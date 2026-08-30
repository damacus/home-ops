#!/usr/bin/env python3
"""Provision Radxa 5B+ images and manage their explicit node lifecycle."""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import hashlib
import json
import os
import platform
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Iterator, NoReturn, Sequence


REPO_ROOT = Path(__file__).resolve().parents[1]
PROVISIONING_ROOT = REPO_ROOT / "provisioning"
IMAGE_ROOT = PROVISIONING_ROOT / "armbian-build"
ARMBIAN_ROOT = IMAGE_ROOT / "armbian-build-repo"
USERPATCHES_ROOT = IMAGE_ROOT / "userpatches"
ARTIFACTS_ROOT = PROVISIONING_ROOT / "artifacts"
K3S_PLAN = REPO_ROOT / "kubernetes/apps/system-upgrade/k3s/app/plan.yaml"
PUBLIC_KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMCLr7NoB34qERAAJNLHKgOy9EJ40smz4F9HhU5d5i8s"
STAGING_ROOT = IMAGE_ROOT / ".staging"
NAS_ROOT = Path("/var/nfs/shared/nfs/provisioning/images/radxa-5b-plus")
ARMBIAN_DOCKER_GENERATED_FILES = ("Dockerfile", ".dockerignore")
REQUIRED_DOCKER_MEMORY = 8 * 1024**3
MAX_DOCKER_VM_OVERHEAD = 512 * 1024**2
MINIMUM_DOCKER_MEMORY = REQUIRED_DOCKER_MEMORY - MAX_DOCKER_VM_OVERHEAD
BUILD_PARAMETERS = {
    "BOARD": "rock-5b-plus",
    "BRANCH": "vendor",
    "RELEASE": "noble",
    "BUILD_MINIMAL": "yes",
    "BUILD_DESKTOP": "no",
    "KERNEL_CONFIGURE": "no",
    "INSTALL_HEADERS": "yes",
    "ENABLE_EXTENSIONS": "nvme-rescan",
    "COMPRESS_OUTPUTIMAGE": "xz",
    "FIXED_IMAGE_SIZE": "3072",
}


class ProvisioningError(RuntimeError):
    """An expected provisioning safety or validation failure."""


def fail(message: str) -> NoReturn:
    raise ProvisioningError(message)


def run(
    command: Sequence[str | Path],
    *,
    check: bool = True,
    capture: bool = False,
    input_text: str | None = None,
    cwd: Path = REPO_ROOT,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(part) for part in command],
        cwd=cwd,
        check=check,
        capture_output=capture,
        text=True,
        input=input_text,
    )


def command_output(command: Sequence[str | Path], *, cwd: Path = REPO_ROOT) -> str:
    return run(command, capture=True, cwd=cwd).stdout.strip()


def print_json(value: Any) -> None:
    print(json.dumps(value, indent=2, sort_keys=True))


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def resolve_k3s_version() -> str:
    versions = re.findall(
        r"(?m)^\s*version:\s*(v\d+\.\d+\.\d+\+k3s\d+)\s*$",
        K3S_PLAN.read_text(encoding="utf-8"),
    )
    if len(versions) != 2:
        fail(f"expected two K3s Plan versions in {K3S_PLAN}, found {len(versions)}")
    if len(set(versions)) != 1:
        fail(f"K3s Plan versions differ: {', '.join(versions)}")
    return versions[0]


def armbian_commit() -> str:
    output = command_output(["git", "ls-files", "--stage", "--", ARMBIAN_ROOT])
    match = re.fullmatch(r"160000 ([0-9a-f]{40}) 0\t.+", output)
    if not match:
        fail(f"{ARMBIAN_ROOT} is not a pinned git submodule")
    return match.group(1)


def repo_commit() -> str:
    commit = command_output(["git", "rev-parse", "HEAD"])
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        fail(f"repository HEAD is not a full commit: {commit}")
    return commit


def release_urls(version: str) -> dict[str, str]:
    encoded = urllib.parse.quote(version, safe="v")
    base = f"https://github.com/k3s-io/k3s/releases/download/{encoded}"
    return {
        "binary_url": f"{base}/k3s-arm64",
        "airgap_url": f"{base}/k3s-airgap-images-arm64.tar",
        "checksum_url": f"{base}/sha256sum-arm64.txt",
    }


def build_plan() -> dict[str, Any]:
    version = resolve_k3s_version()
    return {
        "k3s": {"version": version, **release_urls(version)},
        "home_ops_commit": repo_commit(),
        "armbian_commit": armbian_commit(),
        "build_parameters": BUILD_PARAMETERS,
    }


def require_program(name: str) -> str:
    executable = shutil.which(name)
    if not executable:
        fail(f"required program is unavailable: {name}")
    return executable


def download(url: str, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(url, timeout=120) as response, destination.open("wb") as output:
        shutil.copyfileobj(response, output)


def checksum_entries(path: Path) -> dict[str, str]:
    entries: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"([0-9a-fA-F]{64})\s+\*?(.+)", line.strip())
        if match:
            entries[Path(match.group(2)).name] = match.group(1).lower()
    return entries


def stage_k3s_payloads(plan: dict[str, Any]) -> dict[str, Path]:
    k3s = plan["k3s"]
    STAGING_ROOT.mkdir(parents=True, exist_ok=True)
    targets = {
        "binary": STAGING_ROOT / "k3s-arm64",
        "airgap": STAGING_ROOT / "k3s-airgap-images-arm64.tar",
        "checksums": STAGING_ROOT / "sha256sum-arm64.txt",
    }
    download(k3s["binary_url"], targets["binary"])
    download(k3s["airgap_url"], targets["airgap"])
    download(k3s["checksum_url"], targets["checksums"])
    expected = checksum_entries(targets["checksums"])
    for key, filename in (
        ("binary", "k3s-arm64"),
        ("airgap", "k3s-airgap-images-arm64.tar"),
    ):
        if filename not in expected:
            fail(f"release checksum list does not contain {filename}")
        actual = sha256(targets[key])
        if actual != expected[filename]:
            fail(f"checksum mismatch for {filename}: expected {expected[filename]}, got {actual}")
    return targets


def require_pinned_submodule(expected: str) -> None:
    if not (ARMBIAN_ROOT / ".git").exists():
        fail("Armbian submodule is not initialised; run git submodule update --init -- provisioning/armbian-build/armbian-build-repo")
    actual = command_output(["git", "rev-parse", "HEAD"], cwd=ARMBIAN_ROOT)
    if actual != expected:
        fail(f"Armbian submodule is at {actual}, expected pinned commit {expected}")


def initialise_pinned_submodule(expected: str) -> None:
    if not (ARMBIAN_ROOT / ".git").exists():
        run(["git", "submodule", "update", "--init", "--", ARMBIAN_ROOT.relative_to(REPO_ROOT)])
    require_pinned_submodule(expected)


def require_clean_build_sources() -> None:
    relevant = [
        ".mise/tasks/provisioning",
        "mise.toml",
        "mise.lock",
        "provisioning",
        str(K3S_PLAN.relative_to(REPO_ROOT)),
    ]
    dirty = command_output(
        ["git", "status", "--porcelain", "--untracked-files=all", "--", *relevant]
    )
    if dirty:
        fail(f"build inputs are dirty; commit or remove these changes first:\n{dirty}")


