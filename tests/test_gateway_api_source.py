"""Removing the Gateway API source must not prune cluster CRDs."""
from __future__ import annotations
import json
from pathlib import Path
import subprocess
import unittest
ROOT = Path(__file__).resolve().parents[1]
class GatewayAPISourceTest(unittest.TestCase):
    def test_crd_reconciler_cannot_prune(self) -> None:
        directory = ROOT / "kubernetes/apps/kube-system/gateway-api"
        docs = subprocess.check_output(["kubectl", "kustomize", str(directory)], text=True)
        resources = [json.loads(subprocess.check_output(["yq", "-o=json", ".", "-"], input=doc, text=True)) for doc in docs.split("---") if doc.strip()]
        reconciler = next(item for item in resources if item["kind"] == "Kustomization" and item["apiVersion"].startswith("kustomize.toolkit"))
        self.assertFalse(reconciler["spec"]["prune"])
if __name__ == "__main__":
    unittest.main()
