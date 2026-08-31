"""Behavioural tests for the public jq task interface."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
TASKFILE = REPOSITORY_ROOT / "Taskfile.yaml"


def run_task(*arguments: str) -> subprocess.CompletedProcess[str]:
    """Run a repository task without depending on the caller's directory."""

    return subprocess.run(
        ["task", "--taskfile", str(TASKFILE), *arguments],
        cwd=REPOSITORY_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )


def test_list_failing_accepts_an_explicit_json_path(tmp_path: Path) -> None:
    task_list = tmp_path / "security.json"
    task_list.write_text(
        json.dumps(
            [
                {
                    "category": "security",
                    "description": "Rotate keys",
                    "passes": False,
                },
                {
                    "category": "security",
                    "description": "Document recovery",
                    "passes": True,
                },
            ]
        ),
        encoding="utf-8",
    )

    result = run_task("jq:list-failing", f"FILE={task_list}")

    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "security: Rotate keys"


def test_list_failing_reports_a_missing_json_file(tmp_path: Path) -> None:
    missing_task_list = tmp_path / "missing.json"

    result = run_task("jq:list-failing", f"FILE={missing_task_list}")

    assert result.returncode != 0
    assert "Missing JSON file" in result.stderr
