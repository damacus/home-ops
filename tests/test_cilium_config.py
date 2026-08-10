import json
import subprocess
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
HELMRELEASE = REPO_ROOT / "kubernetes/apps/kube-system/cilium/app/helmrelease.yaml"
VALUES = REPO_ROOT / "kubernetes/apps/kube-system/cilium/app/values.yaml"


class CiliumConfigTests(unittest.TestCase):
    def test_release_avoids_cilium_1_20_0_xds_livelock(self) -> None:
        result = subprocess.run(
            ["yq", "-o=json", str(HELMRELEASE)],
            check=True,
            capture_output=True,
            text=True,
        )
        manifest = json.loads(result.stdout)

        self.assertEqual("1.19.5", manifest["spec"]["chart"]["spec"]["version"])

    def test_release_preserves_1_19_upgrade_defaults(self) -> None:
        result = subprocess.run(
            ["yq", "-o=json", str(VALUES)],
            check=True,
            capture_output=True,
            text=True,
        )
        values = json.loads(result.stdout)

        self.assertEqual("1.19", values["upgradeCompatibility"])


if __name__ == "__main__":
    unittest.main()
