"""Keep the mutable NorthBot image and its SQLite volume safe in Flux."""

from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "kubernetes/apps/dev/northbot/app"


class NorthBotDeploymentTest(unittest.TestCase):
    def test_northbot_is_discovered_by_flux(self) -> None:
        dev = (ROOT / "kubernetes/apps/dev/kustomization.yaml").read_text()
        self.assertIn("./northbot/ks.yaml", dev)
        rendered = subprocess.run(
            ["kubectl", "kustomize", str(APP)],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
        for expected in (
            "kind: Deployment",
            "replicas: 1",
            "forgejo.ironstone.casa/damacus/northbot:main",
            "imagePullPolicy: Always",
            "storageClassName: openebs-hostpath",
            "kind: ExternalSecret",
            "kind: CronJob",
            "kind: Role",
            "automountServiceAccountToken: false",
        ):
            with self.subTest(expected=expected):
                self.assertIn(expected, rendered)
