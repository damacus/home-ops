"""Exercise Kured's configured reboot check without touching host markers."""

from __future__ import annotations

import json
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
RELEASE = ROOT / "kubernetes/apps/kube-system/kured/app/helmrelease.yaml"


class KuredRebootMarkersTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        release = json.loads(subprocess.check_output(
            ["yq", "-o=json", ".", str(RELEASE)], text=True,
        ))
        cls.configuration = release["spec"]["values"]["configuration"]

    def test_chart_enables_the_host_namespace_command(self) -> None:
        # Chart 6.1.0 suppresses rebootSentinelCommand when this is true.
        self.assertIs(self.configuration.get("useRebootSentinelHostPath"), False)
        self.assertTrue(self.configuration.get("rebootSentinelCommand"))

    def test_markers_require_one_reboot_and_clear_after_boot(self) -> None:
        command = self.configuration.get("rebootSentinelCommand", "")
        self.assertTrue(command, "Kured needs a check covering both marker formats")
        for markers in ((), ("reboot-required",), (".reboot_required",),
                        ("reboot-required", ".reboot_required")):
            with self.subTest(markers=markers), tempfile.TemporaryDirectory() as tmp:
                run_dir = Path(tmp)
                for marker in markers:
                    (run_dir / marker).touch()
                # Run the actual configured predicate against an isolated /run.
                args = shlex.split(command.replace("/var/run/", f"{run_dir}/"))
                result = subprocess.run(args, capture_output=True, timeout=5, check=False)
                self.assertEqual(result.returncode, 0 if markers else 1, result.stderr)
                self.assertEqual(sorted(p.name for p in run_dir.iterdir()), sorted(markers))
                for marker in markers:
                    (run_dir / marker).unlink()
                after_boot = subprocess.run(args, capture_output=True, timeout=5, check=False)
                self.assertEqual(after_boot.returncode, 1, after_boot.stderr)


if __name__ == "__main__":
    unittest.main()
