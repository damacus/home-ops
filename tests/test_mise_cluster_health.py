"""Contract tests for native cluster-health Mise tasks."""

from __future__ import annotations

import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
CHECKS = {
    "health-nodes": "nodes",
    "health-kube-vip": "kube-vip",
    "health-cilium": "cilium",
    "health-pods": "pods",
    "health-deployments": "deployments",
    "cnpg-health": "cnpg-health",
    "cnpg-backups": "cnpg-backups",
    "gitops-health": "gitops-health",
    "external-secrets-health": "external-secrets-health",
    "service-account-health": "service-account-health",
    "grafana-alerts": "grafana-alerts",
    "edge-smoke-esphome": "edge-smoke",
    "log-noise": "log-noise",
}


def run(*command: str, env: dict[str, str] | None = None, cwd: Path = ROOT) -> subprocess.CompletedProcess[str]:
    contract_env = (os.environ if env is None else env).copy()
    contract_env.pop("MISE_LOG_LEVEL", None)
    return subprocess.run(command, cwd=cwd, env=contract_env, text=True, capture_output=True, check=False)


def executable(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def isolated_task(tmp_path: Path, task: str) -> Path:
    task_root = tmp_path / ".mise/tasks/kubernetes"
    task_root.mkdir(parents=True)
    destination = task_root / task
    shutil.copy2(ROOT / f".mise/tasks/kubernetes/{task}", destination)
    return destination


class TestMiseClusterHealth(unittest.TestCase):
    def test_cluster_health_checks_are_native_mise_tasks_without_task_implementations(self) -> None:
        taskfile = (ROOT / ".taskfiles/Kubernetes/Taskfile.yaml").read_text()
        for task, command in CHECKS.items():
            source = (ROOT / f".mise/tasks/kubernetes/{task}").read_text()
            self.assertIn('#MISE depends=["kubernetes:cluster-health-build"]', source)
            self.assertNotIn("exec task ", source)
            self.assertIn(f"cluster-health {command}", source)
            self.assertNotIn(f"  {task}:", taskfile)

        for task in ("health", "morning-check"):
            source = (ROOT / f".mise/tasks/kubernetes/{task}").read_text()
            self.assertIn("mise run ", source)
            self.assertNotIn("exec task ", source)
            self.assertNotIn(f"  {task}:", taskfile)

        self.assertNotIn(".cluster-health-options:", taskfile)
        self.assertNotIn(".cluster-health-build:", taskfile)
        self.assertNotIn(".cluster-health-report:", taskfile)

    def test_health_runs_every_child_in_order_aggregates_failures_and_notifies_once(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tmp_path = Path(directory)
            bin_dir = tmp_path / "bin"
            bin_dir.mkdir()
            (tmp_path / "scripts").mkdir()
            calls = tmp_path / "calls"
            notifications = tmp_path / "notifications"
            executable(
                bin_dir / "mise",
                "#!/usr/bin/env bash\n"
                "printf '%s\\t' \"$@\" >> \"$CALLS\"\n"
                "printf '\\n' >> \"$CALLS\"\n"
                "case \"$2\" in kubernetes:health-cilium) exit 41 ;; esac\n",
            )
            executable(bin_dir / "task", "#!/usr/bin/env bash\nexit 99\n")
            executable(
                tmp_path / "scripts/notify",
                "#!/usr/bin/env bash\n"
                "printf '%s\\t' \"$@\" > \"$NOTIFICATIONS\"\n"
                "printf '\\n' >> \"$NOTIFICATIONS\"\n",
            )
            env = os.environ.copy()
            env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
            env["CALLS"] = str(calls)
            env["NOTIFICATIONS"] = str(notifications)

            result = run(
                "bash", str(isolated_task(tmp_path, "health")), "--format", "ndjson", "--notify", "--verbose", "--timeout", "12s", env=env, cwd=tmp_path
            )

            self.assertEqual(result.returncode, 1, result.stderr)
            expected = [
                ["run", f"kubernetes:{task}", "--", "--format", "ndjson", "--verbose", "--timeout", "12s"]
                for task in ("health-nodes", "health-kube-vip", "health-cilium", "health-pods", "health-deployments", "cnpg-health", "grafana-alerts")
            ]
            self.assertEqual([line.split("\t")[:-1] for line in calls.read_text().splitlines()], expected)
            self.assertEqual(
                notifications.read_text().split("\t")[:-1],
                ["--status", "failure", "--title", "Cluster health: action needed", "--message", "One or more cluster health checks failed; see task output for the affected report."],
            )

    def test_morning_check_preserves_optional_children_and_single_notification(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tmp_path = Path(directory)
            bin_dir = tmp_path / "bin"
            bin_dir.mkdir()
            (tmp_path / "scripts").mkdir()
            calls = tmp_path / "calls"
            notifications = tmp_path / "notifications"
            executable(
                bin_dir / "mise",
                "#!/usr/bin/env bash\n"
                "printf '%s\\t' \"$@\" >> \"$CALLS\"\n"
                "printf '\\n' >> \"$CALLS\"\n"
                "case \"$2\" in kubernetes:cnpg-backups) exit 19 ;; esac\n",
            )
            executable(bin_dir / "task", "#!/usr/bin/env bash\nexit 99\n")
            executable(
                tmp_path / "scripts/notify",
                "#!/usr/bin/env bash\n"
                "printf '%s\\t' \"$@\" > \"$NOTIFICATIONS\"\n"
                "printf '\\n' >> \"$NOTIFICATIONS\"\n",
            )
            env = os.environ.copy()
            env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
            env["CALLS"] = str(calls)
            env["NOTIFICATIONS"] = str(notifications)

            result = run(
                "bash", str(isolated_task(tmp_path, "morning-check")), "--format", "ndjson", "--notify", "--no-edge-smoke", "--log-noise", "--period", "6h", "--top", "4", env=env, cwd=tmp_path
            )

            self.assertEqual(result.returncode, 1, result.stderr)
            expected = [
                ["run", f"kubernetes:{task}", "--", "--format", "ndjson", "--period", "6h", "--top", "4"]
                for task in ("health", "gitops-health", "external-secrets-health", "service-account-health", "cnpg-backups", "log-noise")
            ]
            self.assertEqual([line.split("\t")[:-1] for line in calls.read_text().splitlines()], expected)
            self.assertTrue(notifications.exists())

    def test_health_translates_legacy_task_variables_and_preserves_literal_arguments(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tmp_path = Path(directory)
            bin_dir = tmp_path / "bin"
            bin_dir.mkdir()
            calls = tmp_path / "calls"
            executable(
                bin_dir / "mise",
                "#!/usr/bin/env bash\n"
                "printf '%s\\t' \"$@\" >> \"$CALLS\"\n"
                "printf '\\n' >> \"$CALLS\"\n",
            )
            env = os.environ.copy()
            env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
            env["CALLS"] = str(calls)

            result = run(
                "bash",
                str(isolated_task(tmp_path, "health")),
                "format=ndjson",
                "notify=true",
                "verbose=true",
                "raw=true",
                "timeout=12",
                "--literal-flag",
                env=env,
                cwd=tmp_path,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            expected = [
                ["run", f"kubernetes:{task}", "--", "--format", "ndjson", "--verbose", "--raw", "--timeout", "12s", "--literal-flag"]
                for task in ("health-nodes", "health-kube-vip", "health-cilium", "health-pods", "health-deployments", "cnpg-health", "grafana-alerts")
            ]
            self.assertEqual([line.split("\t")[:-1] for line in calls.read_text().splitlines()], expected)

    def test_morning_check_translates_legacy_task_variables_and_preserves_literal_arguments(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tmp_path = Path(directory)
            bin_dir = tmp_path / "bin"
            bin_dir.mkdir()
            calls = tmp_path / "calls"
            executable(
                bin_dir / "mise",
                "#!/usr/bin/env bash\n"
                "printf '%s\\t' \"$@\" >> \"$CALLS\"\n"
                "printf '\\n' >> \"$CALLS\"\n",
            )
            env = os.environ.copy()
            env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
            env["CALLS"] = str(calls)

            result = run(
                "bash",
                str(isolated_task(tmp_path, "morning-check")),
                "format=ndjson",
                "notify=true",
                "verbose=true",
                "raw=true",
                "timeout=12",
                "edge_smoke=false",
                "log_noise=true",
                "skip_http3=true",
                "period=6h",
                "top=4",
                "--literal-flag",
                env=env,
                cwd=tmp_path,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            expected = [
                ["run", f"kubernetes:{task}", "--", "--format", "ndjson", "--verbose", "--raw", "--timeout", "12s", "--skip-http3", "--period", "6h", "--top", "4", "--literal-flag"]
                for task in ("health", "gitops-health", "external-secrets-health", "service-account-health", "cnpg-backups", "log-noise")
            ]
            self.assertEqual([line.split("\t")[:-1] for line in calls.read_text().splitlines()], expected)

    def test_notifier_failure_does_not_replace_composite_failure_status(self) -> None:
        for task, failed_child in (("health", "health-cilium"), ("morning-check", "cnpg-backups")):
            with self.subTest(task=task), tempfile.TemporaryDirectory() as directory:
                tmp_path = Path(directory)
                bin_dir = tmp_path / "bin"
                bin_dir.mkdir()
                (tmp_path / "scripts").mkdir()
                notifications = tmp_path / "notifications"
                executable(
                    bin_dir / "mise",
                    "#!/usr/bin/env bash\n"
                    f"case \"$2\" in kubernetes:{failed_child}) exit 19 ;; esac\n",
                )
                executable(
                    tmp_path / "scripts/notify",
                    "#!/usr/bin/env bash\n"
                    "printf '%s\\n' \"$*\" > \"$NOTIFICATIONS\"\n"
                    "exit 57\n",
                )
                env = os.environ.copy()
                env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
                env["NOTIFICATIONS"] = str(notifications)

                result = run("bash", str(isolated_task(tmp_path, task)), "--notify", env=env, cwd=tmp_path)

                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertTrue(notifications.exists())

    def test_health_empty_legacy_variables_keep_task_defaults(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tmp_path = Path(directory)
            bin_dir = tmp_path / "bin"
            bin_dir.mkdir()
            calls = tmp_path / "calls"
            executable(
                bin_dir / "mise",
                "#!/usr/bin/env bash\n"
                "printf '%s\\t' \"$@\" >> \"$CALLS\"\n"
                "printf '\\n' >> \"$CALLS\"\n",
            )
            env = os.environ.copy()
            env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
            env["CALLS"] = str(calls)

            result = run(
                "bash",
                str(isolated_task(tmp_path, "health")),
                "format=",
                "notify=",
                "verbose=",
                "raw=",
                "timeout=",
                "period=",
                "top=",
                "skip_http3=",
                "include_esphome_canary=",
                "esphome_ws_path=",
                "esphome_ws_contains=",
                "json=",
                "workers=",
                "--literal-flag",
                env=env,
                cwd=tmp_path,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            expected = [
                ["run", f"kubernetes:{task}", "--", "--format", "text", "--timeout", "45s", "--period", "1h", "--top", "20", "--literal-flag"]
                for task in ("health-nodes", "health-kube-vip", "health-cilium", "health-pods", "health-deployments", "cnpg-health", "grafana-alerts")
            ]
            self.assertEqual([line.split("\t")[:-1] for line in calls.read_text().splitlines()], expected)

    def test_morning_check_empty_legacy_variables_keep_task_defaults(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tmp_path = Path(directory)
            bin_dir = tmp_path / "bin"
            bin_dir.mkdir()
            calls = tmp_path / "calls"
            executable(
                bin_dir / "mise",
                "#!/usr/bin/env bash\n"
                "printf '%s\\t' \"$@\" >> \"$CALLS\"\n"
                "printf '\\n' >> \"$CALLS\"\n",
            )
            env = os.environ.copy()
            env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
            env["CALLS"] = str(calls)

            result = run(
                "bash",
                str(isolated_task(tmp_path, "morning-check")),
                "format=",
                "notify=",
                "verbose=",
                "raw=",
                "timeout=",
                "edge_smoke=",
                "log_noise=",
                "skip_http3=",
                "period=",
                "top=",
                "include_esphome_canary=",
                "esphome_ws_path=",
                "esphome_ws_contains=",
                "json=",
                "workers=",
                "--literal-flag",
                env=env,
                cwd=tmp_path,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            expected = [
                ["run", f"kubernetes:{task}", "--", "--format", "text", "--timeout", "45s", "--period", "1h", "--top", "20", "--literal-flag"]
                for task in ("health", "gitops-health", "external-secrets-health", "service-account-health", "cnpg-backups", "edge-smoke")
            ]
            self.assertEqual([line.split("\t")[:-1] for line in calls.read_text().splitlines()], expected)
