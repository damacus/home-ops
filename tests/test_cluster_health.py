from __future__ import annotations

import importlib.util
import pathlib
import sys
import unittest


SCRIPT_PATH = pathlib.Path(__file__).resolve().parents[1] / "scripts" / "cluster-health.py"


def load_cluster_health():
    spec = importlib.util.spec_from_file_location("cluster_health", SCRIPT_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"unable to load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules["cluster_health"] = module
    spec.loader.exec_module(module)
    return module


class CnpgBackupsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.cluster_health = load_cluster_health()

    def test_hibernated_clusters_are_skipped(self) -> None:
        cluster = {
            "metadata": {
                "annotations": {"cnpg.io/hibernation": "on"},
                "name": "immich",
                "namespace": "home",
            },
            "status": {
                "conditions": [
                    {"type": "cnpg.io/hibernation", "status": "True"},
                ],
            },
        }
        backup = {
            "metadata": {
                "creationTimestamp": "2026-05-19T09:03:00Z",
                "namespace": "home",
            },
            "spec": {"cluster": {"name": "immich"}},
            "status": {
                "error": "cannot backup a hibernated cluster",
                "phase": "failed",
            },
        }

        result = self.run_cnpg_backups([backup], [cluster])

        self.assertEqual(result.status, "pass")
        self.assertEqual(result.summary, "all CNPG backups and WAL archiving healthy")
        self.assertEqual(result.details, ["home/immich: hibernated, backup/WAL check skipped"])

    def test_failed_backup_still_fails_for_active_cluster(self) -> None:
        cluster = {
            "metadata": {
                "annotations": {},
                "name": "app",
                "namespace": "default",
            },
            "status": {},
        }
        backup = {
            "metadata": {
                "creationTimestamp": "2026-05-19T09:03:00Z",
                "namespace": "default",
            },
            "spec": {"cluster": {"name": "app"}},
            "status": {
                "error": "backup failed",
                "phase": "failed",
            },
        }

        result = self.run_cnpg_backups([backup], [cluster])

        self.assertEqual(result.status, "fail")
        self.assertEqual(result.details, ["default/app: latest backup failed: backup failed", "default/app: no successful backup found"])

    def run_cnpg_backups(self, backups: list[dict], clusters: list[dict]):
        def kubectl_json(args: list[str]):
            if args == ["get", "backups.postgresql.cnpg.io", "-A"]:
                return {"items": backups}
            if args == ["get", "clusters.postgresql.cnpg.io", "-A"]:
                return {"items": clusters}
            raise AssertionError(f"unexpected kubectl args: {args}")

        def archive_status_from_cluster(namespace: str, name: str):
            return self.cluster_health.CheckResult("cnpg-wal", "pass", "WAL archiving checked", [])

        self.cluster_health.kubectl_json = kubectl_json
        self.cluster_health.archive_status_from_cluster = archive_status_from_cluster

        return self.cluster_health.cnpg_backups()


if __name__ == "__main__":
    unittest.main()
