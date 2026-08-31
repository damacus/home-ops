"""Contract tests for native leaf-operation Mise tasks."""

from __future__ import annotations

import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
TASKS = {
    "jq": (
        "update-field",
        "query",
        "list-failing",
        "failing-by-area",
        "failing-by-category",
        "next-features",
    ),
    "home-assistant": ("unaccounted-electricity",),
    "unifi": ("mesh-status",),
    "flux": ("flate-test", "flate-build", "flate-diff"),
    "certificates": ("check-certificates",),
    "workstation": ("venv",),
    "kubernetes": (
        "resources",
        "yayamlls",
        "rustfs-iam-policy",
        "rustfs-iam-live-policy",
        "forgejo-policy",
        "tempo-trace-backend-contract",
        "log-noise-by-namespace",
        "test-app",
        "mondoo-manifests",
        "mondoo-live",
    ),
}


def run(*command: str, cwd: Path = ROOT, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=cwd, env=env, text=True, capture_output=True, check=False)


def executable(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def isolated_task(tmp_path: Path, namespace: str, task: str) -> Path:
    destination = tmp_path / ".mise/tasks" / namespace / task
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / ".mise/tasks" / namespace / task, destination)
    return destination


def assert_leaf_operations_are_native_and_task_implementations_are_removed() -> None:
    taskfiles = {
        "jq": ROOT / ".taskfiles/Jq/Taskfile.yaml",
        "home-assistant": ROOT / ".taskfiles/HomeAssistant/Taskfile.yaml",
        "unifi": ROOT / ".taskfiles/Unifi/Taskfile.yaml",
        "flux": ROOT / ".taskfiles/Flux/Taskfile.yaml",
        "certificates": ROOT / ".taskfiles/Certificates/Taskfile.yaml",
        "workstation": ROOT / ".taskfiles/Workstation/Taskfile.yaml",
        "kubernetes": ROOT / ".taskfiles/Kubernetes/Taskfile.yaml",
    }
    for namespace, tasks in TASKS.items():
        taskfile = taskfiles[namespace].read_text()
        for task in tasks:
            source = (ROOT / ".mise/tasks" / namespace / task).read_text()
            assert "exec task " not in source
            assert f"  {task}:" not in taskfile

    venv = (ROOT / ".mise/tasks/workstation/venv").read_text()
    assert '#MISE sources=["requirements.txt"]' in venv
    assert '#MISE outputs=[".venv/pyvenv.cfg"]' in venv


def assert_jq_update_field_accepts_legacy_variables_and_preserves_jq_failure(tmp_path: Path) -> None:
    fixture = tmp_path / "tasks.json"
    fixture.write_text('[{"id":"PROF-002","passes":false}]\n')
    result = run(
        "bash",
        str(isolated_task(tmp_path, "jq", "update-field")),
        f"FILE={fixture}",
        "ID=PROF-002",
        "FIELD=passes",
        "VALUE=true",
        cwd=tmp_path,
    )
    assert result.returncode == 0, result.stderr
    assert fixture.read_text() == '[\n  {\n    "id": "PROF-002",\n    "passes": true\n  }\n]\n'


