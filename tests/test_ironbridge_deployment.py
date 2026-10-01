"""Check the active bidirectional IronBridge deployment and its safety constraints."""

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
    def test_flux_orders_database_before_bridge(self) -> None:
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

    def test_flux_readiness_requires_bridge_and_dashboard_secrets_only(self) -> None:
        ks = json.loads(subprocess.run(
            ["yq", "-o=json", "-I=0", ".", str(DEV / "ironbridge/ks.yaml")],
            capture_output=True, text=True, check=True,
        ).stdout)
        self.assertFalse(ks["spec"].get("wait", False), "wait=true ignores explicit healthChecks")
        checks = ks["spec"].get("healthChecks", [])
        self.assertEqual(len(checks), 3)
        self.assertEqual(
            {(c["apiVersion"], c["kind"], c["name"], c["namespace"]) for c in checks},
            {
                ("apps/v1", "Deployment", "ironbridge", "dev"),
                ("external-secrets.io/v1", "ExternalSecret", "ironbridge", "dev"),
                ("external-secrets.io/v1", "ExternalSecret", "ironbridge-dashboard", "dev"),
            },
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

    def test_bridge_rejects_known_gateway_failure_images(self) -> None:
        deployment = next(
            resource for resource in render(DEV / "ironbridge/app")
            if resource["kind"] == "Deployment"
        )
        image = deployment["spec"]["template"]["spec"]["containers"][0]["image"]
        # Published artifacts with observed gateway startup failures must not return.
        broken_digests = {
            "41215596876ab2f2545c4a851a83a98e9d97fdf3c707dd9911039e7f694a4c54",  # 0.1.3: TLS panic
            "5d63bd2d892a1b77fa820d2031a6c5e4c1cb60362fb17da170b1a2e43d04fc6e",  # 0.1.4: HTTP 400
        }
        self.assertNotIn(
            image.split("@sha256:")[-1], broken_digests,
            "do not redeploy an observed gateway startup failure",
        )

    def test_bridge_rejects_image_that_skips_undiscovered_threads(self) -> None:
        deployment = next(
            resource for resource in render(DEV / "ironbridge/app")
            if resource["kind"] == "Deployment"
        )
        image = deployment["spec"]["template"]["spec"]["containers"][0]["image"]
        self.assertNotEqual(
            image.split("@sha256:")[-1],
            "b2108f46a7b0fe491bc8f0dfb1b944893b1a1796c460f6aaada7e39830f9bfea",
            "0.1.5 skips Slack thread replies after the channel cursor passes their parent",
        )

    def test_bridge_rejects_image_that_drops_broadcast_replies(self) -> None:
        deployment = next(
            resource for resource in render(DEV / "ironbridge/app")
            if resource["kind"] == "Deployment"
        )
        image = deployment["spec"]["template"]["spec"]["containers"][0]["image"]
        self.assertNotEqual(
            image.split("@sha256:")[-1],
            "808bc7e1bed4f3ffadf388050f1f18ef96029c9254c461e2eb572a05c4ce8ec5",
            "0.1.7 silently discards Slack thread_broadcast replies",
        )

    def test_bridge_has_no_sqlite_volume_and_forwards_both_directions(self) -> None:
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
            readiness["exec"]["command"], ["/usr/local/bin/ironbridge", "ready"]
        )
        self.assertGreaterEqual(readiness["timeoutSeconds"], 10)
        digest = container["image"].split("@sha256:")[-1]
        self.assertRegex(digest, re.compile(r"^[0-9a-f]{64}$"))
        self.assertTrue(container["image"].startswith(
            "forgejo.ironstone.casa/damacus/ironbridge@sha256:"
        ))
        self.assertNotEqual(digest, "0" * 64, "active bridge needs a published image")
        env = {entry["name"]: entry["value"] for entry in container["env"]}
        self.assertEqual(env["BRIDGE_ENABLED"], "true")
        self.assertEqual(env["BRIDGE_DIRECTION"], "both")
        self.assertEqual(env["BRIDGE_SCOPE"], "all")
        self.assertNotIn("DATABASE_PATH", env)
        self.assertNotIn("PersistentVolumeClaim", by_kind)
        self.assertFalse(any("persistentVolumeClaim" in volume for volume in pod.get("volumes", [])))
        self.assertTrue(any(volume["name"] == "postgres-ca" for volume in pod["volumes"]))
        secret = next(resource for resource in resources if resource["kind"] == "ExternalSecret" and resource["metadata"]["name"] == "ironbridge")
        self.assertIn("northops-postgres-rw.dev.svc.cluster.local", secret["spec"]["target"]["template"]["data"]["DATABASE_URL"])
        self.assertIn("sslmode=verify-full", secret["spec"]["target"]["template"]["data"]["DATABASE_URL"])
        self.assertIn("ExternalSecret", by_kind)


if __name__ == "__main__":
    unittest.main()