def require_clean_armbian_source(
    expected: str,
    *,
    allow_userpatches: bool = False,
) -> None:
    require_pinned_submodule(expected)
    exclusions = [":(exclude)cache", ":(exclude)output", ":(exclude).tmp"]
    if allow_userpatches:
        exclusions.append(":(exclude)userpatches")
    dirty = command_output(
        [
            "git",
            "status",
            "--porcelain",
            "--untracked-files=all",
            "--ignored",
            "--",
            ".",
            *exclusions,
        ],
        cwd=ARMBIAN_ROOT,
    )
    known_generated = {
        f"!! {filename}" for filename in ARMBIAN_DOCKER_GENERATED_FILES
    }
    dirty = "\n".join(
        line for line in dirty.splitlines() if line not in known_generated
    )
    if dirty:
        fail(f"pinned Armbian checkout is dirty:\n{dirty}")


def require_armbian_command(command: str, *, handler: str = "docker") -> None:
    commands = ARMBIAN_ROOT / "lib/functions/cli/commands.sh"
    command_text = commands.read_text(encoding="utf-8") if commands.is_file() else ""
    if not re.search(
        rf'\["{re.escape(command)}"\]\s*=\s*"{re.escape(handler)}"',
        command_text,
    ):
        fail(f"pinned Armbian source does not register the compile.sh {command} command")


def require_armbian_build_contract(expected: str) -> None:
    require_clean_armbian_source(expected, allow_userpatches=True)
    require_armbian_command("build", handler="standard_build")
    partitioning = ARMBIAN_ROOT / "lib/functions/image/partitioning.sh"
    partition_text = partitioning.read_text(encoding="utf-8") if partitioning.is_file() else ""
    if "FIXED_IMAGE_SIZE" not in partition_text:
        fail("pinned Armbian source does not support FIXED_IMAGE_SIZE")


def require_build_inputs_unchanged(plan: dict[str, Any]) -> None:
    actual_commit = repo_commit()
    if actual_commit != plan["home_ops_commit"]:
        fail(
            "home-ops HEAD changed during the build: "
            f"expected {plan['home_ops_commit']}, found {actual_commit}"
        )
    require_clean_build_sources()
    require_armbian_build_contract(str(plan["armbian_commit"]))


def prepare_userpatches(payloads: dict[str, Path]) -> None:
    destination = ARMBIAN_ROOT / "userpatches"
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(USERPATCHES_ROOT, destination, symlinks=True)
    binary = destination / "overlay/usr/local/bin/k3s"
    airgap = destination / "overlay/var/lib/rancher/k3s/agent/images/k3s-airgap-images-arm64.tar"
    binary.parent.mkdir(parents=True, exist_ok=True)
    airgap.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(payloads["binary"], binary)
    binary.chmod(0o755)
    shutil.copy2(payloads["airgap"], airgap)


def remove_path(path: Path) -> None:
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    elif os.path.lexists(path):
        path.unlink()


@contextlib.contextmanager
def injected_userpatches(payloads: dict[str, Path]) -> Iterator[None]:
    destination = ARMBIAN_ROOT / "userpatches"
    backup_root = Path(tempfile.mkdtemp(prefix=".userpatches-backup-", dir=ARMBIAN_ROOT))
    backup = backup_root / "userpatches"
    had_existing = os.path.lexists(destination)
    try:
        if had_existing:
            os.replace(destination, backup)
    except BaseException:
        backup_root.rmdir()
        raise

    active_error: BaseException | None = None
    try:
        prepare_userpatches(payloads)
        yield
    except BaseException as error:
        active_error = error
        raise
    finally:
        try:
            remove_path(destination)
            if had_existing:
                os.replace(backup, destination)
            backup_root.rmdir()
        except BaseException as cleanup_error:
            if active_error is None:
                raise
            active_error.add_note(f"userpatches restoration also failed: {cleanup_error}")


