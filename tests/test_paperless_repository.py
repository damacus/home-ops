"""Protect Paperless backup isolation and restore safety."""

import json
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "kubernetes/apps/home-automation/paperless/app/volsync"


class PaperlessBackupTest(unittest.TestCase):
    @staticmethod
    def load(path: Path) -> dict:
        return json.loads(subprocess.run(
            ["yq", "-o=json", "-I=0", ".", str(path)],
            check=True, capture_output=True, text=True
        ).stdout)

    def test_existing_claim_is_retained_for_flux_pruning(self) -> None:
        app = APP.parent
        self.assertIn("pvc-ssd.yaml", self.load(app / "kustomization.yaml")["resources"])
        legacy = self.load(app / "pvc-ssd.yaml")
        self.assertEqual(legacy["metadata"]["name"], "paperless-data-hdd")
        self.assertEqual(legacy["spec"]["resources"]["requests"]["storage"], "100Gi")

    def test_backup_and_restore_match_application_claim(self) -> None:
        source = self.load(APP / "replicationsource.yaml")["spec"]
        destination = self.load(APP / "replicationdestination.yaml")["spec"]
        values = self.load(APP.parent / "helmrelease.yaml")["spec"]["values"]
        self.assertEqual(source["sourcePVC"], values["persistence"]["data"]["existingClaim"])
        claim = self.load(APP.parent / "pvc-restore.yaml")
        self.assertEqual(destination["restic"]["destinationPVC"], claim["metadata"]["name"])
        self.assertEqual(claim["spec"]["storageClassName"], "longhorn")
        self.assertEqual(claim["spec"]["resources"]["requests"]["storage"], "6Gi")
        for settings in (source["restic"], destination["restic"]):
            self.assertEqual(settings["moverSecurityContext"]["runAsUser"], 1030)

    def test_new_backups_do_not_mutate_mixed_repository_history(self) -> None:
        rendered = subprocess.run(
            ["kubectl", "kustomize", str(APP)], check=True, capture_output=True, text=True
        ).stdout
        resources = [json.loads(subprocess.run(
            ["yq", "-o=json", "-I=0", "."], input=document,
            check=True, capture_output=True, text=True
        ).stdout) for document in rendered.split("---\n") if document.strip()]
        source = next(x for x in resources if x["kind"] == "ReplicationSource")
        destination = next(x for x in resources if x["kind"] == "ReplicationDestination")
        secrets = {x["metadata"]["name"]: x for x in resources if x["kind"] == "ExternalSecret"}
        fresh = secrets["paperless-restic-local-v2"]["spec"]["target"]["template"]["data"]
        self.assertTrue(fresh["RESTIC_REPOSITORY"].endswith("/volsync-paperless/localdata-v2"))
        self.assertEqual(source["spec"]["restic"]["repository"], "paperless-restic-local-v2")
        self.assertEqual(source["spec"]["sourcePVC"], "paperless-localdata")
        self.assertEqual(source["spec"]["restic"]["copyMethod"], "Clone")
        self.assertEqual(destination["spec"]["restic"]["repository"], "paperless-restic-local-v2")
        self.assertTrue(destination["spec"]["paused"])
        self.assertNotEqual(destination["spec"]["restic"]["destinationPVC"], source["spec"]["sourcePVC"])
        self.assertTrue(secrets["rustfs-paperless"]["spec"]["target"]["template"]["data"]["RESTIC_REPOSITORY"].endswith("/volsync-paperless"))


if __name__ == "__main__":
    unittest.main()
