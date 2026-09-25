"""Verify control-plane upgrades wait for the VIP and control-plane health."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
PLAN = ROOT / "kubernetes/apps/system-upgrade/k3s/app/plan.yaml"


class SystemUpgradeHealthGateTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        rendered = subprocess.check_output(
            ["yq", "-o=json", "select(.kind == \"Plan\" and .metadata.name == \"controllers\")", str(PLAN)],
            text=True,
        )
        cls.plan = json.loads(rendered)
        cls.prepare = cls.plan["spec"].get("prepare", {})
        cls.script = "\n".join(cls.prepare.get("args", []))

    def test_controller_plan_runs_health_gate_before_cordon(self) -> None:
        self.assertEqual(self.prepare.get("image"), "rancher/k3s-upgrade")
        self.assertEqual(self.prepare.get("command"), ["/bin/sh", "-ec"])
        self.assertIn("KUBERNETES_SERVICE_HOST=192.168.1.220", self.script)
        self.assertIn("KUBERNETES_SERVICE_PORT=6443", self.script)
        self.assertIn("get --raw=/readyz", self.script)
        self.assertIn("node-role.kubernetes.io/control-plane", self.script)
        self.assertLess(self.script.index("get --raw=/readyz"), self.script.index("get nodes"))
        self.assertEqual(self.plan["spec"].get("jobActiveDeadlineSecs"), 0)

    def test_gate_waits_for_vip_and_every_control_plane_node(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            temp_dir = Path(tmp)
            fake_k3s = temp_dir / "k3s"
            fake_k3s.write_text(
                "#!/bin/sh\n"
                "[ \"$1\" = kubectl ] || exit 2\n"
                "shift\n"
                "[ \"$1\" = --request-timeout=5s ] && shift\n"
                "case \"$*\" in\n"
                "  \"get --raw=/readyz\")\n"
                "    count=$(cat \"$READY_COUNT_FILE\" 2>/dev/null || echo 0)\n"
                "    count=$((count + 1))\n"
                "    echo \"$count\" > \"$READY_COUNT_FILE\"\n"
                "    [ \"$count\" -gt \"$READY_AFTER\" ]\n"
                "    ;;\n"
                "  \"get nodes --selector=node-role.kubernetes.io/control-plane -o json\")\n"
                "    count=$(cat \"$NODES_COUNT_FILE\" 2>/dev/null || echo 0)\n"
                "    count=$((count + 1))\n"
                "    echo \"$count\" > \"$NODES_COUNT_FILE\"\n"
                "    [ \"$count\" -gt 1 ] || exit 1\n"
                "    cat \"$NODES_FILE\"\n"
                "    ;;\n"
                "  *) exit 2 ;;\n"
                "esac\n",
                encoding="utf-8",
            )
            fake_k3s.chmod(0o755)
            fake_sleep = temp_dir / "sleep"
            fake_sleep.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            fake_sleep.chmod(0o755)
            nodes_file = temp_dir / "nodes.json"
            nodes_file.write_text(
                json.dumps(
                    {
                        "items": [
                            {"status": {"conditions": [{"type": "Ready", "status": "True"}]}},
                            {"status": {"conditions": [{"type": "Ready", "status": "True"}]}},
                            {"status": {"conditions": [{"type": "Ready", "status": "True"}]}},
                        ]
                    }
                ),
                encoding="utf-8",
            )
            env = {
                **os.environ,
                "K3S_BIN": str(fake_k3s),
                "SLEEP_BIN": str(fake_sleep),
                "READY_COUNT_FILE": str(temp_dir / "ready-count"),
                "READY_AFTER": "1",
                "NODES_COUNT_FILE": str(temp_dir / "nodes-count"),
                "NODES_FILE": str(nodes_file),
            }
            result = subprocess.run(
                ["/bin/sh", "-ec", self.script],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("all control-plane nodes are Ready", result.stdout)
        self.assertEqual(result.stdout.count("Waiting for API VIP readiness"), 2)

    def test_gate_keeps_waiting_when_a_control_plane_node_is_not_ready(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            temp_dir = Path(tmp)
            fake_k3s = temp_dir / "k3s"
            fake_k3s.write_text(
                "#!/bin/sh\n"
                "[ \"$1\" = kubectl ] || exit 2\n"
                "shift\n"
                "[ \"$1\" = --request-timeout=5s ] && shift\n"
                "case \"$*\" in\n"
                "  \"get --raw=/readyz\") exit 0 ;;\n"
                "  \"get nodes --selector=node-role.kubernetes.io/control-plane -o json\") cat \"$NODES_FILE\" ;;\n"
                "  *) exit 2 ;;\n"
                "esac\n",
                encoding="utf-8",
            )
            fake_k3s.chmod(0o755)
            fake_sleep = temp_dir / "sleep"
            fake_sleep.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            fake_sleep.chmod(0o755)
            nodes_file = temp_dir / "nodes.json"
            nodes_file.write_text(
                json.dumps(
                    {
                        "items": [
                            {"status": {"conditions": [{"type": "Ready", "status": "True"}]}},
                            {"status": {"conditions": [{"type": "Ready", "status": "False"}]}},
                            {"status": {"conditions": [{"type": "Ready", "status": "True"}]}},
                        ]
                    }
                ),
                encoding="utf-8",
            )
            env = {
                **os.environ,
                "K3S_BIN": str(fake_k3s),
                "SLEEP_BIN": str(fake_sleep),
                "NODES_FILE": str(nodes_file),
            }
            with self.assertRaises(subprocess.TimeoutExpired):
                subprocess.run(
                    ["/bin/sh", "-ec", self.script],
                    env=env,
                    capture_output=True,
                    text=True,
                    timeout=0.2,
                    check=False,
                )


if __name__ == "__main__":
    unittest.main()
