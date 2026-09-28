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
    def test_flux_orders_database_before_disabled_bridge(self) -> None:
        dev = (DEV / "kustomization.yaml").read_text()
        self.assertIn("./northops-postgres/ks.yaml", dev)
        self.assertIn("./ironbridge/ks.yaml", dev)
        ks = json.loads(subprocess.run(
            ["yq", "-o=json", "-I=0", ".", str(DEV / "ironbridge/ks.yaml")],
            capture_output=True,
            text=True,
            check=True,
        ).stdout)
        self.assertEqual(ks["kind"], "Kustomization")
        self.assertIn(
            {"name": "northops-postgres"}, ks["spec"]["dependsOn"]
        )

    def test_shared_cluster_adds_isolated_ironbridge_database(self) -> None:
        resources = render(DEV / "northops-postgres/app")
        by_kind = {resource["kind"]: resource for resource in resources if resource["kind"] not in {"ExternalSecret", "Database"}}
        cluster = by_kind["Cluster"]
        self.assertEqual(cluster["metadata"]["name"], "northops-postgres")
        self.assertEqual(cluster["spec"]["instances"], 2)
        self.assertFalse(cluster["spec"]["enableSuperuserAccess"])
        initdb = cluster["spec"]["bootstrap"]["initdb"]
        self.assertEqual(initdb["database"], "northbot")
        self.assertEqual(initdb["owner"], "northbot_owner")
        roles = {role["name"]: role for role in cluster["spec"]["managed"]["roles"]}
        self.assertIn("northbot_runtime", roles)
        self.assertEqual(roles["ironbridge"]["passwordSecret"]["name"], "ironbridge-db")
        self.assertFalse(roles["ironbridge"]["superuser"])
        self.assertEqual(
            cluster["spec"]["postgresql"]["pg_hba"],
            ["hostssl ironbridge ironbridge all scram-sha-256", "host all ironbridge all reject"],
        )
        databases = {resource["metadata"]["name"]: resource for resource in resources if resource["kind"] == "Database"}
        self.assertEqual(databases["northbot"]["spec"]["owner"], "northbot_owner")
        self.assertEqual(databases["ironbridge"]["spec"]["owner"], "ironbridge")
        self.assertEqual(databases["ironbridge"]["spec"]["cluster"]["name"], "northops-postgres")
        self.assertEqual(cluster["spec"]["plugins"][0]["isWALArchiver"], True)
        self.assertEqual(by_kind["ObjectStore"]["spec"]["retentionPolicy"], "30d")
        backup = by_kind["ScheduledBackup"]["spec"]
        self.assertEqual(backup["method"], "plugin")
        self.assertEqual(backup["cluster"]["name"], "northops-postgres")
        secrets = {resource["metadata"]["name"] for resource in resources if resource["kind"] == "ExternalSecret"}
        self.assertIn("ironbridge-db", secrets)
        self.assertIn("rustfs-cnpg-northops-postgres", secrets)

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
        self.assertEqual(env["BRIDGE_DIRECTION"], "both")
        self.assertEqual(env["BRIDGE_SCOPE"], "all")
        self.assertNotIn("DATABASE_PATH", env)
        self.assertNotIn("PersistentVolumeClaim", by_kind)
        self.assertFalse(any("persistentVolumeClaim" in volume for volume in pod.get("volumes", [])))
        self.assertTrue(any(volume["name"] == "postgres-ca" for volume in pod["volumes"]))
        secret = by_kind["ExternalSecret"]
        self.assertIn("northops-postgres-rw.dev.svc.cluster.local", secret["spec"]["target"]["template"]["data"]["DATABASE_URL"])
        self.assertIn("sslmode=verify-full", secret["spec"]["target"]["template"]["data"]["DATABASE_URL"])
        self.assertIn("ExternalSecret", by_kind)


if __name__ == "__main__":
    unittest.main()
