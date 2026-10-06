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

    def test_all_discovered_dashboards_are_mounted(self) -> None:
        volume = next(v for v in self.values["extraVolumes"] if v["name"] == "provisioned-dashboards")
        names = {s["configMap"]["name"] for s in volume["projected"]["sources"]}
        expected = set(EXPECTED)
        self.assertEqual(names, expected)
        paths = [item["path"] for s in volume["projected"]["sources"] for item in s["configMap"]["items"]]
        self.assertEqual(len(paths), len(set(paths)))
        mount = next(m for m in self.values["extraVolumeMounts"] if m["name"] == "provisioned-dashboards")
        self.assertTrue(mount["readOnly"])

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
        pod = next(r for r in resources if r["kind"] == "Deployment")["spec"]["template"]["spec"]
        self.assertFalse(pod["automountServiceAccountToken"])
        self.assertEqual([c["name"] for c in pod["containers"]], ["grafana"])
        self.assertFalse(any("serviceaccount" in m["mountPath"] for c in pod["containers"] for m in c.get("volumeMounts", [])))
        self.assertIn("unifi-radio-alerts", {v.get("configMap", {}).get("name") for v in pod["volumes"]})

    def test_cross_namespace_dashboards_are_created_in_monitoring(self) -> None:
        for file in ("med-tracker-dashboard.yaml", "med-tracker-canary-dashboard.yaml"):
            self.assertEqual(yaml.safe_load((APP / file).read_text())["metadata"]["namespace"], "monitoring")
        cilium = yaml.safe_load((ROOT / "kubernetes/apps/kube-system/cilium/app/values.yaml").read_text())
        self.assertEqual(cilium["dashboards"]["namespace"], "monitoring")
        self.assertEqual(cilium["operator"]["dashboards"]["namespace"], "monitoring")
        cnpg = yaml.safe_load((ROOT / "kubernetes/apps/database/cloudnative-pg/app/helmrelease.yaml").read_text())
        self.assertEqual(cnpg["spec"]["values"]["monitoring"]["grafanaDashboard"]["namespace"], "monitoring")

EXPECTED = ['cilium-dashboard', 'cilium-operator-dashboard', 'cnpg-grafana-dashboard', 'med-tracker-canary-logs-dashboard', 'med-tracker-logs-dashboard', 'unifi-radio-dashboard', 'vm-dashboard-alertmanager-overview', 'vm-dashboard-apiserver', 'vm-dashboard-cluster-total', 'vm-dashboard-k8s-resources-cluster', 'vm-dashboard-k8s-resources-multicluster', 'vm-dashboard-k8s-resources-namespace', 'vm-dashboard-k8s-resources-node', 'vm-dashboard-k8s-resources-nodes-overview', 'vm-dashboard-k8s-resources-pod', 'vm-dashboard-k8s-resources-windows-cluster', 'vm-dashboard-k8s-resources-windows-namespace', 'vm-dashboard-k8s-resources-windows-pod', 'vm-dashboard-k8s-resources-workload', 'vm-dashboard-k8s-resources-workloads-namespace', 'vm-dashboard-k8s-windows-cluster-rsrc-use', 'vm-dashboard-k8s-windows-node-rsrc-use', 'vm-dashboard-kubelet', 'vm-dashboard-kubernetes-system-api-server', 'vm-dashboard-kubernetes-system-coredns', 'vm-dashboard-kubernetes-views-global', 'vm-dashboard-kubernetes-views-namespaces', 'vm-dashboard-kubernetes-views-nodes', 'vm-dashboard-kubernetes-views-pods', 'vm-dashboard-namespace-by-pod', 'vm-dashboard-namespace-by-workload', 'vm-dashboard-node-cluster-rsrc-use', 'vm-dashboard-node-exporter-full', 'vm-dashboard-node-rsrc-use', 'vm-dashboard-nodes', 'vm-dashboard-nodes-aix', 'vm-dashboard-nodes-darwin', 'vm-dashboard-persistentvolumesusage', 'vm-dashboard-pod-total', 'vm-dashboard-prometheus', 'vm-dashboard-prometheus-remote-write', 'vm-dashboard-victoriametrics-operator', 'vm-dashboard-victoriametrics-single-node', 'vm-dashboard-victoriametrics-vmagent', 'vm-dashboard-victoriametrics-vmalert', 'vm-dashboard-workload-total']
if __name__ == "__main__":
    unittest.main()
