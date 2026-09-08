import json
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "kubernetes/apps/dev"


def documents(path):
    result = subprocess.run(["ruby", "-ryaml", "-rjson", "-e",
        "puts JSON.generate(YAML.load_stream(File.read(ARGV[0])))", str(BASE / path)],
        check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


class CincRegistryConfigTests(unittest.TestCase):
    def test_runtime_and_gateway_cannot_mount_migration_credentials(self):
        hr = documents("cinc-registry/app/helmrelease.yaml")[0]
        controllers = hr["spec"]["values"]["controllers"]
        for name, controller in controllers.items():
            for container in controller["containers"].values():
                refs = container.get("envFrom", [])
                self.assertNotIn("cinc-registry-migrate", json.dumps(refs))
                if name == "gateway":
                    self.assertFalse(any("secretRef" in ref for ref in refs))
        self.assertEqual(set(controllers), {"api", "worker", "gateway"})

    def test_zot_is_internal_authenticated_and_s3_backed(self):
        secret = documents("zot/app/externalsecret.yaml")[0]
        config = secret["spec"]["target"]["template"]["data"]["config.json"]
        self.assertIn("bearer", config)
        self.assertIn("cinc-registry", config)
        self.assertIn("rustfs.storage.svc.cluster.local", config)
        self.assertNotIn("signing_key", config)
        hr = documents("zot/app/helmrelease.yaml")[0]
        self.assertNotIn("route", hr["spec"]["values"])
        self.assertNotIn("ingress", hr["spec"]["values"])
        self.assertEqual(hr["spec"]["values"]["service"]["main"]["type"], "ClusterIP")

    def test_bootstrap_precedes_app_and_import_does_not_retry(self):
        ks = documents("cinc-registry/ks.yaml")
        by_name = {d["metadata"]["name"]: d for d in ks}
        self.assertIn({"name": "cinc-registry-bootstrap"}, by_name["cinc-registry"]["spec"]["dependsOn"])
        job = documents("cinc-registry/import/job.yaml")[0]
        self.assertEqual(job["spec"]["backoffLimit"], 0)
        self.assertNotIn("ttlSecondsAfterFinished", job["spec"])
        self.assertEqual(job["spec"]["template"]["spec"]["containers"][0]["args"], ["sync-upstream"])
        self.assertFalse(list((BASE / "cinc-registry").rglob("*cronjob*")))

    def test_migration_can_validate_config_without_artifact_credentials(self):
        job = documents("cinc-registry/bootstrap/job.yaml")[0]
        pod = job["spec"]["template"]["spec"]
        migration = pod["initContainers"][0]
        env = {e["name"]: e["value"] for e in migration["env"]}
        self.assertEqual(env["CINC_SM_ARTIFACT_STORE_ENABLED"], "false")
        self.assertNotIn("cinc-registry-runtime", json.dumps(migration))
        self.assertNotIn("cinc-registry-migrate", json.dumps(pod["containers"]))

    def test_bucket_provisioning_is_limited_to_cinc(self):
        job = documents("../storage/cinc-registry-buckets/app/job.yaml")[0]
        command = job["spec"]["template"]["spec"]["containers"][0]["command"]
        self.assertEqual(command[-1], "cinc-registry")
        script = documents("../storage/rustfs-iam/app/bootstrap-script.yaml")[0]["data"]["bootstrap.sh"]
        scope = script.split('if [ "$scope" = "cinc-registry" ]; then')[1].split("exit 0")[0]
        self.assertEqual(scope.count("provision_single_bucket_identity"), 3)
        self.assertNotIn("remove_stale_policy_users", scope)
        for bucket in ["cinc-registry-oci", "cinc-registry-artifacts", "cnpg-cinc-registry"]:
            self.assertIn('"' + bucket + '"', scope)

    def test_database_has_distinct_unprivileged_runtime_role_and_backups(self):
        cluster = documents("cinc-registry-db/app/cluster.yaml")[0]["spec"]
        self.assertEqual(cluster["instances"], 2)
        self.assertIn(":18@sha256:", cluster["imageName"])
        runtime = cluster["managed"]["roles"][0]
        self.assertEqual(runtime["name"], "cinc_sm_runtime")
        self.assertFalse(runtime["superuser"])
        self.assertNotIn("inRoles", runtime)
        self.assertTrue(cluster["plugins"][0]["isWALArchiver"])


if __name__ == "__main__":
    unittest.main()
