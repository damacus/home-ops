"""Backup repair must preserve existing data claims and pause recovery."""
from pathlib import Path
import unittest
import yaml

ROOT: Path = Path(__file__).resolve().parents[1]
APP: Path = ROOT / "kubernetes/apps/home-automation/paperless/app"


class PaperlessBackupTests(unittest.TestCase):
    def test_existing_claim_is_retained_for_flux_pruning(self) -> None:
        resources = yaml.safe_load((APP / "kustomization.yaml").read_text())["resources"]
        self.assertIn("pvc-ssd.yaml", resources)
        legacy = yaml.safe_load((APP / "pvc-ssd.yaml").read_text())
        self.assertEqual(legacy["metadata"]["name"], "paperless-data-hdd")
        self.assertEqual(legacy["spec"]["resources"]["requests"]["storage"], "100Gi")

    def test_backup_and_restore_match_application_claim(self) -> None:
        source = yaml.safe_load((APP / "volsync/replicationsource.yaml").read_text())["spec"]
        dest = yaml.safe_load((APP / "volsync/replicationdestination.yaml").read_text())["spec"]
        values = yaml.safe_load((APP / "helmrelease.yaml").read_text())["spec"]["values"]
        self.assertEqual(source["sourcePVC"], values["persistence"]["data"]["existingClaim"])
        self.assertEqual(source["restic"]["copyMethod"], "Clone")
        self.assertTrue(dest["paused"])
        claim = yaml.safe_load((APP / "pvc-restore.yaml").read_text())
        self.assertEqual(dest["restic"]["destinationPVC"], claim["metadata"]["name"])
        self.assertEqual(claim["spec"]["storageClassName"], "longhorn")
        self.assertEqual(claim["spec"]["resources"]["requests"]["storage"], "6Gi")
        for settings in (source["restic"], dest["restic"]):
            self.assertEqual(settings["moverSecurityContext"]["runAsUser"], 1030)


if __name__ == "__main__":
    unittest.main()
