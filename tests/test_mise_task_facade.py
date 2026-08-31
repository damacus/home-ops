"""Contract tests for the public Mise facade over Task."""

from __future__ import annotations

import json
import os
import re
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Callable


ROOT = Path(__file__).parents[1]


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


def task_descriptions() -> dict[str, str]:
    result = run("task", "--list-all")
    assert result.returncode == 0, result.stderr
    descriptions: dict[str, str] = {}
    for line in result.stdout.splitlines():
        if not line.startswith("*"):
            continue
        match = re.match(r"^\*\s+(\S+):\s+(.*?)\s*(?:\(aliases:.*\))?$", line)
        if match and match.group(1) != "default":
            descriptions[match.group(1)] = match.group(2).rstrip()
    return descriptions


def mise_tasks() -> dict[str, dict[str, object]]:
    result = run("mise", "tasks", "ls", "--json")
    assert result.returncode == 0, result.stderr
    return {task["name"]: task for task in json.loads(result.stdout)}


def test_mise_facade_discovers_every_public_task_with_the_task_description() -> None:
    expected = task_descriptions()
    actual = mise_tasks()

    assert set(expected).issubset(actual)
    assert "default" not in actual
    assert not any(name.startswith(".") for name in actual)
    for name, description in expected.items():
        assert actual[name]["description"] == description


def test_mise_facade_forwards_arguments_and_streams_output_and_status(tmp_path: Path) -> None:
    arguments_log = tmp_path / "arguments"
    fake_task = tmp_path / "task"
    fake_task.write_text(
        "#!/usr/bin/env bash\n"
        "printf '%s\\0' \"$@\" > \"$FACADE_ARGUMENTS\"\n"
        "printf 'facade stdout\\n'\n"
        "printf 'facade stderr\\n' >&2\n"
        "exit 23\n"
    )
    fake_task.chmod(fake_task.stat().st_mode | stat.S_IXUSR)
    env = os.environ.copy()
    env["FACADE_ARGUMENTS"] = str(arguments_log)
    env["PATH"] = f"{tmp_path}{os.pathsep}{env['PATH']}"

    result = run(
        "bash",
        ".mise/tasks/init",
        "value with spaces",
        "--literal-flag",
        env=env,
    )

    assert result.returncode == 23
    assert result.stdout == "facade stdout\n"
    assert "facade stderr\n" in result.stderr
    assert arguments_log.read_bytes().split(b"\0")[:-1] == [
        b"init",
        b"--",
        b"value with spaces",
        b"--literal-flag",
    ]


def test_retained_facade_routes_task_variables_before_literal_arguments(tmp_path: Path) -> None:
    arguments_log = tmp_path / "arguments"
    fake_task = tmp_path / "task"
    fake_task.write_text(
        "#!/usr/bin/env bash\n"
        "printf '%s\\0' \"$@\" > \"$FACADE_ARGUMENTS\"\n"
    )
    fake_task.chmod(fake_task.stat().st_mode | stat.S_IXUSR)
    env = os.environ.copy()
    env["FACADE_ARGUMENTS"] = str(arguments_log)
    env["PATH"] = f"{tmp_path}{os.pathsep}{env['PATH']}"

    result = run(
        "bash",
        ".mise/tasks/flux/apply",
        "path=authentication/zitadel",
        "ns=testing",
        "--",
        "NAME=literal",
        "--literal-flag",
        env=env,
    )

    assert result.returncode == 0, result.stderr
    assert arguments_log.read_bytes().split(b"\0")[:-1] == [
        b"flux:apply",
        b"path=authentication/zitadel",
        b"ns=testing",
        b"--",
        b"NAME=literal",
        b"--literal-flag",
    ]


