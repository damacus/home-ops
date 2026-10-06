"""Exercise the effective kubectl endpoint used by the upgrade gate."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT: Path = Path(__file__).resolve().parents[1]


class UpgradeVipCredentialsTests(unittest.TestCase):
    def test_both_queries_use_vip_and_service_account_credentials(self) -> None:
        plan = json.loads(subprocess.check_output([
            "yq", "-o=json", 'select(.metadata.name == "controllers")',
            str(ROOT / "kubernetes/apps/system-upgrade/k3s/app/plan.yaml"),
        ], text=True))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake = root / "k3s"
            fake.write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ["CALLS"], "a") as stream:
    stream.write(json.dumps(sys.argv[1:]) + "\\n")
if "nodes" in sys.argv:
    print(json.dumps({"items": [{"status": {"conditions": [{"type": "Ready", "status": "True"}]}}] * 3}))
''')
            fake.chmod(0o755)
            (root / "token").write_text("fixture-token")
            (root / "ca.crt").write_text("fixture-ca")
            env = {**os.environ, "K3S_BIN": str(fake), "CALLS": str(root / "calls"),
                   "SERVICE_ACCOUNT_DIR": str(root)}
            subprocess.run(["/bin/sh", "-ec", plan["spec"]["prepare"]["args"][0]],
                           env=env, capture_output=True, text=True, timeout=5, check=True)
            calls = [json.loads(line) for line in (root / "calls").read_text().splitlines()]
            self.assertEqual(len(calls), 2)
            for call in calls:
                self.assertIn("--server=https://192.168.1.220:6443", call)
                self.assertIn("--kubeconfig=/dev/null", call)
                self.assertIn("--token=fixture-token", call)
                self.assertIn("--certificate-authority=" + str(root / "ca.crt"), call)


if __name__ == "__main__":
    unittest.main()