def assert_native_leaf_tasks_construct_commands_and_preserve_exit_status(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    calls = tmp_path / "calls"
    for command in ("kubectl", "yayamlls", "cnspec", "python3", "flate", "openssl", "uv", "jq", "awk", "rc"):
        executable(
            bin_dir / command,
            "#!/usr/bin/env bash\n"
            "printf '%s:%s\\n' \"$(basename \"$0\")\" \"$*\" >> \"$CALLS\"\n"
            "if [ \"${FAKE_EXIT:-0}\" -ne 0 ]; then exit \"$FAKE_EXIT\"; fi\n",
        )
    (tmp_path / "scripts").mkdir()
    for script in (
        "mondoo_scan.py",
        "tempo_trace_backend_contract.sh",
        "home_assistant_unaccounted_electricity.py",
        "rustfs_iam_live_check.sh",
    ):
        (tmp_path / "scripts" / script).write_text("# fixture\n")
    (tmp_path / "scripts/tempo_trace_backend_contract.sh").write_text('printf "tempo:%s\\n" "$*" >> "$CALLS"\n')
    (tmp_path / "scripts/unifi").mkdir()
    (tmp_path / "scripts/unifi/read-status.py").write_text("# fixture\n")
    (tmp_path / "tests/mondoo").mkdir(parents=True)
    for policy in ("rustfs-iam.mql.yaml", "rustfs-iam-live.mql.yaml", "forgejo.mql.yaml"):
        (tmp_path / "tests/mondoo" / policy).write_text("policy: {}\n")
    (tmp_path / "kubernetes").mkdir()
    (tmp_path / "certificates").mkdir()
    (tmp_path / "certificates/ironstone-casa-tls.crt").write_text("certificate\n")
    (tmp_path / "certificates/ironstone-casa-tls.key").write_text("key\n")
    (tmp_path / "requirements.txt").write_text("")
    env = os.environ.copy()
    env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
    env["CALLS"] = str(calls)

    cases = (
        ("flux", "flate-test", ("path=./rendered",), "flate:--no-progress test all"),
        ("flux", "flate-build", ("path=./rendered",), "flate:--no-progress build all"),
        ("flux", "flate-diff", ("path=./rendered", "path_orig=./baseline"), "flate:--no-progress diff all"),
        ("home-assistant", "unaccounted-electricity", ("format=json", "hours=6"), "kubectl:exec -i -n home-automation"),
        ("unifi", "mesh-status", ("json=true", "no_ping=true"), "python3:scripts/unifi/read-status.py"),
        ("kubernetes", "resources", ("-n", "monitoring"), "kubectl:get nodes -n monitoring"),
        ("kubernetes", "yayamlls", (), "yayamlls:validate --render"),
        ("kubernetes", "rustfs-iam-policy", (), "cnspec:--auto-update=false policy lint"),
        ("kubernetes", "rustfs-iam-live-policy", (), "cnspec:--auto-update=false policy lint"),
        ("kubernetes", "forgejo-policy", (), "cnspec:--auto-update=false policy lint"),
        ("kubernetes", "tempo-trace-backend-contract", (), "tempo:"),
        ("kubernetes", "log-noise-by-namespace", ("PERIOD=6h",), "kubectl:exec -n monitoring deploy/loki-gateway"),
        ("kubernetes", "test-app", ("app=monitoring/grafana", "output=junit"), "python3:"),
        ("kubernetes", "mondoo-manifests", ("path=./rendered", "include_posture=false"), "python3:"),
        ("kubernetes", "mondoo-live", ("output=junit",), "python3:"),
        ("certificates", "check-certificates", (), "openssl:x509 -in ironstone-casa-tls.crt"),
        ("workstation", "venv", (), "uv:venv --allow-existing"),
    )
    for namespace, task, arguments, expected in cases:
        result = run("bash", str(isolated_task(tmp_path, namespace, task)), *arguments, cwd=tmp_path, env=env)
        assert result.returncode == 0, result.stderr
        assert expected in calls.read_text()

    failed = run("bash", str(isolated_task(tmp_path, "flux", "flate-test")), cwd=tmp_path, env=env | {"FAKE_EXIT": "47"})
    assert failed.returncode == 47


class TestMiseLeafOperations(unittest.TestCase):
    def test_leaf_operations_are_native_and_task_implementations_are_removed(self) -> None:
        assert_leaf_operations_are_native_and_task_implementations_are_removed()

    def test_jq_update_field_accepts_legacy_variables_and_preserves_jq_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            assert_jq_update_field_accepts_legacy_variables_and_preserves_jq_failure(Path(directory))

    def test_native_leaf_tasks_construct_commands_and_preserve_exit_status(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            assert_native_leaf_tasks_construct_commands_and_preserve_exit_status(Path(directory))
