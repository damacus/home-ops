"""Grafana must retain provisioned resources without Kubernetes API access."""
from pathlib import Path
import unittest
import os
import subprocess
import yaml
ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "kubernetes/apps/monitoring/grafana/app"

class GrafanaProvisioningTests(unittest.TestCase):
    def setUp(self) -> None:
        self.values = next(d for d in yaml.safe_load_all((APP / "helmrelease.yaml").read_text()) if d["kind"] == "HelmRelease")["spec"]["values"]

    @unittest.skipUnless(os.environ.get("GRAFANA_CHART_PATH"), "Set GRAFANA_CHART_PATH to run chart integration checks")
    def test_rendered_deployment_has_no_api_access(self) -> None:
        chart = os.environ["GRAFANA_CHART_PATH"]
        result = subprocess.run(
            ["helm", "template", "grafana", chart, "--namespace", "monitoring", "--values", "-"],
            input=yaml.safe_dump(self.values), text=True, capture_output=True, check=True,
        )
        resources = [r for r in yaml.safe_load_all(result.stdout) if r]
        self.assertFalse(any(r["kind"] in {"Role", "RoleBinding", "ClusterRole", "ClusterRoleBinding"} for r in resources))
        pod = next(r for r in resources if r["kind"] == "Deployment")["spec"]["template"]["spec"]
        self.assertFalse(pod["automountServiceAccountToken"])
        self.assertEqual([c["name"] for c in pod["containers"]], ["grafana"])
        self.assertFalse(any("serviceaccount" in m["mountPath"] for c in pod["containers"] for m in c.get("volumeMounts", [])))

if __name__ == "__main__":
    unittest.main()
