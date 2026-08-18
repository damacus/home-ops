from __future__ import annotations

import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


def job_block(workflow: str, job: str) -> str:
    match = re.search(
        rf"^  {re.escape(job)}:\n(?P<body>.*?)(?=^  [a-z0-9-]+:\n|\Z)",
        workflow,
        flags=re.MULTILINE | re.DOTALL,
    )
    if match is None:
        raise AssertionError(f"missing workflow job: {job}")
    return match.group("body")


class CiWorkflowContractTest(unittest.TestCase):
    def workflow(self, name: str) -> str:
        return (ROOT / ".github" / "workflows" / name).read_text()

    def test_lightweight_jobs_use_slim_runners(self) -> None:
        expected_jobs = {
            "docs.yml": ("build", "deploy"),
            "labeler.yaml": ("labeler",),
            "label-sync.yaml": ("label-sync",),
            "flux.yaml": ("changes", "flate-success"),
        }

        for workflow_name, jobs in expected_jobs.items():
            workflow = self.workflow(workflow_name)
            for job in jobs:
                with self.subTest(workflow=workflow_name, job=job):
                    self.assertIn("runs-on: ubuntu-slim", job_block(workflow, job))

    def test_flux_workflow_skips_irrelevant_validation(self) -> None:
        workflow = self.workflow("flux.yaml")
        changes = job_block(workflow, "changes")

        self.assertIn("dorny/paths-filter@", changes)
        self.assertIn("yaml:", changes)
        self.assertIn("kubernetes:", changes)
        self.assertIn("mondoo:", changes)
        self.assertIn("contracts:", changes)

        self.assertIn(
            "needs.changes.outputs.yaml == 'true'", job_block(workflow, "yaml-lint")
        )
        self.assertIn(
            "needs.changes.outputs.kubernetes == 'true'",
            job_block(workflow, "yayamlls"),
        )
        self.assertIn(
            "needs.changes.outputs.contracts == 'true'",
            job_block(workflow, "rustfs-iam-policy"),
        )
        self.assertIn(
            "needs.changes.outputs.mondoo == 'true'",
            job_block(workflow, "mondoo"),
        )

    def test_flux_workflow_avoids_homebrew_setup(self) -> None:
        workflow = self.workflow("flux.yaml")

        self.assertNotIn("Homebrew/actions/setup-homebrew", workflow)
        self.assertNotIn("brew install", workflow)
        self.assertIn("arduino/setup-task@", job_block(workflow, "rustfs-iam-policy"))


if __name__ == "__main__":
    unittest.main()