def write_artifacts(
    plan: dict[str, Any],
    payloads: dict[str, Path],
    *,
    built_after: float,
    timestamp: dt.datetime | None = None,
) -> Path:
    candidates = sorted(
        (
            path
            for path in (ARMBIAN_ROOT / "output/images").glob("*.img.xz")
            if path.stat().st_mtime >= built_after
        ),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    if not candidates:
        fail("Armbian build produced no new .img.xz image")
    timestamp = (timestamp or dt.datetime.now(dt.UTC)).replace(microsecond=0)
    commit = str(plan["home_ops_commit"])
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        fail("build plan home-ops commit is not a full commit")
    release_id = f"radxa-5b-plus-{timestamp:%Y%m%d}-{commit[:12]}"
    ARTIFACTS_ROOT.mkdir(parents=True, exist_ok=True)
    image = ARTIFACTS_ROOT / f"{release_id}.img.xz"
    checksum = image.with_name(f"{image.name}.sha256")
    manifest = image.with_name(f"{release_id}.manifest.json")
    existing = [path for path in (image, checksum, manifest) if os.path.lexists(path)]
    if existing:
        fail(f"artifact set member already exists: {existing[0]}")
    shutil.move(str(candidates[0]), image)
    image_hash = sha256(image)
    checksum.write_text(f"{image_hash}  {image.name}\n", encoding="utf-8")
    manifest_data = {
        "schema_version": 1,
        "release_id": release_id,
        "timestamp": timestamp.isoformat().replace("+00:00", "Z"),
        "home_ops_commit": commit,
        "k3s_version": plan["k3s"]["version"],
        "armbian_commit": plan["armbian_commit"],
        "board": BUILD_PARAMETERS["BOARD"],
        "branch": BUILD_PARAMETERS["BRANCH"],
        "release": BUILD_PARAMETERS["RELEASE"],
        "build_parameters": BUILD_PARAMETERS,
        "files": {
            "image": {"filename": image.name, "sha256": image_hash},
            "checksum": {"filename": checksum.name},
            "manifest": {"filename": manifest.name},
            "k3s_binary": {"filename": "k3s-arm64", "sha256": sha256(payloads["binary"])},
            "k3s_airgap": {
                "filename": "k3s-airgap-images-arm64.tar",
                "sha256": sha256(payloads["airgap"]),
            },
        },
    }
    manifest.write_text(json.dumps(manifest_data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return image


def build(args: argparse.Namespace) -> None:
    plan = build_plan()
    if args.dry_run:
        print_json(plan)
        return
    require_program("docker")
    docker_doctor(args)
    initialise_pinned_submodule(plan["armbian_commit"])
    require_build_inputs_unchanged(plan)
    payloads = stage_k3s_payloads(plan)
    command = ["./compile.sh", "build", *(f"{key}={value}" for key, value in BUILD_PARAMETERS.items())]
    if args.verbose:
        command.append("PROGRESS_DISPLAY=plain")
    started_at = time.time() - 1
    with injected_userpatches(payloads):
        run(command, cwd=ARMBIAN_ROOT)
    require_build_inputs_unchanged(plan)
    image = write_artifacts(plan, payloads, built_after=started_at)
    print(image)


def docker_info() -> dict[str, Any]:
    result = run(["docker", "info", "--format", "{{json .}}"], check=False, capture=True)
    if result.returncode != 0:
        fail(result.stderr.strip() or "Docker daemon is unavailable")
    return json.loads(result.stdout)


def docker_memory_sufficient(memory: int) -> bool:
    return memory >= MINIMUM_DOCKER_MEMORY


def docker_doctor(_: argparse.Namespace) -> None:
    checks: dict[str, dict[str, Any]] = {}
    docker = shutil.which("docker")
    checks["cli"] = {"status": "pass" if docker else "fail", "detail": docker or "docker not found"}
    info: dict[str, Any] = {}
    if docker:
        try:
            info = docker_info()
            checks["daemon"] = {"status": "pass", "detail": "Docker daemon reachable"}
        except (ProvisioningError, json.JSONDecodeError) as error:
            checks["daemon"] = {"status": "fail", "detail": str(error)}
    else:
        checks["daemon"] = {"status": "fail", "detail": "Docker CLI unavailable"}
    architecture = str(info.get("Architecture", "unknown"))
    checks["architecture"] = {
        "status": "pass" if architecture in {"aarch64", "arm64"} else "fail",
        "detail": architecture,
    }
    memory = int(info.get("MemTotal", 0))
    checks["memory"] = {
        "status": "pass" if docker_memory_sufficient(memory) else "fail",
        "detail": (
            f"{memory / 1024**3:.1f} GiB available "
            f"(minimum {MINIMUM_DOCKER_MEMORY / 1024**3:.1f} GiB after VM overhead)"
        ),
    }
    free = shutil.disk_usage(Path.home()).free
    checks["host_space"] = {
        "status": "pass" if free >= 50 * 1024**3 else "fail",
        "detail": f"{free / 1024**3:.1f} GiB free",
    }
    for name, check in checks.items():
        print(f"{check['status'].upper():4} {name}: {check['detail']}")
    if any(check["status"] == "fail" for check in checks.values()):
        fail("Docker preflight failed")


def docker_raw_paths() -> list[Path]:
    candidates = {
        Path.home() / "Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"
    }
    settings = Path.home() / "Library/Group Containers/group.com.docker/settings-store.json"
    if settings.is_file():
        try:
            data = json.loads(settings.read_text(encoding="utf-8"))
        except json.JSONDecodeError as error:
            fail(f"invalid Docker Desktop settings: {error}")

        def find_locations(value: Any, key: str = "") -> None:
            if isinstance(value, dict):
                for child_key, child in value.items():
                    find_locations(child, f"{key}.{child_key}")
            elif isinstance(value, list):
                for child in value:
                    find_locations(child, key)
            elif isinstance(value, str) and (
                value.endswith("Docker.raw") or "diskimagelocation" in key.lower()
            ):
                location = Path(value).expanduser()
                candidates.add(location if location.name == "Docker.raw" else location / "Docker.raw")

        find_locations(data)
    return sorted(path for path in candidates if path.is_file())


def docker_usage(_: argparse.Namespace) -> None:
    run(["docker", "system", "df", "-v"])
    for path in docker_raw_paths():
        info = path.stat()
        physical = info.st_blocks * 512
        print(f"{path}: logical={info.st_size} bytes physical={physical} bytes")


def docker_purge(args: argparse.Namespace) -> None:
    plan = {
        "before": "docker system df -v",
        "purge": [str(ARMBIAN_ROOT / "compile.sh"), "docker-purge"],
        "reclaim": bool(args.reclaim),
        "after": "docker system df -v",
    }
    if args.dry_run:
        print_json(plan)
        return
    expected = armbian_commit()
    require_clean_armbian_source(expected)
    require_armbian_command("docker-purge")
    docker_usage(args)
    run(["./compile.sh", "docker-purge"], cwd=ARMBIAN_ROOT)
    if args.reclaim:
        run(["docker", "run", "--rm", "--privileged", "--pid=host", "docker/desktop-reclaim-space"])
    docker_usage(args)


def scoped_paths(include_artifacts: bool = True) -> list[Path]:
    paths = [
        ARMBIAN_ROOT / "output",
        ARMBIAN_ROOT / "cache",
        ARMBIAN_ROOT / ".tmp",
        *(ARMBIAN_ROOT / filename for filename in ARMBIAN_DOCKER_GENERATED_FILES),
        STAGING_ROOT,
    ]
    if include_artifacts:
        paths.append(ARTIFACTS_ROOT)
    return paths


def remove_paths(paths: Sequence[Path], *, dry_run: bool) -> None:
    if dry_run:
        print_json({"remove": [str(path) for path in paths]})
        return
    existing = [path for path in paths if path.exists()]
    for path in existing:
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        else:
            path.unlink()


def clean(args: argparse.Namespace) -> None:
    if args.dry_run:
        print_json({
            "remove": [str(path) for path in scoped_paths()],
            "deep_armbian_docker_purge": bool(args.deep),
        })
        return
    remove_paths(scoped_paths(), dry_run=False)
    if args.deep:
        docker_purge(argparse.Namespace(dry_run=False, reclaim=False))


def artifacts_clean(args: argparse.Namespace) -> None:
    remove_paths([ARTIFACTS_ROOT, ARMBIAN_ROOT / "output/images"], dry_run=args.dry_run)


def artifact_set(artifact: Path) -> tuple[Path, Path, Path]:
    image = artifact.resolve()
    if image.name.endswith(".sha256"):
        image = image.with_name(image.name.removesuffix(".sha256"))
    elif image.name.endswith(".manifest.json"):
        image = image.with_name(image.name.removesuffix(".manifest.json") + ".img.xz")
    if not image.name.endswith(".img.xz"):
        fail(f"artifact must be a .img.xz image: {image}")
    release_id = image.name.removesuffix(".img.xz")
    return image, image.with_name(f"{image.name}.sha256"), image.with_name(f"{release_id}.manifest.json")


def validate_artifacts(artifact: Path) -> tuple[Path, Path, Path, dict[str, Any]]:
    image, checksum, manifest = artifact_set(artifact)
    for path in (image, checksum, manifest):
        if not path.is_file():
            fail(f"artifact is missing: {path}")
    checksum_lines = checksum.read_text(encoding="utf-8").splitlines()
    checksum_match = re.fullmatch(r"([0-9a-fA-F]{64})\s+\*?(.+)", checksum_lines[0].strip()) if len(checksum_lines) == 1 else None
    if not checksum_match or Path(checksum_match.group(2)).name != image.name:
        fail("checksum sidecar must contain exactly the image hash and filename")
    checksum_value = checksum_match.group(1).lower()
    actual = sha256(image)
    data = json.loads(manifest.read_text(encoding="utf-8"))
    release_id = image.name.removesuffix(".img.xz")
    if not re.fullmatch(r"radxa-5b-plus-\d{8}-[0-9a-f]{12}", release_id):
        fail("artifact filename does not contain a canonical release ID")
    if data.get("schema_version") != 1 or data.get("release_id") != release_id:
        fail("manifest schema or release ID does not match artifact")
    home_ops_commit = str(data.get("home_ops_commit", ""))
    if not re.fullmatch(r"[0-9a-f]{40}", home_ops_commit):
        fail("manifest home-ops commit is not a full commit")
    if release_id.rsplit("-", 1)[-1] != home_ops_commit[:12]:
        fail("manifest home-ops commit does not match the release ID")
    try:
        dt.datetime.fromisoformat(str(data.get("timestamp", "")).replace("Z", "+00:00"))
    except ValueError:
        fail("manifest timestamp is not ISO 8601")
    if data.get("board") != BUILD_PARAMETERS["BOARD"] or data.get("branch") != BUILD_PARAMETERS["BRANCH"] or data.get("release") != BUILD_PARAMETERS["RELEASE"]:
        fail("manifest build target does not match the approved target")
    if data.get("build_parameters") != BUILD_PARAMETERS:
        fail("manifest build parameters do not match the approved build")
    manifest_image = data.get("files", {}).get("image", {})
    if checksum_value != actual or manifest_image.get("sha256") != actual:
        fail("image checksum, checksum sidecar, and manifest do not agree")
    if manifest_image.get("filename") != image.name:
        fail("manifest image filename does not match artifact")
    files = data.get("files", {})
    if files.get("checksum", {}).get("filename") != checksum.name:
        fail("manifest checksum filename does not match artifact")
    if files.get("manifest", {}).get("filename") != manifest.name:
        fail("manifest filename does not match artifact")
    if files.get("k3s_binary", {}).get("filename") != "k3s-arm64" or not re.fullmatch(r"[0-9a-f]{64}", str(files.get("k3s_binary", {}).get("sha256", ""))):
        fail("manifest K3s binary metadata is incomplete")
    if files.get("k3s_airgap", {}).get("filename") != "k3s-airgap-images-arm64.tar" or not re.fullmatch(r"[0-9a-f]{64}", str(files.get("k3s_airgap", {}).get("sha256", ""))):
        fail("manifest K3s air-gap metadata is incomplete")
    if data.get("k3s_version") != resolve_k3s_version():
        fail("manifest K3s version does not match the cluster Plans")
    if data.get("armbian_commit") != armbian_commit():
        fail("manifest Armbian commit does not match the pinned submodule")
    return image, checksum, manifest, data


def check(status_ok: bool, detail: str) -> dict[str, str]:
    return {"status": "pass" if status_ok else "fail", "detail": detail}


def mode(path: Path) -> int | None:
    try:
        return stat.S_IMODE(path.stat().st_mode)
    except FileNotFoundError:
        return None


def owner_ids(path: Path) -> tuple[int, int] | None:
    try:
        info = path.stat()
    except FileNotFoundError:
        return None
    return info.st_uid, info.st_gid


def read_files(paths: Sequence[Path]) -> str:
    contents = []
    for path in paths:
        if path.is_file():
            contents.append(path.read_text(encoding="utf-8", errors="replace"))
    return "\n".join(contents)


def effective_sshd_value(rootfs: Path, key: str) -> str | None:
    value = None
    option_names = [key]
    if key.lower() in {
        "challengeresponseauthentication",
        "kbdinteractiveauthentication",
    }:
        option_names = [
            "ChallengeResponseAuthentication",
            "KbdInteractiveAuthentication",
        ]
    options = "|".join(re.escape(option) for option in option_names)
    pattern = re.compile(rf"(?i)^\s*(?:{options})\s+(\S+)")

    def parse(path: Path) -> None:
        nonlocal value
        if value is not None or not path.is_file():
            return
        in_match_block = False
        for raw_line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            line = raw_line.split("#", 1)[0].strip()
            if not line:
                continue
            if re.match(r"(?i)^Match\s+", line):
                in_match_block = True
                continue
            include = re.match(r"(?i)^Include\s+(.+)", line)
            if include and not in_match_block:
                for configured_pattern in include.group(1).split():
                    relative_pattern = configured_pattern.removeprefix("/")
                    for included in sorted(rootfs.glob(relative_pattern)):
                        parse(included)
                continue
            if not in_match_block:
                match = pattern.match(line)
                if match and value is None:
                    value = match.group(1).lower()

    parse(rootfs / "etc/ssh/sshd_config")
    return value


def valid_timer_activation(rootfs: Path) -> bool:
    activation = rootfs / "etc/systemd/system/timers.target.wants/apt-daily-upgrade.timer"
    if not activation.is_symlink():
        return False
    target = Path(os.readlink(activation))
    if target.is_absolute():
        resolved = rootfs / target.relative_to("/")
    else:
        resolved = activation.parent / target
    resolved = resolved.resolve(strict=False)
    expected = {
        rootfs / "lib/systemd/system/apt-daily-upgrade.timer",
        rootfs / "usr/lib/systemd/system/apt-daily-upgrade.timer",
    }
    return resolved in {path.resolve(strict=False) for path in expected} and resolved.is_file()


def rootfs_report(
    rootfs: Path,
    manifest: dict[str, Any] | None = None,
    reported_k3s_version: str | None = None,
) -> dict[str, Any]:
    checks: dict[str, dict[str, str]] = {}
    checks["rootfs_identity"] = check(
        (rootfs / "etc/os-release").is_file(),
        "rootfs contains an operating-system identity",
    )
    passwd = read_files([rootfs / "etc/passwd"])
    authorized_keys = rootfs / "home/pi/.ssh/authorized_keys"
    keys = authorized_keys.read_text(encoding="utf-8", errors="replace").splitlines() if authorized_keys.is_file() else []
    checks["pi_access"] = check(
        bool(re.search(r"(?m)^pi:[^:]*:1000:", passwd)) and keys == [PUBLIC_KEY],
        "pi user and approved key are present",
    )
    key_mode = mode(authorized_keys)
    ssh_dir_mode = mode(authorized_keys.parent)
    private_key_path = key_mode == 0o600 and ssh_dir_mode == 0o700
    checks["authorized_keys_mode"] = check(
        private_key_path,
        f"authorized_keys={key_mode!s}, .ssh={ssh_dir_mode!s}",
    )
    home = rootfs / "home/pi"
    home_owned = home.is_dir() and owner_ids(home) == (1000, 1000) and mode(home) == 0o750
    checks["pi_home"] = check(home_owned, "pi home is owned by 1000:1000 with mode 0750")
    password = effective_sshd_value(rootfs, "PasswordAuthentication")
    keyboard_interactive = effective_sshd_value(
        rootfs, "KbdInteractiveAuthentication"
    )
    root_login = effective_sshd_value(rootfs, "PermitRootLogin")
    checks["ssh_policy"] = check(
        password == "no" and keyboard_interactive == "no" and root_login == "no",
        (
            f"PasswordAuthentication={password}, "
            f"KbdInteractiveAuthentication={keyboard_interactive}, "
            f"PermitRootLogin={root_login}"
        ),
    )
    periodic = read_files([rootfs / "etc/apt/apt.conf.d/20auto-upgrades"])
    unattended = read_files([rootfs / "etc/apt/apt.conf.d/50unattended-upgrades"])
    origins = ["Ubuntu:noble", "Ubuntu:noble-updates", "Ubuntu:noble-security", "Ubuntu:noble-backports", "Armbian:noble"]
    timer_active = valid_timer_activation(rootfs)
    upgrade_ok = (
        'APT::Periodic::Unattended-Upgrade "1"' in periodic
        and all(origin in unattended for origin in origins)
        and "Automatic-Reboot \"false\"" in unattended
        and timer_active
        and not re.search(r"(?i)(linux-image|linux-dtb|linux-u-boot|armbian-firmware)", unattended.split("Package-Blacklist", 1)[-1])
    )
    checks["unattended_upgrades"] = check(upgrade_ok, "all Noble and Armbian origins enabled; timer active")
    cluster_paths = [
        rootfs / "etc/rancher/k3s/config.yaml",
        rootfs / "etc/rancher/k3s/cluster-token",
        rootfs / "var/lib/rancher/k3s/server/token",
    ]
    cluster_clean = not any(path.exists() for path in cluster_paths)
    checks["cluster_state"] = check(cluster_clean, "no cluster config or token is baked")
    kubeconfig = rootfs / "etc/rancher/k3s/k3s.yaml"
    kube_mode = mode(kubeconfig)
    checks["kubeconfig_mode"] = check(kube_mode in {None, 0o600}, f"mode={kube_mode!s}")
    machine_id = rootfs / "etc/machine-id"
    cloud_instance = rootfs / "var/lib/cloud/instance"
    cloud_instances = rootfs / "var/lib/cloud/instances"
    host_keys = list((rootfs / "etc/ssh").glob("ssh_host_*_key")) if (rootfs / "etc/ssh").exists() else []
    identity_clean = (
        machine_id.is_file()
        and machine_id.stat().st_size == 0
        and not cloud_instance.exists()
        and not cloud_instances.exists()
        and not host_keys
    )
    checks["clean_identity"] = check(identity_clean, "machine ID, cloud-init state, and SSH host keys are clean")
    shadow = read_files([rootfs / "etc/shadow"])
    checks["locked_accounts"] = check(
        bool(re.search(r"(?m)^root:[!*]", shadow)) and bool(re.search(r"(?m)^pi:[!*]", shadow)),
        "root and pi passwords are locked",
    )
    package_status = read_files([rootfs / "var/lib/dpkg/status"])
    required_packages = {
        "cloud-init", "conntrack", "iptables", "ipvsadm", "multipath-tools",
        "nfs-common", "nvme-cli", "open-iscsi", "unattended-upgrades",
    }
    installed_packages = {
        match.group(1)
        for paragraph in package_status.split("\n\n")
        if re.search(r"(?m)^Status:\s+install ok installed\s*$", paragraph)
        if (match := re.search(r"(?m)^Package:\s*(\S+)\s*$", paragraph))
    }
    missing_packages = sorted(required_packages - installed_packages)
    checks["node_packages"] = check(not missing_packages, f"missing={','.join(missing_packages) or 'none'}")
    modules = read_files([rootfs / "etc/modules-load.d/k3s.conf"])
    sysctls = read_files([rootfs / "etc/sysctl.d/99-k3s.conf"])
    checks["node_configuration"] = check(
        "overlay" in modules
        and "br_netfilter" in modules
        and bool(re.search(r"(?m)^net\.ipv4\.ip_forward\s*=\s*1", sysctls)),
        "Kubernetes modules and forwarding sysctls are configured",
    )
    input_paths = [
        rootfs / "etc/cloud/cloud.cfg.d/99-ironstone.cfg",
        rootfs / "var/lib/cloud/seed/nocloud/user-data",
        rootfs / "etc/fstab",
    ]
    image_inputs = read_files(input_paths)
    checks["compact_rootfs"] = check(
        all(path.is_file() for path in input_paths) and "K3S_DATA" not in image_inputs,
        "required image inputs exist without a fixed K3S_DATA partition",
    )
    service = rootfs / "etc/systemd/system/k3s.service"
    service_text = read_files([service])
    wants = list((rootfs / "etc/systemd/system").glob("*.wants/k3s.service")) if (rootfs / "etc/systemd/system").exists() else []
    presets = read_files(sorted((rootfs / "etc/systemd/system-preset").glob("*.preset"))) if (rootfs / "etc/systemd/system-preset").exists() else ""
    checks["dormant_k3s"] = check(
        service.is_file()
        and "ConditionPathExists=/etc/rancher/k3s/config.yaml" in service_text
        and "ConditionPathExists=/etc/rancher/k3s/cluster-token" in service_text
        and not wants
        and not re.search(r"(?m)^\s*enable\s+k3s\.service", presets),
        "K3s unit requires enrolment files and is disabled",
    )
    if manifest is not None:
        binary = rootfs / "usr/local/bin/k3s"
        airgap = rootfs / "var/lib/rancher/k3s/agent/images/k3s-airgap-images-arm64.tar"
        files = manifest.get("files", {})
        payloads_ok = (
            binary.is_file()
            and airgap.is_file()
            and sha256(binary) == files.get("k3s_binary", {}).get("sha256")
            and sha256(airgap) == files.get("k3s_airgap", {}).get("sha256")
        )
        checks["k3s_payloads"] = check(payloads_ok, f"matching K3s {manifest.get('k3s_version')} payloads")
        reported_version = reported_k3s_version or ""
        parsed_versions = re.findall(r"\bv\d+\.\d+\.\d+\+k3s\d+\b", reported_version)
        checks["k3s_version"] = check(
            parsed_versions == [str(manifest.get("k3s_version"))],
            f"binary reports {reported_version.strip() or 'no version'}",
        )
    status_value = "pass" if all(item["status"] == "pass" for item in checks.values()) else "fail"
    return {"status": status_value, "checks": checks}


def xz_uncompressed_size(image: Path) -> int:
    listing = command_output(["xz", "--robot", "--list", image])
    totals = next((line for line in listing.splitlines() if line.startswith("totals\t")), "").split("\t")
    if len(totals) < 5 or not totals[4].isdigit():
        fail("could not determine the uncompressed image size")
    return int(totals[4])


def inspect_image_rootfs(image: Path, manifest: dict[str, Any]) -> dict[str, Any]:
    require_program("docker")
    require_program("xz")
    required = xz_uncompressed_size(image) + 1024**3
    free = shutil.disk_usage(tempfile.gettempdir()).free
    if free < required:
        fail(f"image extraction requires {(required / 1024**3):.1f} GiB; {(free / 1024**3):.1f} GiB is free")
    with tempfile.TemporaryDirectory() as temporary:
        temporary_root = Path(temporary)
        raw = temporary_root / "image.img"
        manifest_path = temporary_root / "manifest.json"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        with raw.open("wb") as output:
            subprocess.run(["xz", "-dc", str(image)], check=True, stdout=output)
        script = r'''set -euo pipefail
apt-get update -qq >/dev/null
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq util-linux e2fsprogs python3 >/dev/null
loop=""
mounted=false
cleanup() {
  if [ "$mounted" = true ]; then umount /mnt/root 2>/dev/null || true; fi
  if [ -n "$loop" ]; then losetup -d "$loop" 2>/dev/null || true; fi
}
trap cleanup EXIT HUP INT TERM
loop=$(losetup --find --show --partscan /image.img)
mkdir -p /mnt/root
root=""
while read -r candidate; do
  mount -o ro,noload "$candidate" /mnt/root
  mounted=true
  if test -f /mnt/root/etc/os-release && test -x /mnt/root/usr/local/bin/k3s && test -f /mnt/root/var/lib/rancher/k3s/agent/images/k3s-airgap-images-arm64.tar; then
    root="$candidate"
    break
  fi
  umount /mnt/root
  mounted=false
done < <(lsblk -rno PATH,TYPE,FSTYPE "$loop" | awk '$2 == "part" && $3 == "ext4" {print $1}')
test -n "$root"
reported_version=$(chroot /mnt/root /usr/local/bin/k3s --version 2>&1)
K3S_REPORTED_VERSION="$reported_version" python3 /verifier/provision.py _rootfs-report \
  --rootfs /mnt/root --manifest /verifier/manifest.json
'''
        result = run([
            "docker", "run", "--rm", "--privileged",
            "-v", f"{raw}:/image.img:ro",
            "-v", f"{manifest_path}:/verifier/manifest.json:ro",
            "-v", f"{Path(__file__).resolve()}:/verifier/provision.py:ro",
            "ubuntu:noble", "bash", "-ceu", script,
        ], capture=True)
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        fail(f"verifier container returned an invalid report: {error}")


def rootfs_report_command(args: argparse.Namespace) -> None:
    manifest = json.loads(Path(args.manifest).read_text(encoding="utf-8"))
    print_json(
        rootfs_report(
            Path(args.rootfs),
            manifest,
            reported_k3s_version=os.environ.get("K3S_REPORTED_VERSION"),
        )
    )


def verify(args: argparse.Namespace) -> None:
    if args.rootfs:
        rootfs = Path(args.rootfs).resolve()
        if not rootfs.is_dir():
            fail(f"rootfs input is not a directory: {rootfs}")
        report = rootfs_report(rootfs)
    else:
        if not args.artifact:
            fail("verify requires an artifact or --rootfs")
        image, _, _, manifest = validate_artifacts(Path(args.artifact))
        report = inspect_image_rootfs(image, manifest)
    if args.raw:
        print_json(report)
    else:
        for name, result in report["checks"].items():
            print(f"{result['status'].upper():4} {name}: {result['detail']}")
    if report["status"] != "pass":
        raise SystemExit(1)


def mounted_values(device: dict[str, Any]) -> list[str]:
    values = device.get("mountpoints") or []
    if device.get("mountpoint"):
        values.append(device["mountpoint"])
    for child in device.get("children") or []:
        values.extend(mounted_values(child))
    return [str(value) for value in values if value]


def inspect_linux_device(device: Path) -> dict[str, Any]:
    if not device.exists() or not stat.S_ISBLK(device.stat().st_mode):
        fail(f"flash target is not a block device: {device}")
    data = json.loads(command_output([
        "lsblk", "--json", "--bytes", "--paths",
        "--output", "PATH,TYPE,SIZE,MODEL,MOUNTPOINTS", device,
    ]))
    entries = data.get("blockdevices", [])
    if len(entries) != 1 or entries[0].get("type") != "disk":
        fail(f"flash target is not a whole disk: {device}")
    entry = entries[0]
    mounts = mounted_values(entry)
    if mounts:
        fail(f"flash target has mounted filesystems: {', '.join(mounts)}")
    root_source = command_output(["findmnt", "--noheadings", "--output", "SOURCE", "/"])
    ancestry = command_output([
        "lsblk", "--inverse", "--noheadings", "--paths", "--output", "PATH", root_source,
    ]).splitlines()
    if str(device.resolve()) in {path.strip() for path in ancestry}:
        fail(f"refusing the disk containing the live root filesystem: {device}")
    return {
        "device": Path(str(entry["path"])),
        "raw_device": Path(str(entry["path"])),
        "size": int(entry.get("size") or 0),
        "model": str(entry.get("model") or "unknown").strip(),
    }


def diskutil_plist(*arguments: str | Path) -> dict[str, Any]:
    command, *rest = arguments
    result = run(["diskutil", command, "-plist", *rest], capture=True)
    return plistlib.loads(result.stdout.encode())


def diskutil_apfs_plist() -> dict[str, Any]:
    result = run(["diskutil", "apfs", "list", "-plist"], capture=True)
    return plistlib.loads(result.stdout.encode())


def apfs_physical_whole_disks(
    apfs: dict[str, Any],
    *,
    volume_identifier: str | None = None,
    mounted_only: bool = False,
) -> set[str]:
    whole_disks: set[str] = set()
    for container in apfs.get("Containers", []):
        volumes = container.get("Volumes", [])
        matches = bool(
            volume_identifier
            and container.get("ContainerReference") == volume_identifier
        ) or any(
            (volume_identifier and volume.get("DeviceIdentifier") == volume_identifier)
            or (mounted_only and volume.get("MountPoint"))
            for volume in volumes
        )
        if not matches:
            continue
        for store in container.get("PhysicalStores", []):
            store_identifier = str(store.get("DeviceIdentifier", ""))
            if not store_identifier:
                continue
            store_info = diskutil_plist("info", f"/dev/{store_identifier}")
            whole_disks.add(str(store_info.get("ParentWholeDisk") or store_identifier))
    return whole_disks


def inspect_darwin_device(device: Path) -> dict[str, Any]:
    if not device.exists() or not stat.S_ISBLK(device.stat().st_mode):
        fail(f"flash target is not a block device: {device}")
    info = diskutil_plist("info", device)
    if not info.get("Whole"):
        fail(f"flash target is not a whole disk: {device}")
    identifier = str(info.get("DeviceIdentifier", ""))
    root = diskutil_plist("info", "/")
    apfs = diskutil_apfs_plist()
    root_disks = {str(root.get("ParentWholeDisk", ""))}
    root_disks.update(
        apfs_physical_whole_disks(
            apfs,
            volume_identifier=str(
                root.get("ParentWholeDisk") or root.get("DeviceIdentifier", "")
            ),
        )
    )
    if identifier in root_disks:
        fail(f"refusing the disk containing the live root filesystem: {device}")
    listing = diskutil_plist("list", device)
    partitions = next(
        (
            disk.get("Partitions", [])
            for disk in listing.get("AllDisksAndPartitions", [])
            if disk.get("DeviceIdentifier") == identifier
        ),
        [],
    )
    mounts = []
    for partition in partitions:
        partition_info = diskutil_plist("info", f"/dev/{partition['DeviceIdentifier']}")
        if partition_info.get("MountPoint"):
            mounts.append(str(partition_info["MountPoint"]))
    if identifier in apfs_physical_whole_disks(apfs, mounted_only=True):
        mounts.append("mounted APFS volume")
    if mounts:
        fail(f"flash target has mounted filesystems: {', '.join(mounts)}")
    whole = Path(f"/dev/{identifier}")
    return {
        "device": whole,
        "raw_device": Path(f"/dev/r{identifier}"),
        "size": int(info.get("TotalSize") or 0),
        "model": str(info.get("MediaName") or info.get("DeviceModel") or "unknown").strip(),
    }


def inspect_flash_device(device: Path) -> dict[str, Any]:
    if platform.system() == "Darwin":
        return inspect_darwin_device(device)
    if platform.system() == "Linux":
        return inspect_linux_device(device)
    fail(f"flashing is unsupported on {platform.system()}")


def flash(args: argparse.Namespace) -> None:
    artifact = Path(args.artifact).resolve()
    device = Path(args.device).resolve()
    plan = {"source": str(artifact), "device": str(device), "remote_download": False}
    if args.dry_run:
        print_json(plan)
        return
    require_program("xz")
    image, _, _, _ = validate_artifacts(artifact)
    target = inspect_flash_device(device)
    image_size = xz_uncompressed_size(image)
    if not target["size"] or image_size > target["size"]:
        fail(f"image is {image_size} bytes but target capacity is {target['size']} bytes")
    print(f"Target: {target['device']} size={target['size']} bytes model={target['model']}")
    confirmation = input(f"Type {target['device']} to overwrite it: ")
    if confirmation != str(target["device"]):
        fail("device confirmation did not match")
    with subprocess.Popen(["xz", "-dc", str(image)], stdout=subprocess.PIPE) as source:
        assert source.stdout is not None
        writer = subprocess.run(["sudo", "dd", f"of={target['raw_device']}", "bs=4M", "conv=fsync", "status=progress"], stdin=source.stdout)
        source.stdout.close()
        source_status = source.wait()
    if source_status != 0 or writer.returncode != 0:
        fail("image write failed")
    run(["sync"])
    if platform.system() == "Darwin":
        run(["diskutil", "eject", target["device"]])


def stage(args: argparse.Namespace) -> None:
    image, checksum, manifest, data = validate_artifacts(Path(args.artifact))
    release_id = str(data["release_id"])
    destination = NAS_ROOT / release_id
    if args.dry_run:
        print_json({"validate": str(image), "copy": [str(image), str(checksum), str(manifest)], "destination": str(destination)})
        return
    NAS_ROOT.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        fail(f"staged release already exists: {destination}")
    temporary = Path(tempfile.mkdtemp(prefix=f".{release_id}.", dir=NAS_ROOT))
    try:
        for path in (image, checksum, manifest):
            shutil.copy2(path, temporary / path.name)
        validate_artifacts(temporary / image.name)
        os.replace(temporary, destination)
    except BaseException:
        shutil.rmtree(temporary, ignore_errors=True)
        raise


def release(args: argparse.Namespace) -> None:
    image, checksum, manifest, data = validate_artifacts(Path(args.artifact))
    release_id = str(data["release_id"])
    if args.dry_run:
        print_json({"validate": str(image), "tag": release_id, "files": [str(image), str(checksum), str(manifest)]})
        return
    run(["gh", "release", "create", release_id, str(image), str(checksum), str(manifest), "--title", release_id, "--generate-notes"])


def kubectl_json(arguments: Sequence[str]) -> Any:
    return json.loads(command_output(["kubectl", *arguments]))


def ready_control_planes() -> list[dict[str, Any]]:
    nodes = kubectl_json(["get", "nodes", "-o", "json"])["items"]
    return [
        node for node in nodes
        if any(condition.get("type") == "Ready" and condition.get("status") == "True" for condition in node["status"].get("conditions", []))
        and any(label in node["metadata"].get("labels", {}) for label in ("node-role.kubernetes.io/control-plane", "node-role.kubernetes.io/master"))
    ]


def node_address(node: dict[str, Any]) -> str:
    addresses = node["status"].get("addresses", [])
    for address_type in ("InternalIP", "ExternalIP", "Hostname"):
        for address in addresses:
            if address.get("type") == address_type:
                return str(address["address"])
    fail(f"node {node['metadata']['name']} has no SSH address")


def current_api_endpoint() -> str:
    config = kubectl_json(["config", "view", "--minify", "-o", "json"])
    return str(config["clusters"][0]["cluster"]["server"])


def sanitise_k3s_config(config: str, endpoint: str) -> str:
    endpoint_value = json.dumps(endpoint)
    result = run([
        "yq", "eval",
        f'.server = {endpoint_value} | ."token-file" = "/etc/rancher/k3s/cluster-token" | ."kube-apiserver-arg" = ((."kube-apiserver-arg" // []) | map(select(test("^anonymous-auth(=true)?$") | not))) | del(."node-ip", ."node-external-ip", ."node-name", ."node-label", ."node-taint", ."advertise-address", ."bind-address", ."flannel-iface", .token, ."write-kubeconfig-mode", ."cluster-init", ."cluster-reset", ."cluster-reset-restore-path")',
        "-",
    ], capture=True, input_text=config)
    sanitised = result.stdout
    if re.search(r"(?im)anonymous-auth\s*(?:=|:)\s*true|write-kubeconfig-mode\s*:\s*0?644", sanitised):
        fail("source K3s config contains unsafe authentication or kubeconfig settings")
    return sanitised


def ssh_read(host: str, command: str) -> str:
    return command_output(["ssh", "-o", "BatchMode=yes", f"pi@{host}", command])


def node_is_ready(node: dict[str, Any]) -> bool:
    return any(
        condition.get("type") == "Ready" and condition.get("status") == "True"
        for condition in node.get("status", {}).get("conditions", [])
    )


def existing_node(name: str) -> dict[str, Any] | None:
    result = run(
        [
            "kubectl",
            "get",
            "node",
            name,
            "--ignore-not-found",
            "--request-timeout=10s",
            "-o",
            "json",
        ],
        check=False,
        capture=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "unknown kubectl error"
        fail(f"could not inspect existing Kubernetes node {name}: {detail}")
    if not result.stdout.strip():
        return None
    try:
        node = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        fail(f"Kubernetes returned invalid node data for {name}: {error}")
    if not isinstance(node, dict) or node.get("metadata", {}).get("name") != name:
        fail(f"Kubernetes returned an unexpected node identity for {name}")
    return node


def node_state(node: dict[str, Any]) -> dict[str, Any]:
    return {
        "name": node.get("metadata", {}).get("name"),
        "uid": node.get("metadata", {}).get("uid"),
        "ready": node_is_ready(node),
        "unschedulable": bool(node.get("spec", {}).get("unschedulable", False)),
    }


def wait_for_enrolled_node(
    name: str,
    host: str,
    token: str,
    *,
    timeout: float = 300,
    interval: float = 5,
) -> None:
    deadline = time.monotonic() + timeout
    last_state = "node not found"
    while True:
        try:
            node = existing_node(name)
            if node is not None:
                labels = node.get("metadata", {}).get("labels", {})
                control_plane = any(
                    label in labels
                    for label in (
                        "node-role.kubernetes.io/control-plane",
                        "node-role.kubernetes.io/master",
                    )
                )
                etcd = "node-role.kubernetes.io/etcd" in labels
                last_state = json.dumps(
                    {
                        **node_state(node),
                        "control_plane": control_plane,
                        "etcd": etcd,
                    },
                    sort_keys=True,
                )
                if node_is_ready(node) and control_plane and etcd:
                    return
        except ProvisioningError as error:
            last_state = str(error)
        if time.monotonic() >= deadline:
            break
        time.sleep(min(interval, max(0, deadline - time.monotonic())))

    logs = run(
        [
            "ssh",
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=10",
            f"pi@{host}",
            "timeout 15s sudo -n journalctl -u k3s.service --no-pager -n 200 --since '-10 minutes'",
        ],
        check=False,
        capture=True,
    )
    log_text = "\n".join(part for part in (logs.stdout, logs.stderr) if part).strip()
    redacted_logs = log_text.replace(token, "<redacted>") if token else log_text
    message = (
        f"node {name} did not become Ready with control-plane and etcd roles "
        f"within {timeout:g}s; last state: {last_state}; "
        f"bounded k3s logs:\n{redacted_logs[-8000:] or '<none>'}"
    )
    fail(message.replace(token, "<redacted>") if token else message)


def enrol(args: argparse.Namespace) -> None:
    run(["kubectl", "get", "--raw=/readyz"], capture=True)
    nodes = ready_control_planes()
    if args.source_node:
        nodes = [node for node in nodes if node["metadata"]["name"] == args.source_node]
    if not nodes:
        fail("no Ready control-plane source node is available")
    source = nodes[0]
    source_host = node_address(source)
    target_hostname = ssh_read(args.host, "hostname -s")
    if not re.fullmatch(r"node-[a-f0-9]{6}", target_hostname):
        fail("target hostname does not match the baked node identity contract")
    existing = existing_node(target_hostname)
    if existing is not None:
        if node_is_ready(existing):
            fail(f"refusing to replace Ready Kubernetes node {target_hostname}")
        if not args.replace:
            fail(f"Kubernetes node {target_hostname} already exists; pass --replace explicitly")
    ssh_read(args.host, "sudo -n true")
    ssh_read(args.host, "test -s /etc/machine-id")
    cloud_init = ssh_read(args.host, "cloud-init status --wait")
    if "status: done" not in cloud_init:
        fail(f"target cloud-init has not completed: {cloud_init}")
    expected_version = resolve_k3s_version()
    target_version = ssh_read(args.host, "sudo /usr/local/bin/k3s --version")
    if not re.search(rf"\b{re.escape(expected_version)}\b", target_version):
        fail(f"target K3s version does not match {expected_version}: {target_version}")
    enabled = ssh_read(args.host, "systemctl is-enabled k3s.service 2>/dev/null || true")
    active = ssh_read(args.host, "systemctl is-active k3s.service 2>/dev/null || true")
    if enabled != "disabled" or active != "inactive":
        fail(f"target K3s must be dormant before enrolment: enabled={enabled}, active={active}")
    ssh_read(
        args.host,
        "sudo test ! -e /etc/rancher/k3s/config.yaml "
        "-a ! -e /etc/rancher/k3s/cluster-token "
        "-a ! -e /var/lib/rancher/k3s/server/token "
        "-a ! -d /var/lib/rancher/k3s/server/db",
    )
    plan = {
        "source_node": source["metadata"]["name"],
        "source_host": source_host,
        "target_host": args.host,
        "target_hostname": target_hostname,
        "k3s_version": expected_version,
        "replacement": node_state(existing) if existing is not None else None,
        "actions": ["install sanitised config mode 0600", "install redacted server token mode 0600", "enable and start k3s"],
        "token": "<redacted>",
    }
    if args.dry_run:
        print_json(plan)
        return
    if existing is not None:
        print_json({"existing_node": node_state(existing)})
        confirmation = f"replace {target_hostname}"
        if input(f"Type {confirmation} to delete the NotReady node: ") != confirmation:
            fail("replacement confirmation did not match")
    source_config = ssh_read(source_host, "sudo cat /etc/rancher/k3s/config.yaml")
    token = ssh_read(source_host, "sudo cat /var/lib/rancher/k3s/server/token")
    if not token:
        fail("source node returned an empty K3s token")
    config = sanitise_k3s_config(source_config, current_api_endpoint())
    if existing is not None:
        run(["kubectl", "delete", "node", target_hostname])
    run(["ssh", f"pi@{args.host}", "sudo install -d -m 0700 /etc/rancher/k3s && sudo install -m 0600 /dev/stdin /etc/rancher/k3s/config.yaml"], input_text=config)
    run(["ssh", f"pi@{args.host}", "sudo install -m 0600 /dev/stdin /etc/rancher/k3s/cluster-token"], input_text=f"{token}\n")
    run(["ssh", f"pi@{args.host}", "sudo systemctl enable --now k3s.service"])
    wait_for_enrolled_node(target_hostname, args.host, token)


def status(args: argparse.Namespace) -> None:
    if not args.host:
        command = ["kubectl", "get", "nodes", "-o", "wide"]
        if args.rtk:
            command.insert(0, "rtk")
        run(command)
        return
    checks = {
        "cloud_init": "cloud-init status --long",
        "k3s_version": "sudo /usr/local/bin/k3s --version",
        "k3s_service": "systemctl status k3s --no-pager",
        "updates": "systemctl is-enabled apt-daily-upgrade.timer && systemctl is-active apt-daily-upgrade.timer",
        "disk": "df -h /",
        "reboot_required": "if test -e /var/run/reboot-required; then cat /var/run/reboot-required; else echo no; fi",
    }
    report: dict[str, Any] = {"host": args.host, "checks": {}}
    failed = False
    for name, remote in checks.items():
        if args.raw:
            print(f"== {name} ==")
            result = run(["ssh", f"pi@{args.host}", remote], check=False)
        else:
            result = run(["ssh", f"pi@{args.host}", remote], check=False, capture=True)
            report["checks"][name] = {
                "status": "pass" if result.returncode == 0 else "fail",
                "output": result.stdout,
                "error": result.stderr,
            }
        failed = failed or result.returncode != 0
    if not args.raw:
        print_json(report)
    if failed:
        raise SystemExit(1)


def retire(args: argparse.Namespace) -> None:
    plan = {
        "node": args.node,
        "host": args.host,
        "actions": ["preflight target identity, sudo, and k3s", "kubectl drain", "disable and stop k3s", "kubectl delete node", "remove K3s config and state"],
    }
    if args.dry_run:
        print_json(plan)
        return
    hostname = ssh_read(args.host, "hostname -s")
    if hostname != args.node:
        fail(f"target hostname {hostname!r} does not match node {args.node!r}")
    ssh_read(args.host, "sudo -n true")
    ssh_read(args.host, "systemctl cat k3s.service >/dev/null")
    if input(f"Type {args.node} to retire it: ") != args.node:
        fail("node confirmation did not match")
    run(["kubectl", "drain", args.node, "--ignore-daemonsets", "--delete-emptydir-data"])
    run(["ssh", f"pi@{args.host}", "sudo systemctl disable --now k3s.service"])
    run(["kubectl", "delete", "node", args.node])
    run(["ssh", f"pi@{args.host}", "sudo rm -rf /etc/rancher/k3s /var/lib/rancher/k3s"])


def lima_remove(args: argparse.Namespace) -> None:
    commands = [["limactl", "unprotect", "ironstone"], ["limactl", "delete", "ironstone"], ["limactl", "prune", "--keep-referred"]]
    if args.dry_run:
        print_json({"confirmation": "ironstone", "commands": commands})
        return
    if input("Type ironstone to remove the legacy Lima VM: ") != "ironstone":
        fail("Lima confirmation did not match")
    for command in commands:
        run(command)


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    commands = root.add_subparsers(dest="command", required=True)
    command = commands.add_parser("build")
    command.add_argument("--dry-run", action="store_true")
    command.add_argument("--verbose", action="store_true")
    command.set_defaults(handler=build)
    commands.add_parser("docker-doctor").set_defaults(handler=docker_doctor)
    commands.add_parser("docker-usage").set_defaults(handler=docker_usage)
    command = commands.add_parser("docker-purge")
    command.add_argument("--dry-run", action="store_true")
    command.add_argument("--reclaim", action="store_true")
    command.set_defaults(handler=docker_purge)
    command = commands.add_parser("clean")
    command.add_argument("--dry-run", action="store_true")
    command.add_argument("--deep", action="store_true")
    command.set_defaults(handler=clean)
    command = commands.add_parser("artifacts-clean")
    command.add_argument("--dry-run", action="store_true")
    command.set_defaults(handler=artifacts_clean)
    command = commands.add_parser("verify")
    command.add_argument("artifact", nargs="?")
    command.add_argument("--rootfs")
    command.add_argument("--raw", action="store_true")
    command.set_defaults(handler=verify)
    command = commands.add_parser("_rootfs-report", help=argparse.SUPPRESS)
    command.add_argument("--rootfs", required=True)
    command.add_argument("--manifest", required=True)
    command.set_defaults(handler=rootfs_report_command)
    command = commands.add_parser("flash")
    command.add_argument("artifact")
    command.add_argument("device")
    command.add_argument("--dry-run", action="store_true")
    command.set_defaults(handler=flash)
    command = commands.add_parser("stage")
    command.add_argument("artifact")
    command.add_argument("--dry-run", action="store_true")
    command.set_defaults(handler=stage)
    command = commands.add_parser("release")
    command.add_argument("artifact")
    command.add_argument("--dry-run", action="store_true")
    command.set_defaults(handler=release)
    command = commands.add_parser("enrol")
    command.add_argument("host")
    command.add_argument("--source-node")
    command.add_argument("--replace", action="store_true")
    command.add_argument("--dry-run", action="store_true")
    command.set_defaults(handler=enrol)
    command = commands.add_parser("status")
    command.add_argument("host", nargs="?")
    command.add_argument("--raw", action="store_true")
    command.add_argument("--rtk", action="store_true")
    command.set_defaults(handler=status)
    command = commands.add_parser("retire")
    command.add_argument("node")
    command.add_argument("host")
    command.add_argument("--dry-run", action="store_true")
    command.set_defaults(handler=retire)
    command = commands.add_parser("lima-remove")
    command.add_argument("--dry-run", action="store_true")
    command.set_defaults(handler=lima_remove)
    return root


def main() -> None:
    args = parser().parse_args()
    try:
        args.handler(args)
    except ProvisioningError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
