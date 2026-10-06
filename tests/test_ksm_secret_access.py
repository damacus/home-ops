"""KSM must not collect or receive Kubernetes Secret objects."""
from pathlib import Path
import os
import subprocess
import unittest
import yaml
ROOT = Path(__file__).resolve().parents[1]
HR = ROOT / "kubernetes/apps/monitoring/victoria-metrics/app/helmrelease.yaml"
CHART = os.environ.get("VM_STACK_CHART_PATH")

class KsmSecretAccessTests(unittest.TestCase):
    def test_secret_collector_is_explicitly_excluded(self) -> None:
        values = yaml.safe_load(HR.read_text())["spec"]["values"]
        self.assertIn("secrets", values["kube-state-metrics"].get("collectorsExclude", []))

    @unittest.skipUnless(CHART, "Set VM_STACK_CHART_PATH for Helm integration checks")
    def test_secret_permissions_removed_other_collectors_preserved(self) -> None:
        values = yaml.safe_load(HR.read_text())["spec"]["values"]
        def render(settings: dict) -> list[dict]:
            result = subprocess.run(["helm", "template", "victoria-metrics", CHART, "--namespace", "monitoring", "--values", "-"], input=yaml.safe_dump(settings), text=True, capture_output=True, check=True)
            return [d for d in yaml.safe_load_all(result.stdout) if d]
        desired = render(values)
        baseline = yaml.safe_load(yaml.safe_dump(values))
        baseline["kube-state-metrics"].pop("collectorsExclude", None)
        previous = render(baseline)
        def resources(docs: list[dict]) -> set[str]:
            deployment = next(d for d in docs if d["kind"] == "Deployment" and "kube-state-metrics" in d["metadata"]["name"])
            args = deployment["spec"]["template"]["spec"]["containers"][0]["args"]
            return set(next(a for a in args if a.startswith("--resources=")).split("=", 1)[1].split(","))
        self.assertEqual(resources(desired), resources(previous) - {"secrets"})
        role = next(d for d in desired if d["kind"] == "ClusterRole" and "kube-state-metrics" in d["metadata"]["name"])
        self.assertFalse(any("secrets" in r.get("resources", []) for r in role["rules"]))
        all_resources = {v for r in role["rules"] for v in r.get("resources", [])}
        self.assertTrue({"externalsecrets", "pushsecrets", "objectstores"}.issubset(all_resources))

if __name__ == "__main__":
    unittest.main()
