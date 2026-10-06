"""The rendered KSM permission regression must run in pull-request CI."""
from pathlib import Path
import unittest
import yaml

ROOT: Path = Path(__file__).resolve().parents[1]


class KsmCiTests(unittest.TestCase):
    def test_ci_runs_render_test_with_pinned_chart(self) -> None:
        workflow = yaml.safe_load((ROOT / ".github/workflows/flux.yaml").read_text())
        steps = workflow["jobs"]["mondoo"]["steps"]
        step = next((step for step in steps if "test_ksm_secret_access.py" in step.get("run", "")), {})
        self.assertIn("VM_STACK_CHART_PATH", step.get("env", {}))
        self.assertIn("helm pull", step.get("run", ""))
        self.assertIn('["spec"]["chart"]["spec"]["version"]', step.get("run", ""))


if __name__ == "__main__":
    unittest.main()
