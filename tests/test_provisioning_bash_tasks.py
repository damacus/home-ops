from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
DOCTOR = REPO_ROOT / ".mise/tasks/provisioning/docker/doctor"
USAGE = REPO_ROOT / ".mise/tasks/provisioning/docker/usage"


def write_executable(path: Path, contents: str) -> None:
    path.write_text(contents, encoding="utf-8")
    path.chmod(0o755)


def test_docker_doctor_reports_all_checks_on_failure(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    write_executable(
        bin_dir / "docker",
        "#!/bin/sh\nprintf '%s\\n' '{\"Architecture\":\"amd64\",\"MemTotal\":1}'\n",
    )
    write_executable(bin_dir / "df", "#!/bin/sh\nprintf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\n/dev 1 1 1 99%% /\\n'\n")
    environment = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "HOME": str(tmp_path)}
    result = subprocess.run([str(DOCTOR)], env=environment, capture_output=True, text=True)
    assert result.returncode != 0
    for field in ("cli", "daemon", "architecture", "memory", "host_space"):
        assert f" {field}:" in result.stdout
    assert "Docker preflight failed" in result.stderr


def test_docker_doctor_success_reports_all_checks(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    write_executable(
        bin_dir / "docker",
        "#!/bin/sh\nprintf '%s\\n' '{\"Architecture\":\"arm64\",\"MemTotal\":8053063680}'\n",
    )
    write_executable(bin_dir / "df", "#!/bin/sh\nprintf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\n/dev 1 1 52428800 1%% /\\n'\n")
    environment = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "HOME": str(tmp_path)}
    result = subprocess.run([str(DOCTOR)], env=environment, capture_output=True, text=True)
    assert result.returncode == 0
    assert all(f"PASS {field}:" in result.stdout for field in ("cli", "daemon", "architecture", "memory", "host_space"))


def test_docker_doctor_preserves_daemon_diagnostic(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    write_executable(bin_dir / "docker", "#!/bin/sh\necho 'socket permission denied' >&2\nexit 1\n")
    write_executable(bin_dir / "df", "#!/bin/sh\nprintf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\n/dev 1 1 1 99%% /\\n'\n")
    environment = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "HOME": str(tmp_path)}
    result = subprocess.run([str(DOCTOR)], env=environment, capture_output=True, text=True)
    assert result.returncode != 0
    assert "FAIL daemon: socket permission denied" in result.stdout
    assert all(f" {field}:" in result.stdout for field in ("cli", "daemon", "architecture", "memory", "host_space"))


def test_docker_usage_reports_direct_and_relocated_raw_files(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    write_executable(bin_dir / "docker", "#!/bin/sh\nprintf 'docker usage\\n'\n")
    direct = tmp_path / "Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"
    direct.parent.mkdir(parents=True)
    direct.write_bytes(b"direct")
    relocated_dir = tmp_path / "relocated"
    relocated_dir.mkdir()
    relocated = relocated_dir / "Docker.raw"
    relocated.write_bytes(b"relocated")
    configured_direct = tmp_path / "configured" / "Docker.raw"
    configured_direct.parent.mkdir(parents=True)
    configured_direct.write_bytes(b"configured-direct")
    settings = tmp_path / "Library/Group Containers/group.com.docker/settings-store.json"
    settings.parent.mkdir(parents=True)
    settings.write_text(
        json.dumps(
            {
                "diskImageLocation": str(relocated_dir),
                "nested": {"diskImageLocation": str(configured_direct)},
            }
        ),
        encoding="utf-8",
    )
    environment = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "HOME": str(tmp_path)}
    result = subprocess.run([str(USAGE)], env=environment, capture_output=True, text=True)
    assert result.returncode == 0
    assert str(direct) in result.stdout
    assert str(relocated) in result.stdout
    assert str(configured_direct) in result.stdout
