from __future__ import annotations

import importlib.util
import pathlib
import sys
import tempfile
import unittest


SCRIPT_PATH = pathlib.Path(__file__).resolve().parents[1] / "scripts" / "mondoo_scan.py"


def load_mondoo_scan():
    spec = importlib.util.spec_from_file_location("mondoo_scan", SCRIPT_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"unable to load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules["mondoo_scan"] = module
    spec.loader.exec_module(module)
    return module


class MondooCommandTest(unittest.TestCase):
    def setUp(self) -> None:
        self.mondoo_scan = load_mondoo_scan()

    def test_custom_scan_uses_incognito_and_failing_risk_threshold(self) -> None:
        command = self.mondoo_scan.cnspec_scan_command(
            ["k8s", "/tmp/rendered.yaml"],
            policy_bundle=pathlib.Path("mondoo/policies/home-ops-kubernetes.mql.yaml"),
            policy="home-ops-kubernetes-manifests",
            asset_name="home-ops-rendered-manifests",
        )

        self.assertEqual(command[:4], ["cnspec", "scan", "k8s", "/tmp/rendered.yaml"])
        self.assertIn("--incognito", command)
        self.assertIn("--risk-threshold", command)
        self.assertEqual(command[command.index("--risk-threshold") + 1], "1")
        self.assertIn("--policy-bundle", command)
        self.assertIn("--policy", command)
        self.assertIn("--asset-name", command)

    def test_report_only_scan_uses_non_failing_risk_threshold(self) -> None:
        command = self.mondoo_scan.cnspec_scan_command(
            ["k8s"],
            risk_threshold=self.mondoo_scan.REPORT_ONLY_RISK_THRESHOLD,
        )

        self.assertEqual(command[command.index("--risk-threshold") + 1], "101")

    def test_app_scan_maps_known_app_to_policy(self) -> None:
        app_scan = self.mondoo_scan.APP_SCANS["home-automation/paperless"]

        self.assertEqual(app_scan.policy, "home-ops-app-paperless")
        self.assertEqual(app_scan.asset_name, "home-ops-paperless-oidc")

    def test_node_scan_uses_ssh_sudo_and_pi_user(self) -> None:
        command = self.mondoo_scan.cnspec_scan_command(
            ["ssh", "pi@node-abcdef"],
            policy_bundle=self.mondoo_scan.NODE_POLICY,
            sudo=True,
        )

        self.assertEqual(command[:4], ["cnspec", "scan", "ssh", "pi@node-abcdef"])
        self.assertIn("--sudo", command)
        self.assertIn(str(self.mondoo_scan.NODE_POLICY), command)

    def test_image_scan_passes_rootfs_property(self) -> None:
        with tempfile.TemporaryDirectory() as mount:
            commands: list[list[str]] = []
            original_run_scan = self.mondoo_scan.run_scan
            self.mondoo_scan.run_scan = commands.append
            try:
                self.mondoo_scan.main(["image", "--mount", mount])
            finally:
                self.mondoo_scan.run_scan = original_run_scan

        self.assertEqual(len(commands), 1)
        command = commands[0]
        self.assertIn("local", command)
        self.assertIn("--props", command)
        self.assertIn(f"rootfs={pathlib.Path(mount).resolve()}", command)

    def test_flux_render_command_uses_flate_build(self) -> None:
        command = self.mondoo_scan.flux_render_command("./kubernetes")

        self.assertEqual(
            command,
            [
                "flate",
                "build",
                "all",
                "--api-versions",
                self.mondoo_scan.FLATE_API_VERSIONS,
                "--path",
                "./kubernetes",
            ],
        )

    def test_all_migrated_checks_have_mondoo_policy_markers(self) -> None:
        bundle_text = self.mondoo_scan.policy_text()
        missing = [
            check
            for checks in self.mondoo_scan.MIGRATED_COMPLIANCE_CHECKS.values()
            for check in checks
            if check not in bundle_text
        ]

        self.assertEqual(missing, [])


if __name__ == "__main__":
    unittest.main()
