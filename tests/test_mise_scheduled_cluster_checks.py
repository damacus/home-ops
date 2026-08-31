"""Contract tests for native scheduled Kubernetes Mise tasks."""

from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Callable


ROOT = Path(__file__).parents[1]
TASKS = ("log-noise", "check-kube-vip", "alerts", "edge-smoke")


def run(
    *command: str,
    env: dict[str, str] | None = None,
    cwd: Path = ROOT,
) -> subprocess.CompletedProcess[str]:
    contract_env = (os.environ if env is None else env).copy()
    contract_env.pop("MISE_LOG_LEVEL", None)
    return subprocess.run(
        command,
        cwd=cwd,
        env=contract_env,
        text=True,
        capture_output=True,
        check=False,
    )


def executable(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def test_scheduled_cluster_checks_are_native_mise_tasks_with_a_shared_cached_build() -> None:
    build = ROOT / ".mise/tasks/kubernetes/cluster-health-build"
    assert build.is_file()
    source = build.read_text()
    assert '#MISE sources=["go.mod", "cmd/cluster-health/**/*.go", "internal/clusterhealth/**/*.go"]' in source
    assert '#MISE outputs=[".cache/bin/cluster-health"]' in source
    assert '"$go_binary" build -trimpath -o .cache/bin/cluster-health ./cmd/cluster-health' in source

    for task in TASKS:
        source = (ROOT / f".mise/tasks/kubernetes/{task}").read_text()
        assert "exec task " not in source

    for task in ("log-noise", "edge-smoke"):
        source = (ROOT / f".mise/tasks/kubernetes/{task}").read_text()
        assert '#MISE depends=["kubernetes:cluster-health-build"]' in source


def test_native_tasks_route_to_external_commands_and_preserve_exit_status(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    command_log = tmp_path / "command-log"
    cluster_health_args = tmp_path / "cluster-health-args"
    executable(
        bin_dir / "kubectl",
        "#!/usr/bin/env bash\n"
        "printf 'kubectl:%s\\n' \"$*\" >> \"$COMMAND_LOG\"\n"
        "if [ \"${KUBECTL_EXIT:-0}\" -ne 0 ]; then exit \"$KUBECTL_EXIT\"; fi\n"
        "if [ \"$1\" = \"exec\" ]; then\n"
        "  printf '[{\"labels\":{\"alertname\":\"Example\"},\"status\":{\"state\":\"active\"}}]\\n'\n"
        "else\n"
        "  printf 'kubectl output\\n'\n"
        "fi\n",
    )
    executable(
        bin_dir / "go",
        "#!/usr/bin/env bash\n"
        "while [ \"$#\" -gt 0 ]; do\n"
        "  if [ \"$1\" = \"-o\" ]; then output=$2; shift 2; continue; fi\n"
        "  shift\n"
        "done\n"
        "mkdir -p \"$(dirname \"$output\")\"\n"
        "printf '%s\\n' '#!/usr/bin/env bash' 'printf \"%s\\\\0\" \"$@\" > \"$CLUSTER_HEALTH_ARGS\"' 'printf \"cluster health output\\\\n\"' 'exit \"${CLUSTER_HEALTH_EXIT:-0}\"' > \"$output\"\n"
        "chmod +x \"$output\"\n",
    )
    env = os.environ.copy()
    env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
    env["COMMAND_LOG"] = str(command_log)
    env["CLUSTER_HEALTH_ARGS"] = str(cluster_health_args)
    env["CLUSTER_HEALTH_EXIT"] = "29"
    env["CLUSTER_HEALTH_GO_BINARY"] = str(bin_dir / "go")

    task_root = tmp_path / ".mise/tasks/kubernetes"
    task_root.mkdir(parents=True)
    for task in ("cluster-health-build", "log-noise", "edge-smoke"):
        source = ROOT / ".mise/tasks/kubernetes" / task
        destination = task_root / task
        destination.write_bytes(source.read_bytes())
        destination.chmod(source.stat().st_mode)

    check_kube_vip = run("mise", "run", "kubernetes:check-kube-vip", env=env)
    assert check_kube_vip.returncode == 0, check_kube_vip.stderr
    assert check_kube_vip.stdout == "kubectl output\n"

    alerts = run("mise", "run", "kubernetes:alerts", env=env)
    assert alerts.returncode == 0, alerts.stderr
    alert_records = [line.split() for line in alerts.stdout.splitlines() if line.strip()]
    assert alert_records == [["1", "Example:", "active"]], f"unexpected alert records: {alerts.stdout!r}"

    alerts_failure_env = env | {"KUBECTL_EXIT": "37"}
    alerts_failure = run("mise", "run", "kubernetes:alerts", env=alerts_failure_env)
    assert alerts_failure.returncode == 37

    build = run("bash", str(task_root / "cluster-health-build"), env=env, cwd=tmp_path)
    assert build.returncode == 0, build.stderr

    log_noise = run("bash", str(task_root / "log-noise"), "--period", "24h", "--top", "10", env=env, cwd=tmp_path)
    assert log_noise.returncode == 29, log_noise.stderr
    assert log_noise.stdout == "cluster health output\n"
    assert cluster_health_args.read_bytes().split(b"\0")[:-1] == [b"log-noise", b"--period", b"24h", b"--top", b"10"]

    edge_smoke = run("bash", str(task_root / "edge-smoke"), "--skip-http3", env=env, cwd=tmp_path)
    assert edge_smoke.returncode == 29
    assert cluster_health_args.read_bytes().split(b"\0")[:-1] == [b"edge-smoke", b"--skip-http3"]

    assert command_log.read_text().splitlines() == [
        "kubectl:get pods -n kube-system -l app.kubernetes.io/name=kube-vip -o wide",
        "kubectl:exec -n monitoring vmalertmanager-vm-0 -- wget -qO- http://localhost:9093/api/v2/alerts",
        "kubectl:exec -n monitoring vmalertmanager-vm-0 -- wget -qO- http://localhost:9093/api/v2/alerts",
    ]

    assert (tmp_path / ".cache/bin/cluster-health").is_file()


def test_legacy_task_composite_dependencies_are_one_way_mise_shims(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    arguments_log = tmp_path / "mise-arguments"
    executable(
        bin_dir / "mise",
        "#!/usr/bin/env bash\n"
        "printf '%s\\0' \"$@\" > \"$MISE_ARGUMENTS\"\n"
        "printf 'mise shim output\\n'\n"
        "exit 31\n",
    )
    env = os.environ.copy()
    env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
    env["MISE_ARGUMENTS"] = str(arguments_log)

    for task, arguments, expected_flags in (
        ("edge-smoke", ("--skip-http3",), ("--format", "text", "--timeout", "45s")),
    ):
        result = run("task", "--silent", f"kubernetes:{task}", "--", *arguments, env=env)

        assert result.returncode != 0
        stdout = result.stdout
        ci_annotation = (
            f"::error title=Task 'kubernetes:{task}' failed::exit status 31\n"
        )
        if stdout.endswith(ci_annotation):
            stdout = stdout[: -len(ci_annotation)]
        assert stdout == "mise shim output\n", f"unexpected shim stdout: {result.stdout!r}"
        actual_arguments = arguments_log.read_bytes().split(b"\0")[:-1]
        assert actual_arguments[:3] == [
            b"run",
            f"kubernetes:{task}".encode(),
            b"--",
        ], f"unexpected Mise shim prefix: {actual_arguments!r}"
        forwarded_arguments = actual_arguments[3:]
        if forwarded_arguments[:1] == [b"--"]:
            forwarded_arguments = forwarded_arguments[1:]
        assert forwarded_arguments == [
            *[flag.encode() for flag in expected_flags],
            *[argument.encode() for argument in arguments],
        ], f"unexpected Mise shim arguments: {actual_arguments!r}"


def test_legacy_task_variables_translate_to_mise_flags_and_keep_cli_args(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    arguments_log = tmp_path / "mise-arguments"
    executable(
        bin_dir / "mise",
        "#!/usr/bin/env bash\n"
        "printf '%s\\t' \"$@\" >> \"$MISE_ARGUMENTS\"\n"
        "printf '\\n' >> \"$MISE_ARGUMENTS\"\n",
    )
    env = os.environ.copy()
    env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
    env["MISE_ARGUMENTS"] = str(arguments_log)

    cases = (
        (
            "edge-smoke",
            ("format=ndjson", "notify=true", "verbose=true", "raw=true", "timeout=12", "skip_http3=true"),
            ("--format", "ndjson", "--notify", "--verbose", "--raw", "--timeout", "12s", "--skip-http3"),
        ),
    )
    for task, variables, expected_flags in cases:
        result = run("task", f"kubernetes:{task}", *variables, "--", "--literal-flag", env=env)

        assert result.returncode == 0, result.stderr
        assert arguments_log.read_text().splitlines()[-1].split("\t")[:-1] == [
            "run",
            f"kubernetes:{task}",
            "--",
            *expected_flags,
            "--literal-flag",
        ]


def load_tests(loader: unittest.TestLoader, tests: unittest.TestSuite, pattern: str | None) -> unittest.TestSuite:
    suite = unittest.TestSuite()
    suite.addTest(unittest.FunctionTestCase(test_scheduled_cluster_checks_are_native_mise_tasks_with_a_shared_cached_build))
    for test in (
        test_native_tasks_route_to_external_commands_and_preserve_exit_status,
        test_legacy_task_composite_dependencies_are_one_way_mise_shims,
        test_legacy_task_variables_translate_to_mise_flags_and_keep_cli_args,
    ):
        suite.addTest(
            unittest.FunctionTestCase(
                lambda test=test: _run_with_temp_path(test),
            )
        )
    return suite


def _run_with_temp_path(test: Callable[[Path], None]) -> None:
    with tempfile.TemporaryDirectory() as directory:
        test(Path(directory))
