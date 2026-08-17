import json
import subprocess
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
HELMRELEASE = REPO_ROOT / "kubernetes/apps/monitoring/vector/app/helmrelease.yaml"


class VectorConfigTests(unittest.TestCase):
    def test_vector_stays_on_safe_release_for_dynamic_loki_labels(self) -> None:
        result = subprocess.run(
            ["yq", "-o=json", str(HELMRELEASE)],
            check=True,
            capture_output=True,
            text=True,
        )
        manifest = json.loads(result.stdout)
        chart = manifest["spec"]["chart"]["spec"]
        image = manifest["spec"]["values"]["image"]
        loki = manifest["spec"]["values"]["customConfig"]["sinks"]["loki"]

        self.assertEqual("0.56.0", chart["version"])
        self.assertEqual("0.56.0-debian", image["tag"])
        self.assertNotIn("dangerously_allow_unconfined_template_resolution", loki)


if __name__ == "__main__":
    unittest.main()
