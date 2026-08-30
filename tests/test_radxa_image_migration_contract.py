from __future__ import annotations

import contextlib
import io
import json
import inspect
import datetime as dt
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path
from typing import Any, Callable, NoReturn, Sequence
from unittest import mock
from urllib.parse import quote

from provisioning import provision


REPO_ROOT = Path(__file__).resolve().parents[1]
IMAGE_ROOT = REPO_ROOT / "provisioning" / "armbian-build"
OVERLAY_ROOT = IMAGE_ROOT / "userpatches" / "overlay"
K3S_PLAN = REPO_ROOT / "kubernetes/apps/system-upgrade/k3s/app/plan.yaml"
KURED_HELMRELEASE = REPO_ROOT / "kubernetes/apps/kube-system/kured/app/helmrelease.yaml"
KURED_RULES = REPO_ROOT / "kubernetes/apps/kube-system/kured/app/prometheusrule.yaml"
PUBLIC_KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMCLr7NoB34qERAAJNLHKgOy9EJ40smz4F9HhU5d5i8s"

PROVISIONING_TASKS = {
    "provisioning:docker:doctor",
    "provisioning:docker:usage",
    "provisioning:docker:purge",
    "provisioning:build",
    "provisioning:clean",
    "provisioning:verify",
    "provisioning:flash",
    "provisioning:enrol",
    "provisioning:status",
    "provisioning:retire",
    "provisioning:stage",
    "provisioning:release",
    "provisioning:artifacts:clean",
}

IMAGE_SCRIPT_REFERENCE = re.compile(r"/(?:usr/local/(?:bin|sbin)|opt)/[\w./-]+")
K3S_VERSION_TEXT = r"v\d+\.\d+\.\d+(?:\+|%2[Bb])k3s\d+"
K3S_VERSION_ASSIGNMENT = re.compile(
    rf"""(?ix)
    ^\s*(?:-\s*)?
    (?:export\s+)?[\"']?
    (?P<key>[a-z_][\w.-]*)
    [\"']?\s*(?::|(?:\?|\+|:)?=)\s*
    [^\n#]*?(?P<version>{K3S_VERSION_TEXT})
    """
)
K3S_VERSION_BUILD_ARGUMENT = re.compile(
    rf"(?i)--(?:build-arg(?:ument)?|k3s-version|version)"
    rf"(?:=|\s+)(?:[A-Z_][A-Z0-9_]*=)?[\"']?(?P<version>{K3S_VERSION_TEXT})"
)
K3S_VERSION_ARTIFACT_URL = re.compile(
    rf"(?i)https?://[^\s\"']*k3s[^\s\"']*/(?P<version>{K3S_VERSION_TEXT})/"
    r"[^\s\"']*k3s(?:-airgap-images)?-arm64(?:\.tar)?"
)
SYSTEMCTL_ACTIVATION = re.compile(
    r"(?m)\bsystemctl(?:\s+--[\w-]+(?:=\S+)?)*\s+"
    r"(?:enable|start|preset)(?:\s+--[\w-]+(?:=\S+)?)*\s+"
    r"([\w@.-]+\.service)"
)

