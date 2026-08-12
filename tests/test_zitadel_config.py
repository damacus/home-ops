import json
import subprocess
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
HELMRELEASE = (
    REPO_ROOT / "kubernetes/apps/authentication/zitadel/app/helmrelease.yaml"
)


class ZitadelConfigTests(unittest.TestCase):
    def test_kubectl_hook_image_uses_available_arm64_tag(self) -> None:
        result = subprocess.run(
            ["yq", "-o=json", str(HELMRELEASE)],
            check=True,
            capture_output=True,
            text=True,
        )
        values = json.loads(result.stdout)["spec"]["values"]

        self.assertEqual("alpine/k8s", values["tools"]["kubectl"]["image"]["repository"])
        self.assertEqual("1.34.1", values["tools"]["kubectl"]["image"]["tag"])
        self.assertNotIn("setupJob", values)


if __name__ == "__main__":
    unittest.main()
