"""Contract tests for the public Mise facade over Task."""

from __future__ import annotations

import json
import os
import re
import stat
import subprocess
from pathlib import Path


ROOT = Path(__file__).parents[1]


def run(*command: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=ROOT,
        env=env,
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
        "mise",
        "run",
        "init",
        "value with spaces",
        "--literal-flag",
        env=env,
    )

    assert result.returncode == 23
    assert result.stdout == "facade stdout\n"
    assert result.stderr.startswith("facade stderr\n")
    assert result.stderr.endswith("[init] ERROR task failed\n")
    assert arguments_log.read_bytes().split(b"\0")[:-1] == [
        b"init",
        b"--",
        b"value with spaces",
        b"--literal-flag",
    ]