DIAGNOSTIC_VERSION_KEYS = {
    "comment",
    "description",
    "diagnostic",
    "help",
    "message",
    "note",
    "usage",
}


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def rendered_yaml(path: Path) -> dict:
    result = subprocess.run(
        ["yq", "-o=json", str(path)],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def image_build_inputs() -> dict[Path, str]:
    paths = [IMAGE_ROOT / "build.sh", *IMAGE_ROOT.joinpath("userpatches").rglob("*")]
    return {path: read_text(path) for path in paths if path.is_file()}


def provisioning_build_sources() -> dict[Path, str]:
    sources = image_build_inputs()
    task_root = REPO_ROOT / ".mise/tasks"
    if task_root.exists():
        for path in task_root.rglob("*"):
            if not path.is_file():
                continue
            relative = path.relative_to(task_root)
            if (
                len(relative.parts) >= 2
                and relative.parts[0] == "provisioning"
                and Path(relative.parts[1]).stem == "build"
            ):
                sources[path] = read_text(path)

    candidate_roots = [task_root, REPO_ROOT / "provisioning", REPO_ROOT / "scripts"]
    source_suffixes = {
        "",
        ".bash",
        ".env",
        ".fish",
        ".json",
        ".py",
        ".sh",
        ".toml",
        ".yaml",
        ".yml",
    }
    candidates = {
        path
        for root in candidate_roots
        if root.exists()
        for path in root.rglob("*")
        if path.is_file() and path.suffix in source_suffixes
    }

    pending = list(sources)
    while pending:
        source = pending.pop()
        text = sources[source]
        for candidate in candidates - sources.keys():
            references = {
                candidate.name,
                str(candidate.relative_to(REPO_ROOT)),
                f"/{candidate.relative_to(REPO_ROOT)}",
            }
            if any(reference in text for reference in references):
                sources[candidate] = read_text(candidate)
                pending.append(candidate)

    return sources


def semantic_k3s_version_literals(text: str) -> list[str]:
    versions: set[str] = set()

    for raw_line in text.splitlines():
        stripped = raw_line.lstrip()
        if not stripped or stripped.startswith(("#", "//")):
            continue

        line = re.sub(r"\s+#.*$", "", raw_line)
        if re.match(r"^\s*(?:echo|logger|printf)\b", line):
            continue

        assignment = K3S_VERSION_ASSIGNMENT.search(line)
        if (
            assignment
            and assignment.group("key").lower() not in DIAGNOSTIC_VERSION_KEYS
        ):
            versions.add(assignment.group("version"))

        versions.update(
            match.group("version")
            for pattern in (K3S_VERSION_BUILD_ARGUMENT, K3S_VERSION_ARTIFACT_URL)
            for match in pattern.finditer(line)
        )

    return sorted(versions)


def overlay_files(overlay_root: Path = OVERLAY_ROOT) -> dict[Path, str]:
    return {
        path: read_text(path)
        for path in overlay_root.rglob("*")
        if path.is_file()
    }


def first_boot_execution_sources(
    overlay_root: Path = OVERLAY_ROOT,
) -> dict[Path, str]:
    files = overlay_files(overlay_root)
    cloud_sources = [
        path
        for path, text in files.items()
        if "var/lib/cloud/seed" in str(path.relative_to(overlay_root))
        or re.search(r"(?m)^\s*(bootcmd|runcmd|write_files):", text)
    ]
    enabled_units = {
        unit
        for text in (files[path] for path in cloud_sources)
        for unit in SYSTEMCTL_ACTIVATION.findall(text)
    }
    preset_root = overlay_root / "etc/systemd/system-preset"
    preset_files = list(preset_root.rglob("*.preset")) if preset_root.exists() else []
    if preset_files:
        enabled_units.update(
            unit
            for path in preset_files
            for unit in re.findall(
                r"(?m)^\s*enable\s+([\w@.-]+\.service)\s*$", read_text(path)
            )
        )

    wants_root = overlay_root / "etc/systemd/system"
    wants_files: list[Path] = []
    if wants_root.exists():
        wants_files = list(wants_root.rglob("*.wants/*.service"))
        enabled_units.update(
            path.name for path in wants_files
        )
    pending = [*cloud_sources, *preset_files, *wants_files]
    pending.extend(
        overlay_root / "etc/systemd/system" / unit
        for unit in enabled_units
        if overlay_root.joinpath("etc/systemd/system", unit) in files
    )
    sources: dict[Path, str] = {}

    while pending:
        path = pending.pop()
        if path in sources:
            continue
        text = files[path]
        sources[path] = text

        for image_path in IMAGE_SCRIPT_REFERENCE.findall(text):
            target = overlay_root / image_path.lstrip("/")
            if target in files:
                pending.append(target)

        for unit in re.findall(r"(?m)^(?:Requires|Wants)=.*?([\w@.-]+\.service)", text):
            target = overlay_root / "etc/systemd/system" / unit
            if target in files:
                pending.append(target)

    return sources


def automatic_k3s_startup_violations(
    overlay_root: Path = OVERLAY_ROOT,
) -> dict[Path, list[str]]:
    violations: dict[Path, list[str]] = {}
    activation_patterns = {
        "systemctl activation": (
            r"(?im)\bsystemctl(?:\s+--[\w-]+(?:=\S+)?)*\s+"
            r"(?:enable|start|preset)(?:\s+--[\w-]+(?:=\S+)?)*\s+"
            r"k3s(?:-[\w@.-]+)?\.service\b"
        ),
        "service start": r"(?im)\bservice\s+k3s(?:-[\w@.-]+)?\s+start\b",
        "direct K3s start": r"(?im)(?:^|[;&|]\s*|-\s+)(?:/\S*/)?k3s\s+(?:server|agent)\b",
        "reachable K3s unit": r"(?im)^ExecStart=.*\bk3s\s+(?:server|agent)\b",
        "legacy K3s init": r"(?i)\bk3s-init\b",
        "systemd preset": r"(?im)^\s*enable\s+k3s(?:-[\w@.-]+)?\.service\s*$",
    }

    for path, text in first_boot_execution_sources(overlay_root).items():
        matches = [
            name
            for name, pattern in activation_patterns.items()
            if re.search(pattern, text)
        ]
        if ".wants" in path.parts and re.fullmatch(
            r"k3s(?:-[\w@.-]+)?\.service", path.name
        ):
            matches.append("systemd wants symlink")
        if matches:
            violations[path] = matches

    return violations


def build_time_k3s_startup_violations(
    build_inputs: dict[Path, str] | None = None,
) -> dict[Path, list[str]]:
    inputs = (
        {
            path: text
            for path, text in image_build_inputs().items()
            if not path.is_relative_to(OVERLAY_ROOT)
        }
        if build_inputs is None
        else build_inputs
    )
    violations: dict[Path, list[str]] = {}

    for path, text in inputs.items():
        commands = "\n".join(
            line for line in text.splitlines() if not line.lstrip().startswith("#")
        )
        activated_units = [
            unit
            for unit in SYSTEMCTL_ACTIVATION.findall(commands)
            if re.fullmatch(r"k3s(?:-[\w@.-]+)?\.service", unit, re.IGNORECASE)
        ]
        if activated_units:
            violations[path] = activated_units

    return violations


class MiseProvisioningTaskContractsTest(unittest.TestCase):
    def test_provisioning_tasks_are_exposed_and_usage_is_valid(self) -> None:
        listed = subprocess.run(
            ["mise", "tasks", "ls", "--json"],
            cwd=REPO_ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        task_names = {task["name"] for task in json.loads(listed.stdout)}
        validation = subprocess.run(
            ["mise", "tasks", "validate", *sorted(PROVISIONING_TASKS)],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
        )
        with self.subTest(contract="every approved task is exposed"):
            self.assertSetEqual(task_names & PROVISIONING_TASKS, PROVISIONING_TASKS)
        with self.subTest(contract="Mise validates task usage definitions"):
            self.assertEqual(validation.returncode, 0, validation.stderr)

    def test_flash_dry_run_emits_a_local_no_download_plan(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture_dir = Path(temporary)
            artifact = fixture_dir / "radxa.img.xz"
            device = fixture_dir / "target-device"
            artifact.write_bytes(b"image fixture")
            device.touch()

            result = subprocess.run(
                [
                    "mise",
                    "run",
                    "provisioning:flash",
                    str(artifact),
                    str(device),
                    "--dry-run",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(result.stdout)
        self.assertEqual(plan["source"], str(artifact.resolve()))
        self.assertEqual(plan["device"], str(device.resolve()))
        self.assertFalse(plan["remote_download"])

    @staticmethod
    def write_rootfs_file(rootfs: Path, relative_path: str, content: str, mode: int) -> Path:
        path = rootfs / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        os.chmod(path, mode)
        return path

    def rootfs_fixture(self, rootfs: Path) -> tuple[Path, Path]:
        self.write_rootfs_file(rootfs, "etc/os-release", 'ID="ubuntu"\n', 0o644)
        self.write_rootfs_file(
            rootfs,
            "etc/passwd",
            "root:x:0:0:root:/root:/bin/bash\npi:x:1000:1000:pi:/home/pi:/bin/bash\n",
            0o644,
        )
        authorized_keys = self.write_rootfs_file(
            rootfs,
            "home/pi/.ssh/authorized_keys",
            f"{PUBLIC_KEY}\n",
            0o600,
        )
        os.chmod(rootfs / "home/pi", 0o750)
        os.chmod(rootfs / "home/pi/.ssh", 0o700)
        self.write_rootfs_file(
            rootfs,
            "etc/shadow",
            "root:!:20000:0:99999:7:::\npi:!:20000:0:99999:7:::\n",
            0o600,
        )
        self.write_rootfs_file(rootfs, "etc/machine-id", "", 0o644)
        self.write_rootfs_file(
            rootfs,
            "etc/ssh/sshd_config",
            "Include /etc/ssh/sshd_config.d/*.conf\n",
            0o644,
        )
        self.write_rootfs_file(
            rootfs,
            "etc/ssh/sshd_config.d/00-ironstone-hardening.conf",
            (
                "PasswordAuthentication no\n"
                "ChallengeResponseAuthentication no\n"
                "KbdInteractiveAuthentication no\n"
                "PermitRootLogin no\n"
            ),
            0o644,
        )
        self.write_rootfs_file(
            rootfs,
            "etc/apt/apt.conf.d/20auto-upgrades",
            "APT::Periodic::Unattended-Upgrade \"1\";\n",
            0o644,
        )
        self.write_rootfs_file(
            rootfs,
            "etc/apt/apt.conf.d/50unattended-upgrades",
            (
                "Unattended-Upgrade::Allowed-Origins {\n"
                '  "Ubuntu:noble";\n'
                '  "Ubuntu:noble-updates";\n'
                '  "Ubuntu:noble-security";\n'
                '  "Ubuntu:noble-backports";\n'
                '  "Armbian:noble";\n'
                "};\n"
                'Unattended-Upgrade::Automatic-Reboot "false";\n'
            ),
            0o644,
        )
        self.write_rootfs_file(
            rootfs,
            "lib/systemd/system/apt-daily-upgrade.timer",
            "[Timer]\nOnCalendar=*-*-* 06:00\n",
            0o644,
        )
        activation = rootfs / "etc/systemd/system/timers.target.wants/apt-daily-upgrade.timer"
        activation.parent.mkdir(parents=True, exist_ok=True)
        activation.symlink_to("/lib/systemd/system/apt-daily-upgrade.timer")
        package_status = "\n\n".join(
            f"Package: {package}\nStatus: install ok installed"
            for package in (
                "cloud-init",
                "conntrack",
                "iptables",
                "ipvsadm",
                "multipath-tools",
                "nfs-common",
                "nvme-cli",
                "open-iscsi",
                "unattended-upgrades",
            )
        )
        self.write_rootfs_file(
            rootfs, "var/lib/dpkg/status", f"{package_status}\n", 0o644
        )
        self.write_rootfs_file(
            rootfs, "etc/modules-load.d/k3s.conf", "overlay\nbr_netfilter\n", 0o644
        )
        self.write_rootfs_file(
            rootfs, "etc/sysctl.d/99-k3s.conf", "net.ipv4.ip_forward = 1\n", 0o644
        )
        self.write_rootfs_file(
            rootfs, "etc/cloud/cloud.cfg.d/99-ironstone.cfg", "datasource_list: [NoCloud, None]\n", 0o644
        )
        self.write_rootfs_file(
            rootfs, "var/lib/cloud/seed/nocloud/user-data", "#cloud-config\n", 0o600
        )
        self.write_rootfs_file(rootfs, "etc/fstab", "UUID=root / ext4 defaults 0 1\n", 0o644)
        self.write_rootfs_file(
            rootfs,
            "etc/systemd/system/k3s.service",
            (
                "[Unit]\n"
                "ConditionPathExists=/etc/rancher/k3s/config.yaml\n"
                "ConditionPathExists=/etc/rancher/k3s/cluster-token\n"
                "[Service]\nExecStart=/usr/local/bin/k3s server\n"
            ),
            0o644,
        )
        kubeconfig = self.write_rootfs_file(
            rootfs,
            "etc/rancher/k3s/k3s.yaml",
            "apiVersion: v1\nkind: Config\n",
            0o600,
        )
        return authorized_keys, kubeconfig

    def verify_rootfs(self, rootfs: Path) -> tuple[subprocess.CompletedProcess[str], dict]:
        # macOS cannot create the baked Linux UID/GID without privilege. Mock
        # only stat ownership; every production policy branch still executes.
        def owner_ids(path: Path) -> tuple[int, int] | None:
            if path == rootfs / "home/pi":
                return (0, 0) if (rootfs / ".wrong-home-owner").exists() else (1000, 1000)
            stat_result = path.stat()
            return stat_result.st_uid, stat_result.st_gid

        with mock.patch.object(provision, "owner_ids", side_effect=owner_ids):
            report = provision.rootfs_report(rootfs)
        result = subprocess.CompletedProcess(
            ["provisioning:verify", "--rootfs", str(rootfs)],
            0 if report["status"] == "pass" else 1,
            json.dumps(report),
            "",
        )
        return result, report

    def assert_rootfs_check(self, report: dict, check: str, status: str) -> None:
        self.assertEqual(report["checks"][check]["status"], status)

    def assert_rootfs_mutation_fails(
        self,
        mutation: Callable[[Path], None],
        check: str,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            rootfs = Path(temporary)
            self.rootfs_fixture(rootfs)
            mutation(rootfs)

            result, report = self.verify_rootfs(rootfs)

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(report["status"], "fail")
        self.assert_rootfs_check(report, check, "fail")

    def test_verify_rootfs_reports_effective_image_security(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            rootfs = Path(temporary)
            authorized_keys, kubeconfig = self.rootfs_fixture(rootfs)
            self.assertEqual(authorized_keys.stat().st_mode & 0o777, 0o600)
            self.assertEqual(kubeconfig.stat().st_mode & 0o777, 0o600)

            result, report = self.verify_rootfs(rootfs)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(report["status"], "pass")
            for check in (
                "rootfs_identity",
                "pi_access",
                "authorized_keys_mode",
                "pi_home",
                "ssh_policy",
                "unattended_upgrades",
                "cluster_state",
                "kubeconfig_mode",
                "clean_identity",
                "locked_accounts",
                "node_packages",
                "node_configuration",
                "compact_rootfs",
                "dormant_k3s",
            ):
                with self.subTest(check=check):
                    self.assert_rootfs_check(report, check, "pass")

    def test_real_artifact_report_preserves_payload_hash_and_exact_version_checks(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            rootfs = Path(temporary)
            self.rootfs_fixture(rootfs)
            binary = self.write_rootfs_file(
                rootfs, "usr/local/bin/k3s", "binary payload\n", 0o755
            )
            airgap = self.write_rootfs_file(
                rootfs,
                "var/lib/rancher/k3s/agent/images/k3s-airgap-images-arm64.tar",
                "airgap payload\n",
                0o644,
            )
            manifest = {
                "k3s_version": "v1.36.3+k3s1",
                "files": {
                    "k3s_binary": {"sha256": provision.sha256(binary)},
                    "k3s_airgap": {"sha256": provision.sha256(airgap)},
                },
            }

            def owner_ids(path: Path) -> tuple[int, int]:
                if path == rootfs / "home/pi":
                    return 1000, 1000
                info = path.stat()
                return info.st_uid, info.st_gid

            with mock.patch.object(provision, "owner_ids", side_effect=owner_ids):
                report = provision.rootfs_report(
                    rootfs,
                    manifest,
                    reported_k3s_version="k3s version v1.36.3+k3s1 (build)",
                )
                wrong_version = provision.rootfs_report(
                    rootfs,
                    manifest,
                    reported_k3s_version="k3s version v1.36.3+k3s10 (build)",
                )

            self.assert_rootfs_check(report, "k3s_payloads", "pass")
            self.assert_rootfs_check(report, "k3s_version", "pass")
            self.assert_rootfs_check(wrong_version, "k3s_version", "fail")

    def test_verify_rootfs_rejects_each_security_regression(self) -> None:
        def replace_rootfs_file(
            relative_path: str,
            content: str,
            mode: int = 0o644,
        ) -> Callable[[Path], None]:
            return lambda rootfs: self.write_rootfs_file(
                rootfs, relative_path, content, mode
            )

        mutations: dict[str, tuple[Callable[[Path], None], str]] = {
            "missing rootfs identity": (
                lambda rootfs: (rootfs / "etc/os-release").unlink(),
                "rootfs_identity",
            ),
            "missing pi user": (
                replace_rootfs_file(
                    "etc/passwd",
                    "root:x:0:0:root:/root:/bin/bash\n",
                ),
                "pi_access",
            ),
            "wrong public key": (
                replace_rootfs_file(
                    "home/pi/.ssh/authorized_keys",
                    "ssh-ed25519 AAAAC3NzaWrongKey test@example.invalid\n",
                    0o600,
                ),
                "pi_access",
            ),
            "world-readable authorized_keys": (
                lambda rootfs: os.chmod(
                    rootfs / "home/pi/.ssh/authorized_keys", 0o644
                ),
                "authorized_keys_mode",
            ),
            "private SSH directory missing": (
                lambda rootfs: os.chmod(rootfs / "home/pi/.ssh", 0o755),
                "authorized_keys_mode",
            ),
            "wrong pi home owner": (
                lambda rootfs: (rootfs / ".wrong-home-owner").touch(),
                "pi_home",
            ),
            "password SSH login": (
                replace_rootfs_file(
                    "etc/ssh/sshd_config.d/00-ironstone-hardening.conf",
                    "PasswordAuthentication yes\nKbdInteractiveAuthentication no\nPermitRootLogin no\n",
                ),
                "ssh_policy",
            ),
            "keyboard-interactive SSH login": (
                replace_rootfs_file(
                    "etc/ssh/sshd_config.d/00-00-override.conf",
                    "KbdInteractiveAuthentication yes\n",
                ),
                "ssh_policy",
            ),
            "challenge-response SSH login alias": (
                replace_rootfs_file(
                    "etc/ssh/sshd_config.d/00-00-override.conf",
                    "ChallengeResponseAuthentication yes\n",
                ),
                "ssh_policy",
            ),
            "root SSH login": (
                replace_rootfs_file(
                    "etc/ssh/sshd_config.d/00-ironstone-hardening.conf",
                    "PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin yes\n",
                ),
                "ssh_policy",
            ),
            "inactive unattended-upgrades timer": (
                lambda rootfs: (
                    rootfs
                    / "etc/systemd/system/timers.target.wants/apt-daily-upgrade.timer"
                ).unlink(),
                "unattended_upgrades",
            ),
            "dangling unattended-upgrades timer": (
                lambda rootfs: (
                    rootfs
                    / "lib/systemd/system/apt-daily-upgrade.timer"
                ).unlink(),
                "unattended_upgrades",
            ),
            "missing Armbian unattended-upgrades origin": (
                replace_rootfs_file(
                    "etc/apt/apt.conf.d/50unattended-upgrades",
                    (
                        "Unattended-Upgrade::Allowed-Origins {\n"
                        '  "Ubuntu:noble";\n'
                        '  "Ubuntu:noble-updates";\n'
                        '  "Ubuntu:noble-security";\n'
                        '  "Ubuntu:noble-backports";\n'
                        "};\n"
                    ),
                ),
                "unattended_upgrades",
            ),
            "missing Ubuntu unattended-upgrades origins": (
                replace_rootfs_file(
                    "etc/apt/apt.conf.d/50unattended-upgrades",
                    (
                        "Unattended-Upgrade::Allowed-Origins {\n"
                        '  "Armbian:noble";\n'
                        "};\n"
                    ),
                ),
                "unattended_upgrades",
            ),
            "baked K3s cluster config": (
                replace_rootfs_file(
                    "etc/rancher/k3s/config.yaml",
                    "disable:\n  - traefik\n",
                    0o600,
                ),
                "cluster_state",
            ),
            "baked K3s cluster token": (
                replace_rootfs_file(
                    "etc/rancher/k3s/cluster-token",
                    "should-not-be-baked\n",
                    0o600,
                ),
                "cluster_state",
            ),
            "world-readable kubeconfig": (
                lambda rootfs: os.chmod(
                    rootfs / "etc/rancher/k3s/k3s.yaml", 0o644
                ),
                "kubeconfig_mode",
            ),
            "non-empty machine identity": (
                replace_rootfs_file("etc/machine-id", "machine-id\n"),
                "clean_identity",
            ),
            "baked SSH host key": (
                replace_rootfs_file("etc/ssh/ssh_host_ed25519_key", "private\n", 0o600),
                "clean_identity",
            ),
            "unlocked pi account": (
                replace_rootfs_file(
                    "etc/shadow",
                    "root:!:20000:0:99999:7:::\npi:$6$hash:20000:0:99999:7:::\n",
                    0o600,
                ),
                "locked_accounts",
            ),
            "missing required package": (
                lambda rootfs: (rootfs / "var/lib/dpkg/status").write_text(
                    (rootfs / "var/lib/dpkg/status")
                    .read_text(encoding="utf-8")
                    .replace("Package: nvme-cli\nStatus: install ok installed\n\n", ""),
                    encoding="utf-8",
                ),
                "node_packages",
            ),
            "missing forwarding sysctl": (
                replace_rootfs_file("etc/sysctl.d/99-k3s.conf", ""),
                "node_configuration",
            ),
            "fixed K3S_DATA input": (
                replace_rootfs_file("etc/fstab", "LABEL=K3S_DATA /var/lib/rancher ext4 defaults 0 2\n"),
                "compact_rootfs",
            ),
            "missing cloud-init input": (
                lambda rootfs: (rootfs / "var/lib/cloud/seed/nocloud/user-data").unlink(),
                "compact_rootfs",
            ),
            "K3s unit without token condition": (
                replace_rootfs_file(
                    "etc/systemd/system/k3s.service",
                    "[Unit]\nConditionPathExists=/etc/rancher/k3s/config.yaml\n",
                ),
                "dormant_k3s",
            ),
        }

        for regression, (mutation, check) in mutations.items():
            with self.subTest(regression=regression, check=check):
                self.assert_rootfs_mutation_fails(mutation, check)


class ProvisioningSafetyRegressionTest(unittest.TestCase):
    @staticmethod
    def initialise_armbian_checkout(armbian: Path) -> str:
        (armbian / "lib/functions/cli").mkdir(parents=True)
        (armbian / "lib/functions/image").mkdir(parents=True)
        (armbian / ".gitignore").write_text(
            (
                "/Dockerfile\n"
                "/.dockerignore\n"
                "/cache/\n"
                "/output/\n"
                "/.tmp/\n"
                "/userpatches/\n"
                "*.ignored\n"
            ),
            encoding="utf-8",
        )
        (armbian / "compile.sh").write_text(
            "#!/usr/bin/env bash\nexit 0\n", encoding="utf-8"
        )
        (armbian / "lib/functions/cli/commands.sh").write_text(
            '["docker"]="docker"\n["docker-purge"]="docker"\n',
            encoding="utf-8",
        )
        (armbian / "lib/functions/image/partitioning.sh").write_text(
            "FIXED_IMAGE_SIZE=3072\n", encoding="utf-8"
        )
        subprocess.run(["git", "init", "--quiet"], cwd=armbian, check=True)
        subprocess.run(["git", "add", "."], cwd=armbian, check=True)
        subprocess.run(
            [
                "git",
                "-c",
                "user.name=Provisioning Test",
                "-c",
                "user.email=provisioning-test@example.invalid",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "--quiet",
                "-m",
                "test: initialise pinned Armbian fixture",
            ],
            cwd=armbian,
            check=True,
        )
        return subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=armbian,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

    def test_injected_userpatches_restore_preexisting_ignored_state_on_error(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            armbian = Path(temporary)
            original = armbian / "userpatches"
            original.mkdir()
            marker = original / "ignored.conf"
            marker.write_text("original\n", encoding="utf-8")
            marker.chmod(0o640)
            binary = armbian / "k3s-arm64"
            airgap = armbian / "k3s-airgap-images-arm64.tar"
            binary.write_text("binary\n", encoding="utf-8")
            airgap.write_text("airgap\n", encoding="utf-8")

            with (
                mock.patch.object(provision, "ARMBIAN_ROOT", armbian),
                self.assertRaisesRegex(RuntimeError, "original build error"),
            ):
                with provision.injected_userpatches(
                    {"binary": binary, "airgap": airgap}
                ):
                    self.assertFalse(marker.exists())
                    raise RuntimeError("original build error")

            self.assertEqual(marker.read_text(encoding="utf-8"), "original\n")
            self.assertEqual(marker.stat().st_mode & 0o777, 0o640)
            self.assertFalse(any(path.name.startswith(".userpatches-backup-") for path in armbian.iterdir()))

            shutil.rmtree(original)
            with mock.patch.object(provision, "ARMBIAN_ROOT", armbian):
                with provision.injected_userpatches(
                    {"binary": binary, "airgap": airgap}
                ):
                    self.assertTrue((armbian / "userpatches").is_dir())
            self.assertFalse((armbian / "userpatches").exists())

    def test_existing_node_distinguishes_absent_ready_notready_and_errors(self) -> None:
        ready = {
            "metadata": {"name": "node-a1b2c3", "uid": "ready-uid"},
            "spec": {"unschedulable": False},
            "status": {"conditions": [{"type": "Ready", "status": "True"}]},
        }
        not_ready = {
            "metadata": {"name": "node-a1b2c3", "uid": "old-uid"},
            "spec": {"unschedulable": True},
            "status": {"conditions": [{"type": "Ready", "status": "False"}]},
        }
        cases = {
            "absent": subprocess.CompletedProcess([], 0, "", ""),
            "ready": subprocess.CompletedProcess([], 0, json.dumps(ready), ""),
            "notready": subprocess.CompletedProcess([], 0, json.dumps(not_ready), ""),
            "error": subprocess.CompletedProcess([], 1, "", "forbidden"),
        }
        for state, result in cases.items():
            with self.subTest(state=state), mock.patch.object(provision, "run", return_value=result):
                if state == "error":
                    with self.assertRaises(provision.ProvisioningError):
                        provision.existing_node("node-a1b2c3")
                else:
                    self.assertEqual(provision.existing_node("node-a1b2c3"), None if state == "absent" else (ready if state == "ready" else not_ready))

    def test_docker_purge_rejects_dirty_or_unsupported_pinned_source(self) -> None:
        with (
            mock.patch.object(provision, "require_pinned_submodule"),
            mock.patch.object(
                provision,
                "command_output",
                return_value=" M lib/functions/cli/commands.sh",
            ) as status,
        ):
            with self.assertRaisesRegex(provision.ProvisioningError, "dirty"):
                provision.require_clean_armbian_source("a" * 40)
        status_command = status.call_args.args[0]
        self.assertIn("--ignored", status_command)
        self.assertNotIn(":(exclude)userpatches", status_command)
        self.assertIn(":(exclude).tmp", status_command)

        self.assertIn(provision.ARMBIAN_ROOT / ".tmp", provision.scoped_paths())
        self.assertIn(provision.ARMBIAN_ROOT / "Dockerfile", provision.scoped_paths())
        self.assertIn(provision.ARMBIAN_ROOT / ".dockerignore", provision.scoped_paths())

        with tempfile.TemporaryDirectory() as temporary:
            armbian = Path(temporary)
            commands = armbian / "lib/functions/cli/commands.sh"
            commands.parent.mkdir(parents=True)
            commands.write_text('["docker"]="docker"\n', encoding="utf-8")
            with (
                mock.patch.object(provision, "ARMBIAN_ROOT", armbian),
                self.assertRaisesRegex(provision.ProvisioningError, "docker-purge"),
            ):
                provision.require_armbian_command("docker-purge")

    def test_generated_armbian_docker_state_allows_build_finalisation_and_purge(
        self,
    ) -> None:
        plan = {
            "k3s": {"version": "v1.36.3+k3s1"},
            "home_ops_commit": "1" * 40,
            "armbian_commit": "",
            "build_parameters": provision.BUILD_PARAMETERS,
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            armbian = root / "armbian"
            armbian.mkdir()
            plan["armbian_commit"] = self.initialise_armbian_checkout(armbian)
            source = root / "source-userpatches"
            source.mkdir()
            binary = root / "k3s-arm64"
            airgap = root / "k3s-airgap-images-arm64.tar"
            binary.write_bytes(b"binary")
            airgap.write_bytes(b"airgap")
            payloads = {"binary": binary, "airgap": airgap}
            real_run = provision.run
            events: list[str] = []

            def check_build_inputs(_: dict[str, object]) -> None:
                events.append("check")
                provision.require_clean_armbian_source(
                    str(plan["armbian_commit"]), allow_userpatches=True
                )

            def intercept_build(
                command: Sequence[str | Path], **kwargs: Any
            ) -> subprocess.CompletedProcess[str]:
                if [str(part) for part in command[:2]] == ["./compile.sh", "docker"]:
                    events.append("build")
                    (armbian / "Dockerfile").write_text("generated\n", encoding="utf-8")
                    (armbian / ".dockerignore").write_text(
                        "generated\n", encoding="utf-8"
                    )
                    return subprocess.CompletedProcess(command, 0, "", "")
                return real_run(command, **kwargs)

            def write_artifact(*_: object, **__: object) -> Path:
                events.append("write")
                return Path("artifact.img.xz")

            with (
                mock.patch.object(provision, "ARMBIAN_ROOT", armbian),
                mock.patch.object(provision, "USERPATCHES_ROOT", source),
                mock.patch.object(provision, "build_plan", return_value=plan),
                mock.patch.object(provision, "require_program"),
                mock.patch.object(provision, "docker_doctor"),
                mock.patch.object(provision, "initialise_pinned_submodule"),
                mock.patch.object(
                    provision,
                    "require_build_inputs_unchanged",
                    side_effect=check_build_inputs,
                ),
                mock.patch.object(
                    provision, "stage_k3s_payloads", return_value=payloads
                ),
                mock.patch.object(provision, "run", side_effect=intercept_build),
                mock.patch.object(
                    provision, "write_artifacts", side_effect=write_artifact
                ),
                mock.patch("builtins.print"),
            ):
                provision.build(Namespace(dry_run=False, verbose=False))

            status = subprocess.run(
                ["git", "status", "--porcelain", "--ignored"],
                cwd=armbian,
                check=True,
                capture_output=True,
                text=True,
            ).stdout.splitlines()
            self.assertIn("!! Dockerfile", status)
            self.assertIn("!! .dockerignore", status)
            self.assertEqual(events, ["check", "build", "check", "write"])

            def intercept_purge(
                command: Sequence[str | Path], **kwargs: Any
            ) -> subprocess.CompletedProcess[str]:
                if [str(part) for part in command] == ["./compile.sh", "docker-purge"]:
                    events.append("purge")
                    return subprocess.CompletedProcess(command, 0, "", "")
                return real_run(command, **kwargs)

            with (
                mock.patch.object(provision, "ARMBIAN_ROOT", armbian),
                mock.patch.object(
                    provision, "armbian_commit", return_value=plan["armbian_commit"]
                ),
                mock.patch.object(provision, "docker_usage"),
                mock.patch.object(provision, "run", side_effect=intercept_purge),
            ):
                provision.docker_purge(Namespace(dry_run=False, reclaim=False))
            self.assertEqual(events[-1], "purge")

    def test_armbian_source_gate_rejects_other_ignored_and_tracked_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            armbian = Path(temporary)
            commit = self.initialise_armbian_checkout(armbian)
            (armbian / "Dockerfile").write_text("generated\n", encoding="utf-8")
            (armbian / ".dockerignore").write_text("generated\n", encoding="utf-8")
            unrelated = armbian / "unrelated.ignored"
            unrelated.write_text("not generated by Armbian Docker\n", encoding="utf-8")

            with (
                mock.patch.object(provision, "ARMBIAN_ROOT", armbian),
                self.assertRaisesRegex(provision.ProvisioningError, "unrelated.ignored"),
            ):
                provision.require_clean_armbian_source(commit)

            unrelated.unlink()
            helper = armbian / "lib/functions/cli/commands.sh"
            helper.write_text(
                helper.read_text(encoding="utf-8") + "# local change\n",
                encoding="utf-8",
            )
            with (
                mock.patch.object(provision, "ARMBIAN_ROOT", armbian),
                self.assertRaisesRegex(
                    provision.ProvisioningError,
                    "lib/functions/cli/commands.sh",
                ),
            ):
                provision.require_clean_armbian_source(commit)

    def test_wait_for_enrolled_node_requires_roles_and_redacts_failure_logs(self) -> None:
        ready = {
            "metadata": {
                "name": "node-a1b2c3",
                "labels": {
                    "node-role.kubernetes.io/control-plane": "true",
                    "node-role.kubernetes.io/etcd": "true",
                },
            },
            "status": {"conditions": [{"type": "Ready", "status": "True"}]},
        }
        with mock.patch.object(
            provision, "run", return_value=subprocess.CompletedProcess([], 0, json.dumps(ready), "")
        ):
            provision.wait_for_enrolled_node("node-a1b2c3", "host", "secret-token", timeout=0)

        results = [
            subprocess.CompletedProcess([], 0, "", ""),
            subprocess.CompletedProcess([], 0, "failed secret-token", ""),
        ]
        with (
            mock.patch.object(provision, "run", side_effect=results),
            self.assertRaises(provision.ProvisioningError) as raised,
        ):
            provision.wait_for_enrolled_node("node-a1b2c3", "host", "secret-token", timeout=0)
        self.assertNotIn("secret-token", str(raised.exception))
        self.assertIn("<redacted>", str(raised.exception))

        boundary_token = "boundary-secret-token"
        crossing_log = "x" * 10 + boundary_token + "z" * 7995
        crossing_results = [
            subprocess.CompletedProcess([], 0, "", ""),
            subprocess.CompletedProcess([], 0, crossing_log, ""),
        ]
        with (
            mock.patch.object(provision, "run", side_effect=crossing_results),
            self.assertRaises(provision.ProvisioningError) as crossing,
        ):
            provision.wait_for_enrolled_node(
                "node-a1b2c3", "host", boundary_token, timeout=0
            )
        self.assertNotIn(boundary_token[-5:], str(crossing.exception))

    def test_build_plan_commit_is_stable_through_finalisation(self) -> None:
        commit = "1" * 40
        with (
            mock.patch.object(provision, "resolve_k3s_version", return_value="v1.36.3+k3s1"),
            mock.patch.object(provision, "armbian_commit", return_value="2" * 40),
            mock.patch.object(provision, "repo_commit", return_value=commit),
        ):
            plan = provision.build_plan()
        self.assertEqual(plan["home_ops_commit"], commit)

        with (
            mock.patch.object(provision, "repo_commit", return_value="3" * 40),
            self.assertRaisesRegex(provision.ProvisioningError, "HEAD changed"),
        ):
            provision.require_build_inputs_unchanged(plan)

        events: list[str] = []

        def check(_: dict[str, object]) -> None:
            events.append("check")

        def run(*_: object, **__: object) -> subprocess.CompletedProcess[str]:
            events.append("build")
            return subprocess.CompletedProcess([], 0, "", "")

        def write(*_: object, **__: object) -> Path:
            events.append("write")
            return Path("artifact.img.xz")

        with (
            mock.patch.object(provision, "build_plan", return_value=plan),
            mock.patch.object(provision, "require_program"),
            mock.patch.object(provision, "docker_doctor"),
            mock.patch.object(provision, "initialise_pinned_submodule"),
            mock.patch.object(provision, "require_build_inputs_unchanged", side_effect=check),
            mock.patch.object(provision, "stage_k3s_payloads", return_value={}),
            mock.patch.object(provision, "injected_userpatches", return_value=contextlib.nullcontext()),
            mock.patch.object(provision, "run", side_effect=run),
            mock.patch.object(provision, "write_artifacts", side_effect=write),
            mock.patch("builtins.print"),
        ):
            provision.build(Namespace(dry_run=False, verbose=False))
        self.assertEqual(events, ["check", "build", "check", "write"])

    def test_build_finalises_after_real_userpatches_restoration(self) -> None:
        plan = {
            "k3s": {"version": "v1.36.3+k3s1"},
            "home_ops_commit": "1" * 40,
            "armbian_commit": "2" * 40,
            "build_parameters": provision.BUILD_PARAMETERS,
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            armbian = root / "armbian"
            original = armbian / "userpatches"
            original.mkdir(parents=True)
            marker = original / "ignored.conf"
            marker.write_text("original\n", encoding="utf-8")
            source = root / "source-userpatches"
            source.mkdir()
            binary = root / "k3s-arm64"
            airgap = root / "k3s-airgap-images-arm64.tar"
            binary.write_bytes(b"binary")
            airgap.write_bytes(b"airgap")
            payloads = {"binary": binary, "airgap": airgap}
            events: list[str] = []

            def check(_: dict[str, object]) -> None:
                events.append("check")
                self.assertEqual(marker.read_text(encoding="utf-8"), "original\n")
                self.assertFalse(
                    any(
                        path.name.startswith(".userpatches-backup-")
                        for path in armbian.iterdir()
                    )
                )

            def run(*_: object, **__: object) -> subprocess.CompletedProcess[str]:
                events.append("build")
                return subprocess.CompletedProcess([], 0, "", "")

            def write(*_: object, **__: object) -> Path:
                events.append("write")
                self.assertEqual(marker.read_text(encoding="utf-8"), "original\n")
                return Path("artifact.img.xz")

            with (
                mock.patch.object(provision, "ARMBIAN_ROOT", armbian),
                mock.patch.object(provision, "USERPATCHES_ROOT", source),
                mock.patch.object(provision, "build_plan", return_value=plan),
                mock.patch.object(provision, "require_program"),
                mock.patch.object(provision, "docker_doctor"),
                mock.patch.object(provision, "initialise_pinned_submodule"),
                mock.patch.object(
                    provision, "require_build_inputs_unchanged", side_effect=check
                ),
                mock.patch.object(
                    provision, "stage_k3s_payloads", return_value=payloads
                ),
                mock.patch.object(provision, "run", side_effect=run),
                mock.patch.object(provision, "write_artifacts", side_effect=write),
                mock.patch("builtins.print"),
            ):
                provision.build(Namespace(dry_run=False, verbose=False))

            self.assertEqual(events, ["check", "build", "check", "write"])
            self.assertEqual(marker.read_text(encoding="utf-8"), "original\n")

            events.clear()

            def failing_run(*_: object, **__: object) -> NoReturn:
                events.append("build")
                raise RuntimeError("original build error")

            with (
                mock.patch.object(provision, "ARMBIAN_ROOT", armbian),
                mock.patch.object(provision, "USERPATCHES_ROOT", source),
                mock.patch.object(provision, "build_plan", return_value=plan),
                mock.patch.object(provision, "require_program"),
                mock.patch.object(provision, "docker_doctor"),
                mock.patch.object(provision, "initialise_pinned_submodule"),
                mock.patch.object(
                    provision, "require_build_inputs_unchanged", side_effect=check
                ),
                mock.patch.object(
                    provision, "stage_k3s_payloads", return_value=payloads
                ),
                mock.patch.object(provision, "run", side_effect=failing_run),
                mock.patch.object(provision, "write_artifacts") as finalise,
                self.assertRaisesRegex(RuntimeError, "original build error"),
            ):
                provision.build(Namespace(dry_run=False, verbose=False))

            finalise.assert_not_called()
            self.assertEqual(events, ["check", "build"])
            self.assertEqual(marker.read_text(encoding="utf-8"), "original\n")

    def test_artifact_set_is_immutable_and_records_full_commit(self) -> None:
        timestamp = dt.datetime(2026, 8, 30, 12, 0, tzinfo=dt.UTC)
        commit = "a" * 40
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            armbian = root / "armbian"
            output = armbian / "output/images"
            output.mkdir(parents=True)
            artifacts = root / "artifacts"
            artifacts.mkdir()
            candidate = output / "build.img.xz"
            candidate.write_bytes(b"image")
            binary = root / "k3s-arm64"
            airgap = root / "k3s-airgap-images-arm64.tar"
            binary.write_bytes(b"binary")
            airgap.write_bytes(b"airgap")
            release_id = f"radxa-5b-plus-20260830-{commit[:12]}"
            (artifacts / f"{release_id}.manifest.json").write_text("existing\n", encoding="utf-8")
            with (
                mock.patch.object(provision, "ARMBIAN_ROOT", armbian),
                mock.patch.object(provision, "ARTIFACTS_ROOT", artifacts),
                mock.patch.object(provision, "repo_commit", return_value=commit),
                self.assertRaisesRegex(provision.ProvisioningError, "already exists"),
            ):
                provision.write_artifacts(
                    {
                        "k3s": {"version": "v1.36.3+k3s1"},
                        "home_ops_commit": commit,
                        "armbian_commit": "b" * 40,
                    },
                    {"binary": binary, "airgap": airgap},
                    built_after=0,
                    timestamp=timestamp,
                )
            self.assertTrue(candidate.exists())

            (artifacts / f"{release_id}.manifest.json").unlink()
            with (
                mock.patch.object(provision, "ARMBIAN_ROOT", armbian),
                mock.patch.object(provision, "ARTIFACTS_ROOT", artifacts),
                mock.patch.object(provision, "repo_commit") as current_commit,
            ):
                image = provision.write_artifacts(
                    {
                        "k3s": {"version": "v1.36.3+k3s1"},
                        "home_ops_commit": commit,
                        "armbian_commit": "b" * 40,
                    },
                    {"binary": binary, "airgap": airgap},
                    built_after=0,
                    timestamp=timestamp,
                )
            current_commit.assert_not_called()
            manifest = image.with_name(f"{release_id}.manifest.json")
            data = json.loads(manifest.read_text(encoding="utf-8"))
            self.assertEqual(data["home_ops_commit"], commit)

            second_candidate = output / "second-build.img.xz"
            second_candidate.write_bytes(b"different image")
            with (
                mock.patch.object(provision, "ARMBIAN_ROOT", armbian),
                mock.patch.object(provision, "ARTIFACTS_ROOT", artifacts),
                mock.patch.object(provision, "repo_commit", return_value=commit),
                self.assertRaisesRegex(provision.ProvisioningError, "already exists"),
            ):
                provision.write_artifacts(
                    {
                        "k3s": {"version": "v1.36.3+k3s1"},
                        "home_ops_commit": commit,
                        "armbian_commit": "b" * 40,
                    },
                    {"binary": binary, "airgap": airgap},
                    built_after=0,
                    timestamp=timestamp,
                )
            self.assertTrue(second_candidate.exists())

    def test_full_image_verifier_returns_report_without_exporting_rootfs(self) -> None:
        source = inspect.getsource(provision.inspect_image_rootfs)
        self.assertNotIn("cp -a", source)
        self.assertNotIn("/inspection/rootfs", source)
        self.assertIn("mount -o ro,noload", source)
        self.assertIn("trap cleanup", source)
        self.assertNotIn("fixture", inspect.signature(provision.rootfs_report).parameters)
        script = re.search(r"script = r'''(.*?)'''", source, re.DOTALL)
        self.assertIsNotNone(script)
        syntax = subprocess.run(
            ["bash", "-n"], input=script.group(1), capture_output=True, text=True
        )
        self.assertEqual(syntax.returncode, 0, syntax.stderr)
        lint = subprocess.run(
            ["shellcheck", "-s", "bash", "-"],
            input=script.group(1),
            capture_output=True,
            text=True,
        )
        self.assertEqual(lint.returncode, 0, lint.stdout + lint.stderr)

    def test_full_image_verifier_parses_only_the_container_json_report(self) -> None:
        expected = {"status": "pass", "checks": {"rootfs_identity": {"status": "pass"}}}
        commands: list[list[str]] = []

        def run(command: list[str], **_: object) -> subprocess.CompletedProcess[str]:
            commands.append([str(part) for part in command])
            return subprocess.CompletedProcess(command, 0, json.dumps(expected), "")

        with (
            mock.patch.object(provision, "require_program"),
            mock.patch.object(provision, "xz_uncompressed_size", return_value=1),
            mock.patch.object(provision.shutil, "disk_usage", return_value=mock.Mock(free=2 * 1024**3)),
            mock.patch.object(provision.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)),
            mock.patch.object(provision, "run", side_effect=run),
        ):
            report = provision.inspect_image_rootfs(Path("fixture.img.xz"), {"schema_version": 1})

        self.assertEqual(report, expected)
        docker_command = commands[0]
        mounts = [docker_command[index + 1] for index, value in enumerate(docker_command) if value == "-v"]
        self.assertEqual(len(mounts), 3)
        self.assertTrue(all(mount.endswith(":ro") for mount in mounts))
        targets = {mount.rsplit(":", 2)[-2] for mount in mounts}
        self.assertEqual(
            targets,
            {"/image.img", "/verifier/manifest.json", "/verifier/provision.py"},
        )

    def write_artifact_set(self, root: Path) -> Path:
        release_id = "radxa-5b-plus-20260830-0123456789ab"
        image = root / f"{release_id}.img.xz"
        image.write_bytes(b"test image")
        digest = provision.sha256(image)
        checksum = root / f"{image.name}.sha256"
        checksum.write_text(f"{digest}  {image.name}\n", encoding="utf-8")
        manifest = root / f"{release_id}.manifest.json"
        manifest.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "release_id": release_id,
                    "timestamp": "2026-08-30T12:00:00Z",
                    "home_ops_commit": "0123456789ab" + "0" * 28,
                    "k3s_version": "v1.33.4+k3s1",
                    "armbian_commit": "a" * 40,
                    "board": provision.BUILD_PARAMETERS["BOARD"],
                    "branch": provision.BUILD_PARAMETERS["BRANCH"],
                    "release": provision.BUILD_PARAMETERS["RELEASE"],
                    "build_parameters": provision.BUILD_PARAMETERS,
                    "files": {
                        "image": {"filename": image.name, "sha256": digest},
                        "checksum": {"filename": checksum.name},
                        "manifest": {"filename": manifest.name},
                        "k3s_binary": {"filename": "k3s-arm64", "sha256": "b" * 64},
                        "k3s_airgap": {
                            "filename": "k3s-airgap-images-arm64.tar",
                            "sha256": "c" * 64,
                        },
                    },
                }
            ),
            encoding="utf-8",
        )
        return image

    def test_manifest_release_id_and_sidecar_filename_are_authoritative(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            image = self.write_artifact_set(Path(temporary))
            manifest = image.with_name(
                image.name.removesuffix(".img.xz") + ".manifest.json"
            )
            data = json.loads(manifest.read_text(encoding="utf-8"))
            data["release_id"] = "radxa-5b-plus-20260830-deadbeef"
            manifest.write_text(json.dumps(data), encoding="utf-8")
            with (
                mock.patch.object(provision, "resolve_k3s_version", return_value="v1.33.4+k3s1"),
                mock.patch.object(provision, "armbian_commit", return_value="a" * 40),
                self.assertRaises(provision.ProvisioningError),
            ):
                provision.validate_artifacts(image)

            data["release_id"] = image.name.removesuffix(".img.xz")
            data["home_ops_commit"] = "f" * 40
            manifest.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaisesRegex(
                provision.ProvisioningError, "home-ops commit"
            ):
                provision.validate_artifacts(image)

            data["home_ops_commit"] = "0123456789ab" + "0" * 28
            manifest.write_text(json.dumps(data), encoding="utf-8")
            image.with_name(f"{image.name}.sha256").write_text(
                f"{provision.sha256(image)}  wrong.img.xz\n", encoding="utf-8"
            )
            with self.assertRaises(provision.ProvisioningError):
                provision.validate_artifacts(image)

    def test_enrol_dry_run_checks_target_without_reading_token(self) -> None:
        calls: list[tuple[str, str]] = []

        def ssh_read(host: str, command: str) -> str:
            calls.append((host, command))
            responses = {
                ("new-node", "hostname -s"): "node-a1b2c3",
                ("new-node", "sudo -n true"): "",
                ("new-node", "test -s /etc/machine-id"): "",
                ("new-node", "cloud-init status --wait"): "status: done",
                ("new-node", "sudo /usr/local/bin/k3s --version"): "k3s version v1.33.4+k3s1",
                ("new-node", "systemctl is-enabled k3s.service 2>/dev/null || true"): "disabled",
                ("new-node", "systemctl is-active k3s.service 2>/dev/null || true"): "inactive",
                ("source", "sudo cat /etc/rancher/k3s/config.yaml"): "disable: [traefik]\n",
                ("source", "sudo cat /var/lib/rancher/k3s/server/token"): "secret",
            }
            if command.startswith("sudo test ! -e"):
                return ""
            return responses[(host, command)]

        source = {"metadata": {"name": "source"}, "status": {}}
        completed = subprocess.CompletedProcess([], 0, "", "")
        with (
            mock.patch.object(provision, "run", return_value=completed),
            mock.patch.object(provision, "ready_control_planes", return_value=[source]),
            mock.patch.object(provision, "node_address", return_value="source"),
            mock.patch.object(provision, "ssh_read", side_effect=ssh_read),
            mock.patch.object(provision, "resolve_k3s_version", return_value="v1.33.4+k3s1"),
            mock.patch.object(provision, "current_api_endpoint", return_value="https://cluster:6443"),
            mock.patch.object(provision, "sanitise_k3s_config", return_value="server: https://cluster:6443\n"),
            mock.patch("builtins.print"),
        ):
            provision.enrol(Namespace(host="new-node", source_node=None, replace=False, dry_run=True))

        self.assertTrue(any(command.startswith("sudo test ! -e") for _, command in calls))
        self.assertFalse(
            any(command == "sudo cat /var/lib/rancher/k3s/server/token" for _, command in calls)
        )

    def test_enrol_replace_refuses_ready_and_confirms_notready_before_secrets(self) -> None:
        ready = {
            "metadata": {"name": "node-a1b2c3", "uid": "ready"},
            "status": {"conditions": [{"type": "Ready", "status": "True"}]},
        }
        not_ready = {
            "metadata": {"name": "node-a1b2c3", "uid": "old"},
            "status": {"conditions": [{"type": "Ready", "status": "False"}]},
        }
        source = {"metadata": {"name": "source"}, "status": {}}

        with (
            mock.patch.object(provision, "run", return_value=subprocess.CompletedProcess([], 0, "", "")),
            mock.patch.object(provision, "ready_control_planes", return_value=[source]),
            mock.patch.object(provision, "node_address", return_value="source"),
            mock.patch.object(provision, "ssh_read", return_value="node-a1b2c3"),
            mock.patch.object(provision, "existing_node", return_value=ready),
            mock.patch("builtins.print"),
            self.assertRaisesRegex(provision.ProvisioningError, "Ready"),
        ):
            provision.enrol(
                Namespace(host="new-node", source_node=None, replace=True, dry_run=False)
            )

        events: list[str] = []

        def ssh_read(host: str, command: str) -> str:
            events.append(command)
            responses = {
                "hostname -s": "node-a1b2c3",
                "sudo -n true": "",
                "test -s /etc/machine-id": "",
                "cloud-init status --wait": "status: done",
                "sudo /usr/local/bin/k3s --version": "k3s version v1.33.4+k3s1",
                "systemctl is-enabled k3s.service 2>/dev/null || true": "disabled",
                "systemctl is-active k3s.service 2>/dev/null || true": "inactive",
                "sudo cat /etc/rancher/k3s/config.yaml": "disable: [traefik]\n",
                "sudo cat /var/lib/rancher/k3s/server/token": "secret-token",
            }
            if command.startswith("sudo test ! -e"):
                return ""
            return responses[command]

        def run(command: list[str], **_: object) -> subprocess.CompletedProcess[str]:
            events.append(" ".join(str(part) for part in command))
            return subprocess.CompletedProcess(command, 0, "", "")

        def confirm(_: str) -> str:
            events.append("confirmation")
            return "replace node-a1b2c3"

        with (
            mock.patch.object(provision, "run", side_effect=run),
            mock.patch.object(provision, "ready_control_planes", return_value=[source]),
            mock.patch.object(provision, "node_address", return_value="source"),
            mock.patch.object(provision, "ssh_read", side_effect=ssh_read),
            mock.patch.object(provision, "existing_node", return_value=not_ready),
            mock.patch.object(provision, "resolve_k3s_version", return_value="v1.33.4+k3s1"),
            mock.patch.object(provision, "current_api_endpoint", return_value="https://cluster:6443"),
            mock.patch.object(provision, "sanitise_k3s_config", return_value="server: https://cluster:6443\n"),
            mock.patch.object(provision, "wait_for_enrolled_node"),
            mock.patch("builtins.input", side_effect=confirm),
            mock.patch("builtins.print"),
        ):
            provision.enrol(
                Namespace(host="new-node", source_node=None, replace=True, dry_run=False)
            )

        confirmation = events.index("confirmation")
        token = events.index("sudo cat /var/lib/rancher/k3s/server/token")
        deletion = events.index("kubectl delete node node-a1b2c3")
        self.assertLess(confirmation, token)
        self.assertLess(confirmation, deletion)

    def test_enrol_replace_dry_run_emits_one_json_document(self) -> None:
        not_ready = {
            "metadata": {"name": "node-a1b2c3", "uid": "old"},
            "spec": {"unschedulable": True},
            "status": {"conditions": [{"type": "Ready", "status": "False"}]},
        }
        source = {"metadata": {"name": "source"}, "status": {}}
        responses = {
            "hostname -s": "node-a1b2c3",
            "sudo -n true": "",
            "test -s /etc/machine-id": "",
            "cloud-init status --wait": "status: done",
            "sudo /usr/local/bin/k3s --version": "k3s version v1.33.4+k3s1",
            "systemctl is-enabled k3s.service 2>/dev/null || true": "disabled",
            "systemctl is-active k3s.service 2>/dev/null || true": "inactive",
        }

        def ssh_read(_: str, command: str) -> str:
            if command.startswith("sudo test ! -e"):
                return ""
            return responses[command]

        output = io.StringIO()
        with (
            mock.patch.object(provision, "run", return_value=subprocess.CompletedProcess([], 0, "", "")),
            mock.patch.object(provision, "ready_control_planes", return_value=[source]),
            mock.patch.object(provision, "node_address", return_value="source"),
            mock.patch.object(provision, "ssh_read", side_effect=ssh_read),
            mock.patch.object(provision, "existing_node", return_value=not_ready),
            mock.patch.object(provision, "resolve_k3s_version", return_value="v1.33.4+k3s1"),
            contextlib.redirect_stdout(output),
        ):
            provision.enrol(
                Namespace(host="new-node", source_node=None, replace=True, dry_run=True)
            )

        plan = json.loads(output.getvalue())
        self.assertEqual(plan["replacement"]["uid"], "old")
        self.assertFalse(plan["replacement"]["ready"])

    def test_retire_stops_k3s_before_deleting_node_and_state(self) -> None:
        commands: list[list[str]] = []

        def run(command: list[str], **_: object) -> subprocess.CompletedProcess[str]:
            commands.append([str(part) for part in command])
            return subprocess.CompletedProcess(command, 0, "", "")

        with (
            mock.patch.object(
                provision,
                "ssh_read",
                side_effect=["node-a1b2c3", "", ""],
            ),
            mock.patch.object(provision, "run", side_effect=run),
            mock.patch("builtins.input", return_value="node-a1b2c3"),
        ):
            provision.retire(
                Namespace(node="node-a1b2c3", host="node-a1b2c3", dry_run=False)
            )

        rendered = [" ".join(command) for command in commands]
        self.assertLess(
            next(i for i, command in enumerate(rendered) if "kubectl drain" in command),
            next(i for i, command in enumerate(rendered) if "systemctl disable" in command),
        )
        self.assertLess(
            next(i for i, command in enumerate(rendered) if "systemctl disable" in command),
            next(i for i, command in enumerate(rendered) if "kubectl delete node" in command),
        )
        self.assertLess(
            next(i for i, command in enumerate(rendered) if "kubectl delete node" in command),
            next(i for i, command in enumerate(rendered) if "rm -rf" in command),
        )


class ImageSecurityContractsTest(unittest.TestCase):
    def test_enabled_first_boot_paths_do_not_download_keys_or_start_k3s(self) -> None:
        first_boot_text = "\n".join(first_boot_execution_sources().values())
        key_download = (
            r"(?im)\b(?:curl|wget|aria2c|fetch|ftp|busybox\s+wget|"
            r"python(?:3)?\s+-c[^\n]*(?:urllib|requests))\b[^\n]*"
            r"(authorized_keys|\.keys\b|ssh-ed25519)"
        )

        with self.subTest(contract="SSH key download"):
            self.assertNotRegex(first_boot_text, key_download)
        with self.subTest(contract="automatic K3s startup or join"):
            self.assertEqual(automatic_k3s_startup_violations(), {})
        with self.subTest(contract="build-time K3s service activation"):
            self.assertEqual(build_time_k3s_startup_violations(), {})

    @staticmethod
    def write_overlay_file(overlay_root: Path, relative_path: str, content: str) -> Path:
        path = overlay_root / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        return path

    def test_first_boot_scan_covers_activation_forms_but_allows_a_dormant_unit(
        self,
    ) -> None:
        unit_path = "etc/systemd/system/k3s.service"
        unit = "[Service]\nExecStart=/usr/local/bin/k3s server\n"

        with tempfile.TemporaryDirectory() as temporary:
            overlay_root = Path(temporary)
            self.write_overlay_file(overlay_root, unit_path, unit)
            self.assertEqual(automatic_k3s_startup_violations(overlay_root), {})

        activation_files = {
            "systemctl enable --now": (
                "var/lib/cloud/seed/nocloud/user-data",
                "#cloud-config\nruncmd:\n  - systemctl enable --now k3s.service\n",
            ),
            "systemctl start": (
                "var/lib/cloud/seed/nocloud/user-data",
                "#cloud-config\nruncmd:\n  - systemctl start k3s.service\n",
            ),
            "service start": (
                "var/lib/cloud/seed/nocloud/user-data",
                "#cloud-config\nruncmd:\n  - service k3s start\n",
            ),
            "direct cloud-init K3s start": (
                "var/lib/cloud/seed/nocloud/user-data",
                "#cloud-config\nruncmd:\n"
                "  - /usr/local/bin/k3s agent "
                "--server https://192.0.2.10:6443\n",
            ),
            "systemd preset": (
                "etc/systemd/system-preset/90-k3s.preset",
                "enable k3s.service\n",
            ),
        }

        for activation, (relative_path, content) in activation_files.items():
            with self.subTest(activation=activation), tempfile.TemporaryDirectory() as temporary:
                overlay_root = Path(temporary)
                self.write_overlay_file(overlay_root, unit_path, unit)
                self.write_overlay_file(overlay_root, relative_path, content)
                self.assertTrue(automatic_k3s_startup_violations(overlay_root))

        with (
            self.subTest(activation="systemd wants symlink"),
            tempfile.TemporaryDirectory() as temporary,
        ):
            overlay_root = Path(temporary)
            unit_file = self.write_overlay_file(overlay_root, unit_path, unit)
            wants = overlay_root / "etc/systemd/system/multi-user.target.wants/k3s.service"
            wants.parent.mkdir(parents=True, exist_ok=True)
            wants.symlink_to(unit_file)
            self.assertTrue(automatic_k3s_startup_violations(overlay_root))

    def test_build_input_scan_detects_activation_but_allows_a_dormant_unit(
        self,
    ) -> None:
        unit_path = Path("userpatches/overlay/etc/systemd/system/k3s.service")
        dormant_unit = "[Service]\nExecStart=/usr/local/bin/k3s server\n"
        self.assertEqual(
            build_time_k3s_startup_violations({unit_path: dormant_unit}),
            {},
        )

        activation_commands = {
            "systemctl enable": "systemctl enable k3s.service\n",
            "systemctl enable --now": "systemctl enable --now k3s.service\n",
            "systemctl start": "systemctl start k3s.service\n",
        }
        for activation, command in activation_commands.items():
            with self.subTest(activation=activation):
                build_script = Path("userpatches/customize-image.sh")
                violations = build_time_k3s_startup_violations(
                    {unit_path: dormant_unit, build_script: command}
                )
                self.assertEqual(violations, {build_script: ["k3s.service"]})

    def test_image_does_not_bake_cluster_enrolment_or_insecure_k3s_settings(self) -> None:
        prohibited = {
            "NFS token retrieval": (
                r"(?i)(nfs-token|token-file:|mount\s+-t\s+nfs|NFS_(SERVER|SHARE)|"
                r"(?:cat|curl|wget)\b[^\n]*cluster-token)"
            ),
            "K3S_DATA partitioning": r"K3S_DATA",
            "anonymous Kubernetes API authentication": r"anonymous-auth(?:=|:\s*)true",
            "world-readable kubeconfig": (
                r"(?i)(write-kubeconfig-mode:\s*0?644\b|--write-kubeconfig-mode"
                r"(?:=|\s+)0?644\b|chmod\s+0?644\s+[^\n]*(kubeconfig|k3s\.yaml))"
            ),
        }
        source_text = "\n".join(image_build_inputs().values())

        for contract, pattern in prohibited.items():
            with self.subTest(contract=contract):
                self.assertNotRegex(source_text, pattern)


class K3sBuildContractsTest(unittest.TestCase):
    def test_build_dry_run_reports_plan_versioned_k3s_artifacts(self) -> None:
        plan_versions = re.findall(
            r"(?m)^\s*version:\s*(v\d+\.\d+\.\d+\+k3s\d+)\s*$",
            read_text(K3S_PLAN),
        )
        self.assertEqual(len(set(plan_versions)), 1)
        version = plan_versions[0]

        result = subprocess.run(
            ["mise", "run", "provisioning:build", "--", "--dry-run"],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(result.stdout)
        k3s = plan["k3s"]
        release_url = (
            "https://github.com/k3s-io/k3s/releases/download/"
            f"{quote(version, safe='v')}/"
        )

        self.assertEqual(k3s["version"], version)
        self.assertEqual(k3s["binary_url"], f"{release_url}k3s-arm64")
        self.assertEqual(
            k3s["airgap_url"], f"{release_url}k3s-airgap-images-arm64.tar"
        )
        self.assertEqual(plan["build_parameters"]["FIXED_IMAGE_SIZE"], "3072")

    def test_image_bootstrap_is_one_shot_and_k3s_requires_enrolment_files(self) -> None:
        user_data = read_text(
            OVERLAY_ROOT / "var/lib/cloud/seed/nocloud/user-data"
        )
        unit = read_text(OVERLAY_ROOT / "etc/systemd/system/k3s.service")
        gitignore = read_text(REPO_ROOT / ".gitignore")

        self.assertIn("cloud-init-per", user_data)
        self.assertIn("once", user_data)
        self.assertIn("ConditionPathExists=/etc/rancher/k3s/config.yaml", unit)
        self.assertIn("ConditionPathExists=/etc/rancher/k3s/cluster-token", unit)
        self.assertIn("provisioning/artifacts/", gitignore)
        self.assertIn("provisioning/armbian-build/.staging/", gitignore)

    def test_provisioning_build_sources_have_no_independent_k3s_version(self) -> None:
        independent_versions = {
            str(path.relative_to(REPO_ROOT)): semantic_k3s_version_literals(text)
            for path, text in provisioning_build_sources().items()
            if semantic_k3s_version_literals(text)
        }
        self.assertEqual(
            independent_versions,
            {},
            "Provisioning build tasks and their reachable local helpers must "
            "derive the K3s version from the cluster Plan",
        )

    def test_independent_k3s_version_scan_ignores_comments_and_diagnostics(self) -> None:
        diagnostic_text = """
# K3S_VERSION=v1.31.4+k3s1
echo "Found old K3s v1.31.4+k3s1"
printf 'Diagnostic URL: %s\\n' 'https://github.com/k3s-io/k3s/releases/download/v1.31.4+k3s1/k3s-arm64'
description: "Migration note for v1.31.4+k3s1"
"""
        self.assertEqual(semantic_k3s_version_literals(diagnostic_text), [])

        semantic_inputs = {
            "assignment": 'K3S_VERSION="v1.31.4+k3s1"',
            "build argument": "docker build --build-arg K3S_VERSION=v1.32.1+k3s1 .",
            "config value": 'k3s_version: "v1.33.2+k3s1"',
            "quoted config value": '"k3s_version" = "v1.33.3+k3s1"',
            "artefact URL": (
                '"url": "https://github.com/k3s-io/k3s/releases/download/'
                'v1.34.0%2Bk3s1/k3s-airgap-images-arm64.tar"'
            ),
        }
        for source, text in semantic_inputs.items():
            with self.subTest(source=source):
                self.assertTrue(semantic_k3s_version_literals(text))


class KuredContractsTest(unittest.TestCase):
    def test_kured_reboots_are_unrestricted_one_at_a_time_and_alert_on_readiness(self) -> None:
        helmrelease = rendered_yaml(KURED_HELMRELEASE)
        values = helmrelease["spec"]["values"]
        rules = rendered_yaml(KURED_RULES)["spec"]["groups"]
        alerts = [rule for group in rules for rule in group["rules"]]
        alerts_by_name = {alert["alert"]: alert for alert in alerts}
        readiness_alert = alerts_by_name["KuredDaemonSetNotReady"]
        expression = readiness_alert["expr"]
        flat_expression = " ".join(expression.split())
        desired_selector = (
            'kube_daemonset_status_desired_number_scheduled'
            '{namespace="kube-system", daemonset="kured"}'
        )
        ready_selector = (
            'kube_daemonset_status_number_ready'
            '{namespace="kube-system", daemonset="kured"}'
        )
        desired_vector = f"max by (namespace, daemonset) ({desired_selector})"
        ready_vector = f"max by (namespace, daemonset) ({ready_selector})"

        expected_matchers = [
            ("daemonset", "=", "kured"),
            ("namespace", "=", "kube-system"),
        ]
        for metric in (
            "kube_daemonset_status_desired_number_scheduled",
            "kube_daemonset_status_number_ready",
        ):
            selectors = re.findall(rf"{metric}\{{([^}}]+)\}}", expression)
            with self.subTest(contract=f"exact selectors for {metric}"):
                self.assertTrue(selectors)
                for selector in selectors:
                    matchers = sorted(
                        re.findall(
                            r'([a-zA-Z_][a-zA-Z0-9_]*)\s*(=~|!~|!=|=)\s*"([^"]*)"',
                            selector,
                        )
                    )
                    self.assertEqual(matchers, expected_matchers)

        contracts = {
            "no custom reboot selector": lambda: self.assertNotIn("nodeSelector", values),
            "preserved maintenance configuration": lambda: self.assertEqual(
                values["configuration"],
                {
                    "concurrency": 1,
                    "startTime": "7:00",
                    "endTime": "12:00",
                    "period": "10m",
                    "timeZone": "Europe/London",
                },
            ),
            "preserved service settings": lambda: self.assertEqual(
                values["service"], {"ipFamilyPolicy": "preferDualStack"}
            ),
            "preserved metrics settings": lambda: self.assertEqual(
                values["metrics"], {"create": False}
            ),
            "preserved resources": lambda: self.assertEqual(
                values["resources"],
                {
                    "requests": {"cpu": "15m", "memory": "20Mi"},
                    "limits": {"memory": "40Mi"},
                },
            ),
            "preserved TZ environment": lambda: self.assertEqual(
                values["extraEnvVars"], [{"name": "TZ", "value": "Europe/London"}]
            ),
            "no RebootScheduled alert": lambda: self.assertNotIn(
                "RebootScheduled", alerts_by_name
            ),
            "RebootRequired keeps 24 hour delay": lambda: self.assertEqual(
                alerts_by_name["RebootRequired"]["for"], "24h"
            ),
            "readiness compares desired and ready": lambda: self.assertIn(
                f"{desired_vector} != {ready_vector}", flat_expression
            ),
            "missing ready series alerts": lambda: self.assertIn(
                f"{desired_vector} unless on (namespace, daemonset) {ready_vector}",
                flat_expression,
            ),
            "missing desired series alerts": lambda: self.assertIn(
                f"{ready_vector} unless on (namespace, daemonset) {desired_vector}",
                flat_expression,
            ),
            "total metric loss is not Kured-specific": lambda: self.assertNotRegex(
                expression, r"\babsent\s*\("
            ),
            "readiness alert waits 15 minutes": lambda: self.assertEqual(
                readiness_alert["for"], "15m"
            ),
            "readiness alert is warning": lambda: self.assertEqual(
                readiness_alert["labels"].get("severity"), "warning"
            ),
        }

        for contract, assertion in contracts.items():
            with self.subTest(contract=contract):
                assertion()


class MigrationRemovalContractsTest(unittest.TestCase):
    def test_ansible_code_and_root_task_entry_points_are_removed(self) -> None:
        taskfiles = [REPO_ROOT / "Taskfile.yaml", *REPO_ROOT.glob(".taskfiles/**/Taskfile.yaml")]
        taskfile_references = {
            str(path.relative_to(REPO_ROOT))
            for path in taskfiles
            if re.search(r"(?i)\bansible\b", read_text(path))
        }
        contracts = {
            "Ansible code": lambda: self.assertFalse((REPO_ROOT / "ansible").exists()),
            "Ansible taskfiles": lambda: self.assertFalse(
                (REPO_ROOT / ".taskfiles/Ansible").exists()
            ),
            "Taskfile references": lambda: self.assertEqual(taskfile_references, set()),
        }

        for contract, assertion in contracts.items():
            with self.subTest(contract=contract):
                assertion()

    def test_destructive_helpers_do_not_use_global_docker_prune(self) -> None:
        roots = [
            REPO_ROOT / "Taskfile.yaml",
            REPO_ROOT / ".mise",
            REPO_ROOT / ".taskfiles",
            REPO_ROOT / "provisioning",
            REPO_ROOT / "scripts",
        ]
        prune_pattern = re.compile(
            r"(?i)(?:\bcommand\s+)?\bdocker(?:\s+--[^\s]+(?:\s+[^\s]+)?)*\s+"
            r"(?:system|container|image|volume|network)\s+prune\b"
        )
        violations = []

        for root in roots:
            paths = [root] if root.is_file() else root.rglob("*") if root.exists() else []
            for path in paths:
                if path.is_file() and path.suffix in {"", ".py", ".sh", ".toml", ".yaml", ".yml"}:
                    if prune_pattern.search(read_text(path)):
                        violations.append(str(path.relative_to(REPO_ROOT)))

        self.assertEqual(violations, [])


if __name__ == "__main__":
    unittest.main()
