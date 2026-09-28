"""Check NorthBot's fresh PostgreSQL deployment in Flux."""

from pathlib import Path
import json
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "kubernetes/apps/dev/northbot/app"
DATABASE = ROOT / "kubernetes/apps/dev/northops-postgres/app"


class NorthBotDeploymentTest(unittest.TestCase):
    @staticmethod
    def resource_list(path: Path = APP) -> list[dict]:
        rendered = subprocess.run(
            ["kubectl", "kustomize", str(path)],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
        documents = []
        for document in rendered.split("---\n"):
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

    @classmethod
    def resources(cls, path: Path = APP) -> dict[str, dict]:
        return {resource["kind"]: resource for resource in cls.resource_list(path)}

    def test_northbot_is_discovered_by_flux(self) -> None:
        dev = (ROOT / "kubernetes/apps/dev/kustomization.yaml").read_text()
        self.assertIn("./northbot/ks.yaml", dev)
        rendered = subprocess.run(["kubectl", "kustomize", str(APP)], capture_output=True, text=True, check=True).stdout
        for expected in (
            "kind: Deployment",
            "replicas: 1",
            "forgejo.ironstone.casa/damacus/northbot:main",
            "imagePullPolicy: Always",
            "kind: ExternalSecret",
            "kind: CronJob",
            "kind: Role",
            "automountServiceAccountToken: false",
        ):
            with self.subTest(expected=expected):
                self.assertIn(expected, rendered)

    def test_postgres_setup_separates_owner_and_runtime_credentials(self) -> None:
        pod = self.resources()["Deployment"]["spec"]["template"]["spec"]
        self.assertEqual(pod["initContainers"][0]["command"], ["/northbot", "migrate"])
        self.assertEqual(pod["initContainers"][0]["env"][0]["valueFrom"]["secretKeyRef"]["name"], "northops-postgres-owner")
        self.assertEqual(pod["containers"][0]["env"][0]["valueFrom"]["secretKeyRef"]["name"], "northops-postgres-runtime")
        self.assertFalse(any(env["name"] == "DATABASE_PATH" for env in pod["containers"][0]["env"]))
        self.assertFalse(any(volume.get("persistentVolumeClaim") for volume in pod["volumes"]))
        self.assertNotIn("PersistentVolumeClaim", self.resources())
        self.assertEqual(pod["volumes"][0]["secret"]["secretName"], "northops-postgres-ca")
        self.assertEqual(pod["volumes"][0]["secret"]["items"][0]["key"], "ca.crt")

    def test_database_and_backup_are_discovered_before_northbot(self) -> None:
        dev = (ROOT / "kubernetes/apps/dev/kustomization.yaml").read_text()
        self.assertIn("./northops-postgres/ks.yaml", dev)
        northbot_flux = (ROOT / "kubernetes/apps/dev/northbot/ks.yaml").read_text()
        self.assertIn("- name: northops-postgres", northbot_flux)
        resources = self.resources(DATABASE)
        cluster = resources["Cluster"]["spec"]
        self.assertEqual(cluster["imageCatalogRef"]["major"], 18)
        self.assertEqual(cluster["instances"], 2)
        self.assertEqual(cluster["bootstrap"]["initdb"]["owner"], "northbot_owner")
        self.assertEqual(cluster["managed"]["roles"][0]["name"], "northbot_runtime")
        self.assertFalse(cluster["managed"]["roles"][0]["superuser"])
        self.assertEqual(resources["Database"]["spec"]["owner"], "northbot_owner")
        self.assertEqual(resources["ObjectStore"]["spec"]["retentionPolicy"], "30d")
        self.assertEqual(resources["ScheduledBackup"]["spec"]["method"], "plugin")
        credentials = {
            resource["metadata"]["name"]: resource
            for resource in self.resource_list(DATABASE)
            if resource["kind"] == "ExternalSecret"
        }
        for name in ("northops-postgres-owner", "northops-postgres-runtime"):
            self.assertEqual(credentials[name]["spec"]["target"]["template"]["type"], "kubernetes.io/basic-auth")

    def test_backup_bucket_is_provisioned_before_database(self) -> None:
        storage = (ROOT / "kubernetes/apps/storage/kustomization.yaml").read_text()
        self.assertIn("./northops-postgres-buckets/ks.yaml", storage)
        bucket_flux = (ROOT / "kubernetes/apps/storage/northops-postgres-buckets/ks.yaml").read_text()
        self.assertIn("- name: rustfs-iam", bucket_flux)
        database_flux = (ROOT / "kubernetes/apps/dev/northops-postgres/ks.yaml").read_text()
        self.assertIn("- name: northops-postgres-buckets", database_flux)
        bucket_app = ROOT / "kubernetes/apps/storage/northops-postgres-buckets/app"
        resources = self.resources(bucket_app)
        job = resources["Job"]["spec"]["template"]["spec"]["containers"][0]
        self.assertEqual(job["command"], ["/bin/sh", "/scripts/bootstrap.sh", "northops-postgres"])
        self.assertIn("rustfs-northops-postgres", [ref["secretRef"]["name"] for ref in job["envFrom"]])
        secret = resources["ExternalSecret"]["spec"]
        self.assertEqual(secret["data"][0]["remoteRef"]["key"], "rustfs-cnpg-northops-postgres")
        script = self.resources(ROOT / "kubernetes/apps/storage/rustfs-iam/app")["ConfigMap"]["data"]["bootstrap.sh"]
        self.assertIn('provision_single_bucket_identity "rustfs-cnpg-northops-postgres"', script)
        self.assertIn('"cnpg-northops-postgres"', script)

    def test_secret_changes_and_daily_job_restart_the_deployment(self) -> None:
        resources = self.resources()
        deployment = resources["Deployment"]
        self.assertEqual(
            deployment["metadata"]["annotations"]["reloader.stakater.com/auto"],
            "true",
        )
        job = resources["CronJob"]["spec"]["jobTemplate"]["spec"]["template"]["spec"]
        self.assertEqual(job["serviceAccountName"], "northbot-refresh")
        self.assertEqual(
            job["containers"][0]["command"],
            ["kubectl", "-n", "dev", "rollout", "restart", "deployment/northbot"],
        )
        role = resources["Role"]["rules"][0]
        self.assertEqual(role["resourceNames"], ["northbot"])
        self.assertEqual(set(role["verbs"]), {"get", "patch"})
        self.assertEqual(resources["RoleBinding"]["subjects"][0]["name"], "northbot-refresh")
