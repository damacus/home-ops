"""Contract tests for native scheduled Kubernetes Mise tasks."""

from __future__ import annotations

import os
import shutil
import stat
import subprocess
from pathlib import Path


ROOT = Path(__file__).parents[1]
TASKS = ("log-noise", "check-kube-vip", "alerts", "edge-smoke")


def run(*command: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=ROOT,
        env=env,
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

    cache_binary = ROOT / ".cache/bin/cluster-health"
    cache_binary.unlink(missing_ok=True)

    check_kube_vip = run("mise", "run", "kubernetes:check-kube-vip", env=env)
    assert check_kube_vip.returncode == 0, check_kube_vip.stderr
    assert check_kube_vip.stdout == "kubectl output\n"

    alerts = run("mise", "run", "kubernetes:alerts", env=env)
    assert alerts.returncode == 0, alerts.stderr
    assert alerts.stdout == "   1 Example: active\n"

    alerts_failure_env = env | {"KUBECTL_EXIT": "37"}
    alerts_failure = run("mise", "run", "kubernetes:alerts", env=alerts_failure_env)
    assert alerts_failure.returncode == 37

    build = run("bash", ".mise/tasks/kubernetes/cluster-health-build", env=env)
    assert build.returncode == 0, build.stderr

    log_noise = run("bash", ".mise/tasks/kubernetes/log-noise", "--period", "24h", "--top", "10", env=env)
    assert log_noise.returncode == 29, log_noise.stderr
    assert log_noise.stdout == "cluster health output\n"
    assert cluster_health_args.read_bytes().split(b"\0")[:-1] == [b"log-noise", b"--period", b"24h", b"--top", b"10"]

    edge_smoke = run("bash", ".mise/tasks/kubernetes/edge-smoke", "--skip-http3", env=env)
    assert edge_smoke.returncode == 29
    assert cluster_health_args.read_bytes().split(b"\0")[:-1] == [b"edge-smoke", b"--skip-http3"]

    assert command_log.read_text().splitlines() == [
        "kubectl:get pods -n kube-system -l app.kubernetes.io/name=kube-vip -o wide",
        "kubectl:exec -n monitoring vmalertmanager-vm-0 -- wget -qO- http://localhost:9093/api/v2/alerts",
        "kubectl:exec -n monitoring vmalertmanager-vm-0 -- wget -qO- http://localhost:9093/api/v2/alerts",
    ]


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
        ("log-noise", ("--period", "24h"), ("--format", "text", "--timeout", "45s", "--period", "1h", "--top", "20")),
    ):
        result = run("task", f"kubernetes:{task}", "--", *arguments, env=env)

        assert result.returncode != 0
        assert result.stdout == "mise shim output\n"
        assert arguments_log.read_bytes().split(b"\0")[:-1] == [
            b"run",
            f"kubernetes:{task}".encode(),
            b"--",
            *[flag.encode() for flag in expected_flags],
            *[argument.encode() for argument in arguments],
        ]


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
            "log-noise",
            ("format=ndjson", "notify=true", "verbose=true", "raw=true", "timeout=12", "period=6h", "top=4"),
            ("--format", "ndjson", "--notify", "--verbose", "--raw", "--timeout", "12s", "--period", "6h", "--top", "4"),
        ),
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


def test_morning_check_variables_reach_migrated_mise_shims_without_external_commands(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    arguments_log = tmp_path / "mise-arguments"
    task_binary = shutil.which("task")
    assert task_binary is not None
    executable(
        bin_dir / "mise",
        "#!/usr/bin/env bash\n"
        "printf '%s\\t' \"$@\" >> \"$MISE_ARGUMENTS\"\n"
        "printf '\\n' >> \"$MISE_ARGUMENTS\"\n",
    )
    executable(
        bin_dir / "task",
        "#!/usr/bin/env bash\n"
        "case \"$1\" in\n"
        "  kubernetes:edge-smoke|kubernetes:log-noise) exec \"$REAL_TASK\" \"$@\" ;;\n"
        "  *) exit 0 ;;\n"
        "esac\n",
    )
    executable(bin_dir / "go", "#!/usr/bin/env bash\nexit 0\n")
    env = os.environ.copy()
    env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
    env["MISE_ARGUMENTS"] = str(arguments_log)
    env["REAL_TASK"] = task_binary

    result = run(
        task_binary,
        "kubernetes:morning-check",
        "format=ndjson",
        "verbose=true",
        "raw=true",
        "timeout=12",
        "period=6h",
        "top=4",
        "skip_http3=true",
        "log_noise=true",
        env=env,
    )

    assert result.returncode == 0, result.stderr
    calls = [line.split("\t")[:-1] for line in arguments_log.read_text().splitlines()]
    assert ["run", "kubernetes:edge-smoke", "--", "--format", "ndjson", "--verbose", "--raw", "--timeout", "12s", "--skip-http3"] in calls
    assert ["run", "kubernetes:log-noise", "--", "--format", "ndjson", "--verbose", "--raw", "--timeout", "12s", "--period", "6h", "--top", "4"] in calls
