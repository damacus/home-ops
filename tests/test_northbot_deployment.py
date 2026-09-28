"""Keep the mutable NorthBot image and its SQLite volume safe in Flux."""

from pathlib import Path
import json
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "kubernetes/apps/dev/northbot/app"


class NorthBotDeploymentTest(unittest.TestCase):
    @staticmethod
    def resources() -> dict[str, dict]:
        rendered = subprocess.run(
            ["kubectl", "kustomize", str(APP)],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
        documents = []
        for document in rendered.split("---\n"):
            if not document.strip():
                continue
            converted = subprocess.run(
                ["yq", "-o=json", "-I=0", "."],
                input=document,
                capture_output=True,
                text=True,
                check=True,
            ).stdout
            documents.append(json.loads(converted))
        return {resource["kind"]: resource for resource in documents}

    def test_northbot_is_discovered_by_flux(self) -> None:
        dev = (ROOT / "kubernetes/apps/dev/kustomization.yaml").read_text()
        self.assertIn("./northbot/ks.yaml", dev)
        rendered = subprocess.run(["kubectl", "kustomize", str(APP)], capture_output=True, text=True, check=True).stdout
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

    def test_sqlite_claim_survives_flux_pruning(self) -> None:
        pvc = self.resources()["PersistentVolumeClaim"]
        self.assertEqual(
            pvc["metadata"]["annotations"]["kustomize.toolkit.fluxcd.io/prune"],
            "disabled",
        )

    def test_secret_changes_and_daily_job_restart_the_deployment(self) -> None:
        resources = self.resources()
        deployment = resources["Deployment"]
        self.assertEqual(
            deployment["metadata"]["annotations"]["reloader.stakater.com/auto"],
            "true",
        )
        job = resources["CronJob"]["spec"]["jobTemplate"]["spec"]["template"]["spec"]
        self.assertEqual(job["serviceAccountName"], "northbot-refresh")
        self.assertEqual(
            job["containers"][0]["command"],
            ["kubectl", "-n", "dev", "rollout", "restart", "deployment/northbot"],
        )
        role = resources["Role"]["rules"][0]
        self.assertEqual(role["resourceNames"], ["northbot"])
        self.assertEqual(set(role["verbs"]), {"get", "patch"})
        self.assertEqual(resources["RoleBinding"]["subjects"][0]["name"], "northbot-refresh")
