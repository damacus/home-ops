import json
import subprocess
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
HELMRELEASE = REPO_ROOT / "kubernetes/apps/network/cloudflared/app/helmrelease.yaml"


class CloudflaredConfigTests(unittest.TestCase):
    def test_failed_upgrade_rolls_back_to_the_last_release(self) -> None:
        result = subprocess.run(
            ["yq", "-o=json", str(HELMRELEASE)],
            check=True,
            capture_output=True,
            text=True,
        )
        manifest = json.loads(result.stdout)
        remediation = manifest["spec"]["upgrade"]["remediation"]

        self.assertEqual("rollback", remediation["strategy"])
        self.assertTrue(remediation["remediateLastFailure"])


if __name__ == "__main__":
    unittest.main()