def test_retained_facade_preserves_cli_arguments_starting_with_literal_separator(tmp_path: Path) -> None:
    arguments_log = tmp_path / "arguments"
    fake_task = tmp_path / "task"
    fake_task.write_text("#!/usr/bin/env bash\nprintf '%s\\0' \"$@\" > \"$FACADE_ARGUMENTS\"\n")
    fake_task.chmod(fake_task.stat().st_mode | stat.S_IXUSR)
    env = os.environ.copy()
    env["FACADE_ARGUMENTS"] = str(arguments_log)
    env["PATH"] = f"{tmp_path}{os.pathsep}{env['PATH']}"

    result = run(
        "bash",
        ".mise/tasks/flux/apply",
        "path=authentication/zitadel",
        "--",
        "--",
        "literal",
        env=env,
    )

    assert result.returncode == 0, result.stderr
    assert arguments_log.read_bytes().split(b"\0")[:-1] == [
        b"flux:apply",
        b"path=authentication/zitadel",
        b"--",
        b"--",
        b"literal",
    ]


def test_public_facade_preserves_explicit_separator_streams_and_status(tmp_path: Path) -> None:
    task_path = tmp_path / ".mise/tasks/flux/apply"
    task_path.parent.mkdir(parents=True)
    shutil.copy2(ROOT / ".mise/tasks/flux/apply", task_path)
    scripts = tmp_path / "scripts"
    scripts.mkdir()
    shutil.copy2(ROOT / "scripts/mise-task-facade.sh", scripts / "mise-task-facade.sh")
    arguments_log = tmp_path / "arguments"
    fake_task = tmp_path / "task"
    fake_task.write_text(
        "#!/usr/bin/env bash\n"
        "printf '%s\\0' \"$@\" > \"$FACADE_ARGUMENTS\"\n"
        "printf 'public stdout\\n'\n"
        "printf 'public stderr\\n' >&2\n"
        "exit 23\n"
    )
    fake_task.chmod(fake_task.stat().st_mode | stat.S_IXUSR)
    env = os.environ.copy()
    env["FACADE_ARGUMENTS"] = str(arguments_log)
    env["PATH"] = f"{tmp_path}{os.pathsep}{env['PATH']}"
    home = tmp_path / "home"
    home.mkdir()
    env["HOME"] = str(home)
    env["NO_COLOR"] = "1"

    version_result = run("mise", "--version", env=env, cwd=tmp_path)
    assert version_result.returncode == 0, version_result.stderr
    version = tuple(int(part) for part in version_result.stdout.split()[0].split("."))
    parser_delimiters = ("--", "--") if version >= (2026, 8, 15) else ("--",)

    result = run(
        "mise",
        "run",
        "flux:apply",
        "path=authentication/zitadel",
        "ns=testing",
        *parser_delimiters,
        "NAME=literal",
        "--literal-flag",
        env=env,
        cwd=tmp_path,
    )

    assert result.returncode == 23
    assert result.stdout == "public stdout\n"
    known_diagnostic = "[flux:apply] ERROR task failed\n"
    known_coloured_diagnostics = (
        "\x1b[32m\x1b[2m[flux:apply]\x1b[0m "
        "\x1b[31mERROR\x1b[0m task failed\n",
        "\x1b[38;5;10m[flux:apply]\x1b[0m "
        "\x1b[31mERROR\x1b[0m task failed\n",
    )
    stderr = result.stderr
    for diagnostic in (known_diagnostic, *known_coloured_diagnostics):
        if stderr.endswith(diagnostic):
            stderr = stderr[: -len(diagnostic)]
            break
    assert stderr == "public stderr\n", f"unexpected public stderr: {result.stderr!r}"
    arguments = arguments_log.read_bytes().split(b"\0")[:-1]
    separator = arguments.index(b"--")
    assert arguments[:separator] == [
        b"flux:apply",
        b"path=authentication/zitadel",
        b"ns=testing",
    ], f"unexpected Task-variable argv: {arguments!r}"
    assert arguments[separator + 1 :] == [
        b"NAME=literal",
        b"--literal-flag",
    ], f"unexpected literal Task argv: {arguments!r}"


def test_contract_runner_does_not_leak_mise_logging_into_subprocesses() -> None:
    result = run(
        "bash",
        "-c",
        "printf '%s' \"${MISE_LOG_LEVEL:-}\"",
        env=os.environ.copy() | {"MISE_LOG_LEVEL": "info"},
    )

    assert result.returncode == 0, result.stderr
    assert result.stdout == ""


