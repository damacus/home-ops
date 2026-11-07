"""Rendered Loki watchers must not gain Kubernetes Secret permissions."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]
INSTALLATIONS = {
    "monitoring": ("kubernetes/apps/monitoring/loki/app", "loki", "loki-rule-configmaps"),
}

class LokiWatcherTests(unittest.TestCase):
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
                roles = [d for d in docs if d["kind"] in ("Role", "ClusterRole") and "loki" in d["metadata"]["name"]]
                self.assertEqual(roles, [])
                bindings = [d for d in docs if d["kind"] == "ClusterRoleBinding" and "loki" in d["metadata"]["name"]]
                self.assertEqual(len(bindings), 1)
                self.assertEqual(bindings[0]["roleRef"]["name"], role_name)
                self.assertEqual(bindings[0]["subjects"][0]["namespace"], namespace)
                app_output = subprocess.check_output(["kubectl", "kustomize", str(ROOT / directory)], text=True)
                app_resources = [d for d in yaml.safe_load_all(app_output) if d]
                role = next(d for d in app_resources if d["kind"] == "ClusterRole" and d["metadata"]["name"] == role_name)
                self.assertTrue(role["rules"])
                for rule in role["rules"]:
                    self.assertEqual(rule["apiGroups"], [""])
                    self.assertEqual(rule["resources"], ["configmaps"])
                    self.assertEqual(set(rule["verbs"]), {"get", "list", "watch"})

if __name__ == "__main__":
    unittest.main()
