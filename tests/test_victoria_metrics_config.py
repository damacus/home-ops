import json
import subprocess
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
HELMRELEASE = (
    REPO_ROOT
    / "kubernetes/apps/monitoring/victoria-metrics/app/helmrelease.yaml"
)


class VictoriaMetricsConfigTests(unittest.TestCase):
    def test_kube_state_metrics_has_memory_headroom(self) -> None:
        result = subprocess.run(
            ["yq", "-o=json", str(HELMRELEASE)],
            check=True,
            capture_output=True,
            text=True,
        )
        manifest = json.loads(result.stdout)
        values = manifest["spec"]["values"]["kube-state-metrics"]

        self.assertIn("--auto-gomemlimit", values["extraArgs"])
        self.assertEqual("512Mi", values["resources"]["limits"]["memory"])


if __name__ == "__main__":
    unittest.main()
