"""Verify direct Loki rule provisioning and existing notification routing."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "kubernetes/apps/monitoring/loki/app"

class LokiAlertTests(unittest.TestCase):
    def test_rules_are_provisioned_without_discovery(self) -> None:
        resources = yaml.safe_load((APP / "kustomization.yaml").read_text())["resources"]
        self.assertIn("./rules.yaml", resources)
        rules = yaml.safe_load((APP / "rules.yaml").read_text())
        self.assertEqual(rules["kind"], "ConfigMap")
        self.assertIn("loki_rule", rules["metadata"].get("labels", {}))
        groups = yaml.safe_load(rules["data"]["home-ops.yaml"])["groups"]
        alerts = {r["alert"]: r for g in groups for r in g["rules"]}
        self.assertEqual(set(alerts), {"FrigateCameraRepeatedFailures", "IronBridgeDeliveryExhausted", "ApplicationStorageWriteFailure"})
        self.assertEqual(alerts["FrigateCameraRepeatedFailures"]["for"], "5m")
        self.assertEqual(alerts["ApplicationStorageWriteFailure"]["labels"]["severity"], "critical")
        for rule in alerts.values():
            self.assertNotIn("{{ $labels.message }}", str(rule))

    @unittest.skipUnless(os.environ.get("LOKI_CHARTS_PATH"), "Set LOKI_CHARTS_PATH for chart render validation")
    def test_render_mounts_rules_and_routes_to_alertmanager(self) -> None:
        release = next(d for d in yaml.safe_load_all((APP / "helmrelease.yaml").read_text()) if d["kind"] == "HelmRelease")
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml") as f:
            yaml.safe_dump(release["spec"]["values"], f)
            f.flush()
            output = subprocess.check_output(["helm", "template", "loki", str(Path(os.environ["LOKI_CHARTS_PATH"]) / "loki"), "-n", "monitoring", "-f", f.name], text=True)
        docs = [d for d in yaml.safe_load_all(output) if d]
        pod = next(d["spec"]["template"]["spec"] for d in docs if d["kind"] == "StatefulSet" and d["metadata"]["name"] == "loki")
        container = next(c for c in pod["containers"] if c["name"] == "loki")
        sidecar = next(c for c in pod["containers"] if c["name"] == "loki-sc-rules")
        env = {e["name"]: e.get("value") for e in sidecar["env"]}
        self.assertEqual(env["FOLDER"], "/rules/fake")
        self.assertEqual(env["UNIQUE_FILENAMES"], "true")
        self.assertFalse(any(v["name"] == "explicit-rules" for v in pod["volumes"]))
        config = next(yaml.safe_load(d["data"]["config.yaml"]) for d in docs if d["kind"] == "ConfigMap" and "config.yaml" in d.get("data", {}))
        self.assertEqual(config["ruler"]["storage"]["local"]["directory"], "/rules")
        self.assertEqual(config["ruler"]["alertmanager_url"], "http://vmalertmanager-vm.monitoring.svc.cluster.local:9093")
        self.assertFalse(config["auth_enabled"])
        self.assertIs(pod["automountServiceAccountToken"], True)
        self.assertIn("loki-sc-rules", [c["name"] for c in pod["containers"]])

if __name__ == "__main__":
    unittest.main()
