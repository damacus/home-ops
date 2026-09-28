"""Check the first IronBridge deployment cannot start bridging by accident."""

import json
from pathlib import Path
import re
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
DEV = ROOT / "kubernetes/apps/dev"


def render(path: Path) -> list[dict]:
    yaml = subprocess.run(
        ["kubectl", "kustomize", str(path)],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    documents = []
    for document in yaml.split("---\n"):
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
    return documents


class IronBridgeDeploymentTest(unittest.TestCase):
    def test_rustfs_bootstrap_creates_dedicated_backup_bucket_and_identity(self) -> None:
        script = (ROOT / "kubernetes/apps/storage/rustfs-iam/app/bootstrap-script.yaml").read_text()
        self.assertIn(
            'provision_single_bucket_identity "rustfs-cnpg-northops" '
            '"$RUSTFS_CNPG_NORTHOPS_ACCESS_KEY" '
            '"$RUSTFS_CNPG_NORTHOPS_SECRET_KEY" "cnpg-northops"',
            script,
        )
        credentials = (ROOT / "kubernetes/apps/storage/rustfs-iam/app/northops-externalsecret.yaml").read_text()
        self.assertIn("key: rustfs-cnpg-northops", credentials)
        job = (ROOT / "kubernetes/apps/storage/rustfs-iam/app/northops-job.yaml").read_text()
        self.assertIn("/scripts/bootstrap.sh, northops", job)
        db_ks = (DEV / "northops-pg/ks.yaml").read_text()
        self.assertIn("- name: rustfs-iam", db_ks)

    def test_flux_orders_database_before_disabled_bridge(self) -> None:
        dev = (DEV / "kustomization.yaml").read_text()
        self.assertIn("./northops-pg/ks.yaml", dev)
        self.assertIn("./ironbridge/ks.yaml", dev)
        ks = json.loads(subprocess.run(
            ["yq", "-o=json", "-I=0", ".", str(DEV / "ironbridge/ks.yaml")],
            capture_output=True,
            text=True,
            check=True,
        ).stdout)
        self.assertEqual(ks["kind"], "Kustomization")
        self.assertIn(
            {"name": "northops-pg"}, ks["spec"]["dependsOn"]
        )

    def test_database_is_private_and_backed_up(self) -> None:
        resources = render(DEV / "northops-pg/app")
        by_kind = {resource["kind"]: resource for resource in resources if resource["kind"] != "ExternalSecret"}
        cluster = by_kind["Cluster"]
        self.assertEqual(cluster["metadata"]["name"], "northops-pg")
        self.assertEqual(cluster["spec"]["instances"], 2)
        self.assertFalse(cluster["spec"]["enableSuperuserAccess"])
        initdb = cluster["spec"]["bootstrap"]["initdb"]
        self.assertEqual(initdb["database"], "ironbridge")
        self.assertEqual(initdb["owner"], "ironbridge")
        self.assertIn(
            "REVOKE CONNECT, TEMPORARY ON DATABASE postgres FROM PUBLIC",
            initdb["postInitSQL"],
        )
        self.assertIn(
            "REVOKE CONNECT, TEMPORARY ON DATABASE template1 FROM PUBLIC",
            initdb["postInitTemplateSQL"],
        )
        self.assertIn(
            "REVOKE CONNECT, TEMPORARY ON DATABASE ironbridge FROM PUBLIC",
            initdb["postInitApplicationSQL"],
        )
        self.assertEqual(cluster["spec"]["plugins"][0]["isWALArchiver"], True)
        self.assertEqual(by_kind["ObjectStore"]["spec"]["retentionPolicy"], "30d")
        backup = by_kind["ScheduledBackup"]["spec"]
        self.assertEqual(backup["method"], "plugin")
        self.assertTrue(backup["immediate"])
        self.assertEqual(backup["cluster"]["name"], "northops-pg")
        secrets = {resource["metadata"]["name"] for resource in resources if resource["kind"] == "ExternalSecret"}
        self.assertIn("ironbridge-db", secrets)
        self.assertIn("rustfs-cnpg-northops", secrets)

    def test_bridge_has_no_sqlite_volume_and_starts_disabled(self) -> None:
        resources = render(DEV / "ironbridge/app")
        by_kind = {resource["kind"]: resource for resource in resources}
        deployment = by_kind["Deployment"]
        self.assertEqual(deployment["spec"]["replicas"], 1)
        self.assertEqual(deployment["spec"]["strategy"]["type"], "Recreate")
        pod = deployment["spec"]["template"]["spec"]
        self.assertFalse(pod["automountServiceAccountToken"])
        self.assertTrue(pod["securityContext"]["runAsNonRoot"])
        container = pod["containers"][0]
        self.assertTrue(container["securityContext"]["readOnlyRootFilesystem"])
        self.assertEqual(container["securityContext"]["capabilities"]["drop"], ["ALL"])
        readiness = container["readinessProbe"]
        self.assertEqual(
            readiness["exec"]["command"], ["/usr/local/bin/ironbridge", "status"]
        )
        self.assertGreaterEqual(readiness["timeoutSeconds"], 10)
        digest = container["image"].split("@sha256:")[-1]
        self.assertRegex(digest, re.compile(r"^[0-9a-f]{64}$"))
        if digest == "0" * 64:
            ks = (DEV / "ironbridge/ks.yaml").read_text()
            self.assertIn("suspend: true", ks, "placeholder image must not reconcile")
        env = {entry["name"]: entry["value"] for entry in container["env"]}
        self.assertEqual(env["BRIDGE_ENABLED"], "false")
        self.assertEqual(env["BRIDGE_SCOPE"], "channels")
        self.assertNotIn("DATABASE_PATH", env)
        self.assertNotIn("PersistentVolumeClaim", by_kind)
        self.assertFalse(any("persistentVolumeClaim" in volume for volume in pod.get("volumes", [])))
        self.assertIn("ExternalSecret", by_kind)


if __name__ == "__main__":
    unittest.main()
