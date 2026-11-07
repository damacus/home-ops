"""Grafana must retain provisioned resources without Kubernetes API access."""
from pathlib import Path
import json
import unittest
import os
import subprocess
import yaml
ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "kubernetes/apps/monitoring/grafana/app"

class GrafanaProvisioningTests(unittest.TestCase):
    def setUp(self) -> None:
        self.values = yaml.safe_load((APP / "helmrelease.yaml").read_text())["spec"]["values"]

    def test_no_discovery_or_api_credentials(self) -> None:
        for feature in ("dashboards", "alerts", "datasources", "plugins", "notifiers"):
            self.assertFalse(self.values["sidecar"].get(feature, {}).get("enabled", False))
        self.assertFalse(self.values["rbac"]["create"])
        self.assertFalse(self.values["automountServiceAccountToken"])
        self.assertFalse(self.values["serviceAccount"]["automountServiceAccountToken"])

    def test_alerts_keep_their_source_and_uid(self) -> None:
        mount = next(m for m in self.values["extraConfigmapMounts"] if m["configMap"] == "unifi-radio-alerts")
        self.assertEqual(mount["mountPath"], "/etc/grafana/provisioning/alerting/unifi.yaml")
        self.assertEqual(mount["subPath"], "unifi.yaml")
        self.assertTrue(mount["readOnly"])
        rules = yaml.safe_load((ROOT / "kubernetes/apps/monitoring/unpoller/app/grafana-alerts.yaml").read_text())
        groups = yaml.safe_load(rules["data"]["unifi.yaml"])["groups"]
        self.assertEqual({r["uid"] for g in groups for r in g["rules"]}, {"unifi-channel-warning", "unifi-channel-critical", "unifi-telemetry-unavailable"})
        self.assertEqual({r["uid"] for g in self.values["alerting"]["rules.yaml"]["groups"] for r in g["rules"]}, {'cnpg-wal-archiving-failing', 'cnpg-recent-backup-failed', 'kube-deployment-replicas-mismatch', 'kube-crashlooping-pods', 'cnpg-last-successful-backup-stale'})

    @unittest.skipUnless(os.environ.get("GRAFANA_CHART_PATH"), "Set GRAFANA_CHART_PATH to run chart integration checks")
    def test_rendered_deployment_has_no_api_access(self) -> None:
        chart = os.environ["GRAFANA_CHART_PATH"]
        result = subprocess.run(
            ["helm", "template", "grafana", chart, "--namespace", "monitoring", "--values", "-"],
            input=yaml.safe_dump(self.values), text=True, capture_output=True, check=True,
        )
        resources = [r for r in yaml.safe_load_all(result.stdout) if r]
        self.assertFalse(any(r["kind"] in {"Role", "RoleBinding", "ClusterRole", "ClusterRoleBinding"} for r in resources))
        deployment = next(r for r in resources if r["kind"] == "Deployment")
        self.assertEqual(deployment["metadata"]["annotations"]["reloader.stakater.com/auto"], "true")
        pod = deployment["spec"]["template"]["spec"]
        self.assertFalse(pod["automountServiceAccountToken"])
        self.assertEqual([c["name"] for c in pod["containers"]], ["grafana"])
        self.assertFalse(any("serviceaccount" in m["mountPath"] for c in pod["containers"] for m in c.get("volumeMounts", [])))
        self.assertIn("unifi-radio-alerts", {v.get("configMap", {}).get("name") for v in pod["volumes"]})
        volume = next(v for v in pod["volumes"] if v["name"] == "provisioned-dashboards")
        sources = volume["projected"]["sources"]
        paths = [item["path"] for source in sources for item in source["configMap"]["items"]]
        self.assertEqual(len(paths), len(set(paths)))
        volumes = {v["name"]: v for v in pod["volumes"]}
        mounts = {m["name"]: m for m in pod["containers"][0]["volumeMounts"]}
        for name, configmap, filename in (
            ("unifi-os-dashboard-file", "unifi-os-dashboard", "unifi-os.json"),
            ("unifi-radio-dashboard-file", "unifi-radio-dashboard", "unifi-radio.json"),
        ):
            self.assertEqual(volumes[name]["configMap"]["name"], configmap)
            self.assertEqual(mounts[name]["mountPath"], f"/var/lib/grafana/dashboards/network/{filename}")
            self.assertEqual(mounts[name]["subPath"], filename)
            self.assertTrue(mounts[name]["readOnly"])

    def test_cross_namespace_dashboards_are_created_in_monitoring(self) -> None:
        for file in ("med-tracker-dashboard.yaml",):
            self.assertEqual(yaml.safe_load((APP / file).read_text())["metadata"]["namespace"], "monitoring")
        cilium = yaml.safe_load((ROOT / "kubernetes/apps/kube-system/cilium/app/values.yaml").read_text())
        self.assertEqual(cilium["dashboards"]["namespace"], "monitoring")
        self.assertEqual(cilium["operator"]["dashboards"]["namespace"], "monitoring")
        cnpg = yaml.safe_load((ROOT / "kubernetes/apps/database/cloudnative-pg/app/helmrelease.yaml").read_text())
        self.assertEqual(cnpg["spec"]["values"]["monitoring"]["grafanaDashboard"]["namespace"], "monitoring")

if __name__ == "__main__":
    unittest.main()
