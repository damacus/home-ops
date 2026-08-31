"""Contract tests for native PostgreSQL Mise tasks."""

from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
DIRECT_TASKS = (
    "discover",
    "show-active",
    "preflight",
    "blue-connection",
    "green-connection",
    "prepare-blue",
    "create-green",
    "copy-schema",
    "publication",
    "subscription",
    "subscription-reset",
    "monitor",
    "ready",
    "cutover",
    "postcheck",
    "grafana-postcheck",
    "rollback",
    "cleanup",
)
TASK_NAMES = ("default", "sop", *DIRECT_TASKS, "all-but-cutover")
SEQUENCE = (
    "discover",
    "prepare-blue",
    "preflight",
    "create-green",
    "copy-schema",
    "publication",
    "subscription",
    "monitor",
)


def run(*command: str, cwd: Path = ROOT, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=cwd, env=env, text=True, capture_output=True, check=False)


def executable(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def isolated_tasks(tmp_path: Path) -> None:
    destination = tmp_path / ".mise/tasks/postgres"
    destination.mkdir(parents=True)
    for name in TASK_NAMES:
        shutil.copy2(ROOT / ".mise/tasks/postgres" / name, destination / name)
    scripts = tmp_path / "scripts"
    scripts.mkdir()
    shutil.copy2(ROOT / "scripts/mise-postgres-task.sh", scripts / "mise-postgres-task.sh")


def fake_bluegreen(tmp_path: Path) -> Path:
    calls = tmp_path / "calls"
    executable(
        tmp_path / "scripts/pg-bluegreen.sh",
        "#!/usr/bin/env bash\n"
        "python3 -c 'import json, os, sys; print(json.dumps({\"argv\": sys.argv[1:], \"env\": {name: os.environ.get(name) for name in (\"PG_PROFILE\", \"NAMESPACE\", \"APP_DEPLOYMENTS\", \"HELMRELEASE\", \"BLUE_CLUSTER\", \"GREEN_CLUSTER\", \"BLUE_DATABASE\", \"GREEN_DATABASE\", \"BLUE_USER\", \"GREEN_USER\", \"BLUE_APP_SECRET\", \"GREEN_APP_SECRET\", \"PUBLICATION_NAME\", \"SUBSCRIPTION_NAME\", \"STATE_DIR\", \"MIGRATION_MANIFEST_DIR\", \"HELMRELEASE_PATH\", \"PROMETHEUS_URL\", \"CONFIRM_CONTEXT\", \"ROOT_DIR\")}}))' \"$@\" >> \"$CALLS\"\n"
        "[ \"${FAIL_SUBCOMMAND:-}\" != \"${1:-}\" ] || exit \"${FAIL_EXIT:-1}\"\n",
    )
    return calls


def assert_postgres_tasks_are_native_and_task_implementation_is_removed() -> None:
    root_taskfile = (ROOT / "Taskfile.yaml").read_text()
    assert "exec task " not in "".join(
        (ROOT / ".mise/tasks/postgres" / name).read_text() for name in TASK_NAMES
    )
    assert "taskfile: .taskfiles/Postgres/Taskfile.yaml" not in root_taskfile
    assert not (ROOT / ".taskfiles/Postgres/Taskfile.yaml").exists()


def assert_workflow_runs_postgres_contracts_for_every_postgres_path() -> None:
    workflow = (ROOT / ".github/workflows/flux.yaml").read_text()
    contracts_filter = workflow.split("            contracts:\n", maxsplit=1)[1].split(
        "\n\n", maxsplit=1
    )[0]
    postgres_paths = (
        ".mise/tasks/postgres/**",
        "scripts/mise-postgres-task.sh",
        ".taskfiles/Postgres/profiles/**",
        "scripts/pg-bluegreen.sh",
        "tests/test_mise_postgres.py",
    )
    for path in postgres_paths:
        assert f"- '{path}'" in contracts_filter

    contract_job = workflow.split("\n  rustfs-iam-policy:\n", maxsplit=1)[1].split(
        "\n  flate-test:\n", maxsplit=1
    )[0]
    assert "needs.changes.outputs.contracts == 'true'" in contract_job
    assert "python3 -m unittest tests/test_mise_postgres.py" in contract_job


def assert_direct_task_forwards_its_subcommand(
    tmp_path: Path,
    task: str,
    calls: Path,
    env: dict[str, str],
) -> None:
    calls.unlink(missing_ok=True)
    result = run("mise", "run", f"postgres:{task}", cwd=tmp_path, env=env)

    assert result.returncode == 0, result.stderr
    assert [json.loads(line)["argv"] for line in calls.read_text().splitlines()] == [[task]]


def assert_task_forwards_subcommand_defaults_and_explicit_environment(tmp_path: Path) -> None:
    isolated_tasks(tmp_path)
    calls = fake_bluegreen(tmp_path)
    env = os.environ.copy() | {"CALLS": str(calls)}

    result = run(
        "mise",
        "run",
        "postgres:discover",
        "PG_PROFILE=forgejo",
        "NAMESPACE=override",
        "CONFIRM_CONTEXT=true",
        cwd=tmp_path,
        env=env,
    )

    assert result.returncode == 0, result.stderr
    call = json.loads(calls.read_text())
    assert call["argv"] == ["discover"]
    assert call["env"] == {
        "PG_PROFILE": "forgejo",
        "NAMESPACE": "override",
        "APP_DEPLOYMENTS": "n8n n8n-worker",
        "HELMRELEASE": "n8n",
        "BLUE_CLUSTER": "n8n",
        "GREEN_CLUSTER": "n8n-green",
        "BLUE_DATABASE": "app",
        "GREEN_DATABASE": "app",
        "BLUE_USER": "app",
        "GREEN_USER": "app",
        "BLUE_APP_SECRET": "n8n-app",
        "GREEN_APP_SECRET": "n8n-green-app",
        "PUBLICATION_NAME": "n8n-green-pub",
        "SUBSCRIPTION_NAME": "n8n-green-sub",
        "STATE_DIR": ".migration-state/n8n",
        "MIGRATION_MANIFEST_DIR": "",
        "HELMRELEASE_PATH": "",
        "PROMETHEUS_URL": "http://prometheus-operated.observability.svc.cluster.local:9090",
        "CONFIRM_CONTEXT": "true",
        "ROOT_DIR": os.path.realpath(tmp_path),
    }


def assert_profile_is_loaded_from_the_preserved_profile_path(tmp_path: Path) -> None:
    (tmp_path / "scripts").mkdir()
    shutil.copy2(ROOT / "scripts/pg-bluegreen.sh", tmp_path / "scripts/pg-bluegreen.sh")
    profiles = tmp_path / ".taskfiles/Postgres/profiles"
    profiles.mkdir(parents=True)
    shutil.copy2(ROOT / ".taskfiles/Postgres/profiles/forgejo.env", profiles / "forgejo.env")
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for command in ("kubectl", "yq", "jq"):
        executable(bin_dir / command, "#!/usr/bin/env bash\nexit 0\n")
    env = os.environ.copy() | {
        "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
        "PG_PROFILE": "forgejo",
        "ROOT_DIR": str(tmp_path),
    }

    result = run("bash", "scripts/pg-bluegreen.sh", "show-active", cwd=tmp_path, env=env)

    assert result.returncode == 0, result.stderr
    assert "profile: forgejo" in result.stdout
    assert "type: helm-value" in result.stdout


def assert_all_but_cutover_is_serial_and_stops_on_first_failure(tmp_path: Path) -> None:
    isolated_tasks(tmp_path)
    calls = fake_bluegreen(tmp_path)
    env = os.environ.copy() | {
        "CALLS": str(calls),
        "FAIL_SUBCOMMAND": "copy-schema",
        "FAIL_EXIT": "37",
    }

    result = run("mise", "run", "postgres:all-but-cutover", "PG_PROFILE=forgejo", cwd=tmp_path, env=env)

    assert result.returncode == 37
    actual = [json.loads(line)["argv"][0] for line in calls.read_text().splitlines()]
    assert actual == list(SEQUENCE[:5])


def assert_sop_uses_canonical_mise_commands() -> None:
    result = run("mise", "run", "postgres:sop")

    assert result.returncode == 0, result.stderr
    assert "CNPG PG16 -> PG18 blue/green SOP" in result.stdout
    assert "mise run postgres:discover PG_PROFILE=<app>" in result.stdout
    assert "mise run postgres:all-but-cutover PG_PROFILE=<app>" in result.stdout
    assert "mise run postgres:cleanup PG_PROFILE=<app>" in result.stdout
    assert "task postgres:" not in result.stdout


class TestMisePostgres(unittest.TestCase):
    def test_postgres_tasks_are_native_and_task_implementation_is_removed(self) -> None:
        assert_postgres_tasks_are_native_and_task_implementation_is_removed()

    def test_workflow_runs_postgres_contracts_for_every_postgres_path(self) -> None:
        assert_workflow_runs_postgres_contracts_for_every_postgres_path()

    def test_every_direct_task_forwards_its_own_subcommand(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tmp_path = Path(directory)
            isolated_tasks(tmp_path)
            calls = fake_bluegreen(tmp_path)
            env = os.environ.copy() | {"CALLS": str(calls)}
            for task in DIRECT_TASKS:
                with self.subTest(task=task):
                    assert_direct_task_forwards_its_subcommand(tmp_path, task, calls, env)

    def test_task_forwards_subcommand_defaults_and_explicit_environment(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            assert_task_forwards_subcommand_defaults_and_explicit_environment(Path(directory))

    def test_profile_is_loaded_from_the_preserved_profile_path(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            assert_profile_is_loaded_from_the_preserved_profile_path(Path(directory))

    def test_all_but_cutover_is_serial_and_stops_on_first_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            assert_all_but_cutover_is_serial_and_stops_on_first_failure(Path(directory))

    def test_sop_uses_canonical_mise_commands(self) -> None:
        assert_sop_uses_canonical_mise_commands()