def test_flux_apply_routes_task_variables_without_contacting_the_cluster(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    calls = tmp_path / "calls"
    kubeconfig = tmp_path / "kubeconfig"
    kubeconfig.write_text("fixture\n")
    fake_flux = bin_dir / "flux"
    fake_flux.write_text(
        "#!/usr/bin/env bash\n"
        "printf 'flux:%s\\n' \"$*\" >> \"$CALLS\"\n"
        "case \" $* \" in\n"
        "  *' get kustomizations '*) printf 'not found\\n' ;;\n"
        "  *' build ks '*) printf 'apiVersion: v1\\nkind: ConfigMap\\n' ;;\n"
        "esac\n"
    )
    fake_flux.chmod(fake_flux.stat().st_mode | stat.S_IXUSR)
    fake_kubectl = bin_dir / "kubectl"
    fake_kubectl.write_text(
        "#!/usr/bin/env bash\n"
        "printf 'kubectl:%s\\n' \"$*\" >> \"$CALLS\"\n"
        "cat >/dev/null\n"
    )
    fake_kubectl.chmod(fake_kubectl.stat().st_mode | stat.S_IXUSR)
    env = os.environ.copy()
    env["CALLS"] = str(calls)
    env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"

    result = run(
        "mise",
        "run",
        "flux:apply",
        "path=authentication/zitadel",
        "ns=testing",
        f"KUBECONFIG_FILE={kubeconfig}",
        env=env,
    )

    assert result.returncode == 0, result.stderr
    actual = calls.read_text()
    assert "--namespace testing get kustomizations zitadel" in actual
    assert "build ks zitadel --namespace testing" in actual
    assert f"kubectl:apply --kubeconfig {kubeconfig} --server-side" in actual


def test_object_storage_facade_routes_every_override_without_live_secrets(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    rclone_arguments = tmp_path / "rclone-arguments"
    fake_kubectl = bin_dir / "kubectl"
    fake_kubectl.write_text("#!/usr/bin/env bash\nprintf 'Y3JlZGVudGlhbA=='\n")
    fake_kubectl.chmod(fake_kubectl.stat().st_mode | stat.S_IXUSR)
    fake_rclone = bin_dir / "rclone"
    fake_rclone.write_text(
        "#!/usr/bin/env bash\n"
        "printf '%s\\0' \"$@\" > \"$RCLONE_ARGUMENTS\"\n"
    )
    fake_rclone.chmod(fake_rclone.stat().st_mode | stat.S_IXUSR)
    env = os.environ.copy()
    env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
    env["RCLONE_ARGUMENTS"] = str(rclone_arguments)

    result = run(
        "mise",
        "run",
        "kubernetes:object-storage-migrate",
        "source=rustfs",
        "destination=minio",
        "mode=sync",
        "source_path=source-bucket/prefix",
        "destination_path=destination-bucket/prefix",
        "dry_run=true",
        env=env,
    )

    assert result.returncode == 0, result.stderr
    arguments = rclone_arguments.read_bytes().split(b"\0")[:-1]
    assert b"sync" in arguments
    assert b"rustfs:source-bucket/prefix" in arguments
    assert b"minio:destination-bucket/prefix" in arguments
    assert b"--dry-run" in arguments


def test_workflow_routes_every_migration_contract_path_to_the_complete_suite() -> None:
    workflow = (ROOT / ".github/workflows/flux.yaml").read_text()
    migration_filter = workflow.split("            mise_contracts:\n", maxsplit=1)[1].split(
        "\n\n", maxsplit=1
    )[0]
    for path in (
        ".github/workflows/flux.yaml",
        "mise.toml",
        "mise.lock",
        "Taskfile.yaml",
        ".taskfiles/**",
        ".mise/tasks/**",
        "scripts/mise-task-facade.sh",
        "scripts/mise-postgres-task.sh",
        "scripts/pg-bluegreen.sh",
        "scripts/object_storage_migrate.sh",
        "scripts/tempo_trace_backend_contract.sh",
        "scripts/mondoo_scan.py",
        "scripts/home_assistant_unaccounted_electricity.py",
        "scripts/unifi/read-status.py",
        "scripts/rustfs_iam_live_check.sh",
        "scripts/notify",
        "tests/test_mise_task_facade.py",
        "tests/test_mise_scheduled_cluster_checks.py",
        "tests/test_mise_cluster_health.py",
        "tests/test_mise_leaf_operations.py",
        "tests/test_mise_postgres.py",
    ):
        assert f"- '{path}'" in migration_filter

    job = workflow.split("\n  mise-migration-contracts:\n", maxsplit=1)[1].split(
        "\n  yaml-lint:\n", maxsplit=1
    )[0]
    assert "needs.changes.outputs.mise_contracts == 'true'" in job
    assert "python3 -m unittest" in job
    for module in (
        "tests/test_mise_task_facade.py",
        "tests/test_mise_scheduled_cluster_checks.py",
        "tests/test_mise_cluster_health.py",
        "tests/test_mise_leaf_operations.py",
        "tests/test_mise_postgres.py",
    ):
        assert module in job

    mondoo_unit_step = workflow.split("      - name: Run unit tests\n", maxsplit=1)[1].split(
        "\n      - name: Validate migrated policy parity\n", maxsplit=1
    )[0]
    assert "tests/test_mondoo_scan.py" in mondoo_unit_step
    assert "tests/test_zitadel_config.py" in mondoo_unit_step
    assert "tests/test_mise_leaf_operations.py" not in mondoo_unit_step
    assert "tests/test_mise_postgres.py" not in mondoo_unit_step

    flate_diff_job = workflow.split("\n  flate-diff:\n", maxsplit=1)[1].split(
        "\n  flate-success:\n", maxsplit=1
    )[0]
    assert "FLATE_BASE: origin/pr-base" not in flate_diff_job
    assert "mise run flux:flate-diff base=origin/pr-base output=github" in flate_diff_job


def test_current_operator_documentation_uses_the_mise_interface() -> None:
    gemini = (ROOT / "GEMINI.md").read_text()
    flate = (ROOT / "docs/flate-setup.md").read_text()
    test_app = (ROOT / ".mise/tasks/kubernetes/test-app").read_text()

    assert "Mise is the public task interface" in " ".join(gemini.split())
    assert "task flux:" not in gemini
    assert "task configure" not in gemini
    assert "task repo:" not in gemini
    assert ".mise/tasks/flux/flate-test" in flate
    assert ".github/workflows/flux.yaml" in flate
    assert ".taskfiles/Flux/Taskfile.yaml" not in flate
    assert "Usage: mise run kubernetes:test-app app=<namespace>/<app>" in test_app


def load_tests(loader: unittest.TestLoader, tests: unittest.TestSuite, pattern: str | None) -> unittest.TestSuite:
    suite = unittest.TestSuite()
    for test in (
        test_mise_facade_discovers_every_public_task_with_the_task_description,
        test_contract_runner_does_not_leak_mise_logging_into_subprocesses,
        test_workflow_routes_every_migration_contract_path_to_the_complete_suite,
        test_current_operator_documentation_uses_the_mise_interface,
    ):
        suite.addTest(unittest.FunctionTestCase(test))
    for test in (
        test_mise_facade_forwards_arguments_and_streams_output_and_status,
        test_retained_facade_routes_task_variables_before_literal_arguments,
        test_retained_facade_preserves_cli_arguments_starting_with_literal_separator,
        test_public_facade_preserves_explicit_separator_streams_and_status,
        test_flux_apply_routes_task_variables_without_contacting_the_cluster,
        test_object_storage_facade_routes_every_override_without_live_secrets,
    ):
        suite.addTest(unittest.FunctionTestCase(lambda test=test: _run_with_temp_path(test)))
    return suite


def _run_with_temp_path(test: Callable[[Path], None]) -> None:
    with tempfile.TemporaryDirectory() as directory:
        test(Path(directory))
