"""Render the deployed charts to verify Loki does not discover Kubernetes rules."""
import copy
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]
INSTALLATIONS = {
    "monitoring": ("kubernetes/apps/monitoring/loki/app/helmrelease.yaml", "loki"),
    "openebs-system": ("kubernetes/apps/openebs-system/openebs/app/helmrelease.yaml", "openebs"),
}

class LokiWatcherTests(unittest.TestCase):
    def test_explicitly_disable_discovery_and_tokens(self) -> None:
        for namespace, (manifest, chart) in INSTALLATIONS.items():
            with self.subTest(namespace=namespace):
                release = next(d for d in yaml.safe_load_all((ROOT / manifest).read_text()) if d["kind"] == "HelmRelease")
                values = release["spec"]["values"]
                loki = values if chart == "loki" else values["loki"]
                self.assertIs(loki.get("sidecar", {}).get("rules", {}).get("enabled"), False)
                self.assertIs(loki.get("serviceAccount", {}).get("automountServiceAccountToken"), False)

    @unittest.skipUnless(os.environ.get("LOKI_CHARTS_PATH"), "Set LOKI_CHARTS_PATH for exact-chart render tests")
    def test_render_removes_watchers_and_secret_access(self) -> None:
        for namespace, (manifest, chart) in INSTALLATIONS.items():
            with self.subTest(namespace=namespace):
                release = next(d for d in yaml.safe_load_all((ROOT / manifest).read_text()) if d["kind"] == "HelmRelease")
                values = release["spec"]["values"]
                baseline = copy.deepcopy(values)
                settings = baseline if chart == "loki" else baseline["loki"]
                settings["sidecar"].setdefault("rules", {})["enabled"] = True
                settings.setdefault("serviceAccount", {})["automountServiceAccountToken"] = True
                rendered = []
                for config in (baseline, values):
                    with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml") as f:
                        yaml.safe_dump(config, f)
                        f.flush()
                        output = subprocess.check_output(["helm", "template", chart, str(Path(os.environ["LOKI_CHARTS_PATH"]) / chart), "--namespace", namespace, "-f", f.name], text=True)
                        rendered.append([d for d in yaml.safe_load_all(output) if d])
                old, new = rendered
                def loki_pods(docs: list[dict]) -> list[dict]:
                    return [d["spec"]["template"]["spec"] for d in docs if d["kind"] == "StatefulSet" and any(c["name"] == "loki" for c in d["spec"]["template"]["spec"]["containers"])]
                self.assertTrue(loki_pods(new))
                self.assertTrue(any(c["name"] == "loki-sc-rules" for p in loki_pods(old) for c in p["containers"]))
                for pod in loki_pods(new):
                    self.assertNotIn("loki-sc-rules", [c["name"] for c in pod["containers"]])
                    self.assertIs(pod.get("automountServiceAccountToken"), False)
                    self.assertFalse(any(v["name"] == "sc-rules-volume" for v in pod.get("volumes", [])))
                for doc in new:
                    if doc["kind"] in ("Role", "ClusterRole", "RoleBinding", "ClusterRoleBinding") and "loki" in doc["metadata"]["name"]:
                        self.fail("Loki discovery RBAC still rendered: " + doc["metadata"]["name"])
                def ruler_configs(docs: list[dict]) -> list[dict]:
                    configs = []
                    for doc in docs:
                        if doc["kind"] in ("ConfigMap", "Secret"):
                            for value in doc.get("data", {}).values():
                                try:
                                    parsed = yaml.safe_load(value)
                                except yaml.YAMLError:
                                    continue
                                if isinstance(parsed, dict) and "ruler" in parsed:
                                    configs.append(parsed["ruler"])
                    return configs
                self.assertTrue(ruler_configs(new))
                self.assertEqual(ruler_configs(old), ruler_configs(new))

if __name__ == "__main__":
    unittest.main()
