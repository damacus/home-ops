"""Keep Gateway API reconciliation on the installed standard bundle."""
from __future__ import annotations
import json
from pathlib import Path
import subprocess
import unittest
ROOT = Path(__file__).resolve().parents[1]
class GatewayAPISourceTest(unittest.TestCase):
    def test_source_and_crd_reconciler_are_managed_together(self) -> None:
        directory = ROOT / "kubernetes/apps/kube-system/gateway-api"
        docs = subprocess.check_output(["kubectl", "kustomize", str(directory)], text=True)
        resources = [json.loads(subprocess.check_output(["yq", "-o=json", ".", "-"], input=doc, text=True)) for doc in docs.split("---") if doc.strip()]
        source = next(item for item in resources if item["kind"] == "GitRepository")
        reconciler = next(item for item in resources if item["kind"] == "Kustomization" and item["apiVersion"].startswith("kustomize.toolkit"))
        self.assertEqual(source["metadata"]["name"], "gateway-api")
        self.assertEqual(source["spec"]["ref"]["tag"], "v1.6.1")
        self.assertEqual(reconciler["metadata"]["name"], "gateway-api-crds")
        self.assertEqual(reconciler["spec"]["sourceRef"]["name"], source["metadata"]["name"])
        self.assertEqual(reconciler["spec"]["path"], "./config/crd/standard")
        self.assertFalse(reconciler["spec"]["prune"])
        namespace = subprocess.check_output(["kubectl", "kustomize", str(directory.parent)], text=True)
        self.assertIn("name: gateway-api-crds", namespace)
if __name__ == "__main__":
    unittest.main()
