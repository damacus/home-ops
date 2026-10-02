"""Deployment contract for the Rust UniFi announcer cutover."""
import json
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "kubernetes/apps/default/unifi-release-announcer/app/HelmRelease.yaml"
PYTHON_IMAGE = "0.2.14@sha256:19ef75ff3c21473a49e07c91ed19aefa9187cd286b8e595d783eb2148cb4a552"


class RustAnnouncerDeploymentTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.values = json.loads(subprocess.run(
            ["yq", "-o=json", "-I=0", ".", str(MANIFEST)],
            capture_output=True, text=True, check=True,
        ).stdout)["spec"]["values"]
        cls.controller = cls.values["controllers"]["app"]
        cls.container = cls.controller["containers"]["app"]

    def test_uses_published_digest_pinned_rust_image(self) -> None:
        image = self.container["image"]
        self.assertEqual(image["repository"], "ghcr.io/damacus/unifi-release-announcer")
        self.assertRegex(image["tag"], r"^\d+\.\d+\.\d+@sha256:[0-9a-f]{64}$")
        self.assertNotEqual(image["tag"], PYTHON_IMAGE)

    def test_cutover_has_one_writer_and_waits_for_shutdown(self) -> None:
        self.assertEqual(self.controller.get("replicas"), 1)
        self.assertEqual(self.controller.get("strategy"), "Recreate")
        self.assertGreaterEqual(
            self.values["defaultPodOptions"].get("terminationGracePeriodSeconds", 0), 35
        )

    def test_runtime_preserves_volume_and_restricts_permissions(self) -> None:
        security = self.container["securityContext"]
        self.assertTrue(security.get("readOnlyRootFilesystem", False))
        self.assertTrue(security["runAsNonRoot"])
        self.assertFalse(security["allowPrivilegeEscalation"])
        self.assertEqual(security["capabilities"]["drop"], ["ALL"])
        self.assertFalse(self.values["defaultPodOptions"]["automountServiceAccountToken"])
        self.assertEqual(self.values["persistence"]["cache"], {
            "accessMode": "ReadWriteOnce", "globalMounts": [{"path": "/cache"}], "size": "10m"
        })

    def test_retains_production_discord_target_and_tags(self) -> None:
        env = {item["name"]: item for item in self.container["env"]}
        self.assertEqual(env["TAGS"]["value"], "unifi-drive,unifi-network,unifi-protect")
        for name in ("DISCORD_BOT_TOKEN", "DISCORD_CHANNEL_ID"):
            self.assertEqual(env[name]["valueFrom"]["secretKeyRef"], {
                "name": "unifi-release-announcer", "key": name
            })
        self.assertNotIn("--dry-run", self.container.get("args", []))


if __name__ == "__main__":
    unittest.main()
