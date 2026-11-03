"""Protect Paperless backup isolation and restore safety."""

import json
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "kubernetes/apps/home-automation/paperless/app/volsync"


class PaperlessBackupTest(unittest.TestCase):
    def test_backups_isolate_legacy_history_and_keep_restores_paused(self) -> None:
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
        repository = source["spec"]["restic"]["repository"]
        fresh = secrets[repository]["spec"]["target"]["template"]["data"]
        legacy = secrets["rustfs-paperless"]["spec"]["target"]["template"]["data"]
        self.assertNotEqual(fresh["RESTIC_REPOSITORY"], legacy["RESTIC_REPOSITORY"])
        self.assertEqual(source["spec"]["restic"]["copyMethod"], "Clone")
        self.assertEqual(destination["spec"]["restic"]["repository"], repository)
        self.assertTrue(destination["spec"]["paused"])
        self.assertNotEqual(destination["spec"]["restic"]["destinationPVC"], source["spec"]["sourcePVC"])


if __name__ == "__main__":
    unittest.main()
