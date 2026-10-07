"""Render deployed charts to enforce ConfigMap-only cross-namespace discovery."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]
INSTALLATIONS = {
    "monitoring": ("kubernetes/apps/monitoring/loki/app", "loki", "loki-rule-configmaps"),
    "openebs-system": ("kubernetes/apps/openebs-system/openebs/app", "openebs", "openebs-loki-rule-configmaps"),
}

class LokiWatcherTests(unittest.TestCase):
    def test_configmap_only_discovery_permissions(self) -> None:
        for namespace, (directory, chart, role_name) in INSTALLATIONS.items():
            with self.subTest(namespace=namespace):
                app = ROOT / directory
                hr = next(d for d in yaml.safe_load_all((app / "helmrelease.yaml").read_text()) if d["kind"] == "HelmRelease")
                values = hr["spec"]["values"]
                settings = values if chart == "loki" else values["loki"]
                self.assertIs(settings["sidecar"]["rules"]["enabled"], True)
                self.assertEqual(settings["sidecar"]["rules"]["resource"], "configmap")
                self.assertEqual(settings["sidecar"]["rules"]["searchNamespace"], ["ALL"])
                self.assertEqual(settings["sidecar"]["rules"]["label"], "loki_rule")
                self.assertEqual(settings["sidecar"]["image"]["tag"], "0.2.5")
                self.assertEqual(settings["rbac"]["useExistingRole"], role_name)
                self.assertFalse(settings["rbac"]["namespaced"])
                self.assertIs(settings["serviceAccount"]["automountServiceAccountToken"], True)
                self.assertIn("./rule-discovery-rbac.yaml", yaml.safe_load((app / "kustomization.yaml").read_text())["resources"])
                role = yaml.safe_load((app / "rule-discovery-rbac.yaml").read_text())
                self.assertEqual(role["kind"], "ClusterRole")
                self.assertEqual(role["metadata"]["name"], role_name)
                self.assertEqual(role["rules"], [{"apiGroups": [""], "resources": ["configmaps"], "verbs": ["get", "list", "watch"]}])

    @unittest.skipUnless(os.environ.get("LOKI_CHARTS_PATH"), "Set LOKI_CHARTS_PATH for render tests")
    def test_rendered_watchers_bind_only_custom_roles(self) -> None:
        for namespace, (directory, chart, role_name) in INSTALLATIONS.items():
            with self.subTest(namespace=namespace):
                hr = next(d for d in yaml.safe_load_all((ROOT / directory / "helmrelease.yaml").read_text()) if d["kind"] == "HelmRelease")
                with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml") as f:
                    yaml.safe_dump(hr["spec"]["values"], f); f.flush()
                    output = subprocess.check_output(["helm", "template", chart, str(Path(os.environ["LOKI_CHARTS_PATH"]) / chart), "-n", namespace, "-f", f.name], text=True)
                docs = [d for d in yaml.safe_load_all(output) if d]
                pods = [d["spec"]["template"]["spec"] for d in docs if d["kind"] == "StatefulSet" and any(c["name"] == "loki" for c in d["spec"]["template"]["spec"]["containers"])]
                self.assertTrue(pods)
                for pod in pods:
                    self.assertIs(pod["automountServiceAccountToken"], True)
                    sidecar = next(c for c in pod["containers"] if c["name"] == "loki-sc-rules")
                    env = {e["name"]: e.get("value") for e in sidecar["env"]}
                    self.assertEqual(env["RESOURCE"], "configmap")
                    self.assertEqual(env["NAMESPACE"], "ALL")
                    self.assertEqual(env["LABEL"], "loki_rule")
                    self.assertIn("k8s-sideca-rs", sidecar["image"])
                if chart == "openebs":
                    config = next(yaml.safe_load(d["data"]["config.yaml"]) for d in docs if d["kind"] == "ConfigMap" and "loki" in d["metadata"]["name"] and "config.yaml" in d.get("data", {}))
                    self.assertEqual(config["ruler"]["storage"], {"type": "s3", "s3": {"bucketnames": "ruler"}})
                    self.assertEqual(env["FOLDER"], "/rules")
                roles = [d for d in docs if d["kind"] in ("Role", "ClusterRole") and "loki" in d["metadata"]["name"]]
                self.assertEqual(roles, [])
                bindings = [d for d in docs if d["kind"] == "ClusterRoleBinding" and "loki" in d["metadata"]["name"]]
                self.assertEqual(len(bindings), 1)
                self.assertEqual(bindings[0]["roleRef"]["name"], role_name)
                self.assertEqual(bindings[0]["subjects"][0]["namespace"], namespace)

if __name__ == "__main__":
    unittest.main()
