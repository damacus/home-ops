import json
import subprocess
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
HELMRELEASE = REPO_ROOT / "kubernetes/apps/monitoring/vector/app/helmrelease.yaml"


class VectorConfigTests(unittest.TestCase):
    def test_loki_allows_dynamic_kubernetes_label_templates(self) -> None:
        result = subprocess.run(
            ["yq", "-o=json", str(HELMRELEASE)],
            check=True,
            capture_output=True,
            text=True,
        )
        manifest = json.loads(result.stdout)
        loki = manifest["spec"]["values"]["customConfig"]["sinks"]["loki"]

        self.assertIs(True, loki["dangerously_allow_unconfined_template_resolution"])


if __name__ == "__main__":
    unittest.main()
