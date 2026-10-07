"""Check maintenance safety in the exact pinned Helm chart output."""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class MaintenanceChartsTest(unittest.TestCase):
    def render(self, name: str, namespace: str) -> str:
        filename = "HelmRelease.yaml" if name == "longhorn" else "helmrelease.yaml"
        release = ROOT / f"kubernetes/apps/{namespace}/{name}/app/{filename}"
        hr = json.loads(subprocess.check_output(["yq", "-o=json", ".", str(release)], text=True))
        chart = Path(os.environ["MAINTENANCE_CHARTS_PATH"]) / name
        with tempfile.TemporaryDirectory() as tmp:
            values = Path(tmp) / "values.json"
            values.write_text(json.dumps(hr["spec"]["values"]), encoding="utf-8")
            metadata = json.loads(subprocess.check_output(["yq", "-o=json", ".", str(chart / "Chart.yaml")], text=True))
            self.assertEqual(metadata["version"], hr["spec"]["chart"]["spec"]["version"])
            return subprocess.check_output(["helm", "template", name, str(chart), "-f", str(values)], text=True)

    def test_kured_aborts_failed_drains_without_forcing_reboots(self) -> None:
        rendered = self.render("kured", "kube-system")
        self.assertIn("--drain-timeout=15m", rendered)
        self.assertNotIn("--force-reboot", rendered)

    def test_longhorn_preserves_running_last_replica_protection(self) -> None:
        rendered = self.render("longhorn", "storage")
        self.assertIn('node-drain-policy: "allow-if-replica-is-stopped"', rendered)
        self.assertNotIn('node-drain-policy: "always-allow"', rendered)


if __name__ == "__main__":
    unittest.main()
