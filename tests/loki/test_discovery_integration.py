"""Opt-in integration checks against an explicitly named disposable kind cluster.

Run with LOKI_TEST_KUBECONFIG and LOKI_CHARTS_PATH set. Never targets Ironstone.
"""
from collections.abc import Callable
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[2]
CONTEXT = "kind-loki-configmap-rules-test"

@unittest.skipUnless(os.environ.get("LOKI_TEST_KUBECONFIG"), "Requires disposable kind cluster")
class DiscoveryIntegrationTests(unittest.TestCase):
    def kubectl(self, *args: str, stdin: str | None = None) -> str:
        return subprocess.check_output(["kubectl", "--kubeconfig", os.environ["LOKI_TEST_KUBECONFIG"], "--context", CONTEXT, "--request-timeout=20s", *args], input=stdin, text=True, stderr=subprocess.STDOUT, timeout=120 if "wait" in args else 35)

    def apply(self, *docs: dict) -> None:
        self.kubectl("apply", "-f", "-", stdin=yaml.safe_dump_all(docs))

    def eventually(self, predicate: Callable[[], bool], message: str) -> None:
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            try:
                if predicate():
                    return
            except (subprocess.CalledProcessError, KeyError, AssertionError):
                pass
            time.sleep(2)
        self.fail(message)

    def rule_names(self) -> set[str]:
        result = json.loads(self.kubectl("get", "--raw", "/api/v1/namespaces/monitoring/services/http:loki:3100/proxy/prometheus/api/v1/rules"))
        rules = [r for g in result["data"]["groups"] for r in g["rules"]]
        self.assertTrue(all(r["health"] == "ok" for r in rules))
        return {r["name"] for r in rules}

    def files(self, namespace: str) -> str:
        return self.kubectl("-n", namespace, "exec", "loki", "-c", "inspect", "--", "sh", "-c", r"find /rules -type f -name '*.yaml' -exec cat {} \;")

    def test_discovery_collision_update_deletion_and_secret_denial(self) -> None:
        info = json.loads(self.kubectl("config", "view", "--minify", "-o", "json"))
        self.assertEqual(info["current-context"], CONTEXT)
        self.assertIn("127.0.0.1", info["clusters"][0]["cluster"]["server"])
        for namespace in ("monitoring", "openebs-system", "fixture-a", "fixture-b"):
            self.apply({"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": namespace}})
        config = {
            "auth_enabled": False,
            "server": {"http_listen_port": 3100},
            "common": {"instance_addr": "127.0.0.1", "path_prefix": "/tmp/loki", "storage": {"filesystem": {"chunks_directory": "/tmp/loki/chunks", "rules_directory": "/rules"}}, "replication_factor": 1, "ring": {"kvstore": {"store": "inmemory"}}},
            "schema_config": {"configs": [{"from": "2024-01-01", "store": "tsdb", "object_store": "filesystem", "schema": "v13", "index": {"prefix": "index_", "period": "24h"}}]},
            "ruler": {"storage": {"type": "local", "local": {"directory": "/rules"}}, "rule_path": "/tmp/loki/ruler", "alertmanager_url": "http://127.0.0.1:9093", "enable_api": True, "evaluation_interval": "1s", "poll_interval": "2s"},
        }
        for namespace, directory, chart in (("monitoring", "monitoring/loki", "loki"), ("openebs-system", "openebs-system/openebs", "openebs")):
            app = ROOT / "kubernetes/apps" / directory / "app"
            role = yaml.safe_load((app / "rule-discovery-rbac.yaml").read_text())
            self.apply(role)
            release = next(d for d in yaml.safe_load_all((app / "helmrelease.yaml").read_text()) if d["kind"] == "HelmRelease")
            with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml") as f:
                yaml.safe_dump(release["spec"]["values"], f); f.flush()
                docs = [d for d in yaml.safe_load_all(subprocess.check_output(["helm", "template", chart, str(Path(os.environ["LOKI_CHARTS_PATH"]) / chart), "-n", namespace, "-f", f.name], text=True)) if d]
            binding = next(d for d in docs if d["kind"] == "ClusterRoleBinding" and "loki" in d["metadata"]["name"])
            sa = binding["subjects"][0]["name"]
            self.apply({"apiVersion": "v1", "kind": "ServiceAccount", "metadata": {"name": sa, "namespace": namespace}}, binding)
            template = next(d["spec"]["template"]["spec"] for d in docs if d["kind"] == "StatefulSet" and any(c["name"] == "loki" for c in d["spec"]["template"]["spec"]["containers"]))
            sidecar = next(c for c in template["containers"] if c["name"] == "loki-sc-rules")
            if os.environ.get("LOKI_TEST_SIDECAR_IMAGE"):
                sidecar["image"] = os.environ["LOKI_TEST_SIDECAR_IMAGE"]
                sidecar["imagePullPolicy"] = "Never"
            sidecar["resources"] = {"requests": {"cpu": "10m", "memory": "32Mi"}, "limits": {"memory": "128Mi"}}
            mount = next(m for m in sidecar["volumeMounts"] if m["name"] == "sc-rules-volume")
            inspect = {"name": "inspect", "image": "busybox:1.37.0", "command": ["sh", "-c", "sleep 3600"], "volumeMounts": [mount]}
            containers = [sidecar, inspect]
            volumes = [{"name": "tmp", "emptyDir": {}}, {"name": "sc-rules-volume", "emptyDir": {}}]
            if namespace == "monitoring":
                self.apply({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "test-config", "namespace": namespace}, "data": {"config.yaml": yaml.safe_dump(config)}})
                volumes.append({"name": "config", "configMap": {"name": "test-config"}})
                containers.append({"name": "loki", "image": "grafana/loki:3.6.12", "args": ["-config.file=/etc/loki/config.yaml"], "ports": [{"containerPort": 3100}], "volumeMounts": [mount, {"name": "config", "mountPath": "/etc/loki"}, {"name": "tmp", "mountPath": "/tmp"}]})
                self.apply({"apiVersion": "v1", "kind": "Service", "metadata": {"name": "loki", "namespace": namespace}, "spec": {"selector": {"test": "loki"}, "ports": [{"name": "http", "port": 3100}]}})
            self.apply({"apiVersion": "v1", "kind": "Pod", "metadata": {"name": "loki", "namespace": namespace, "labels": {"test": "loki"}}, "spec": {"serviceAccountName": sa, "containers": containers, "volumes": volumes}})
            self.kubectl("-n", namespace, "wait", "--for=condition=Ready", "pod/loki", "--timeout=90s")
            for resource in ("configmaps", "secrets"):
                args = ["auth", "can-i", "list", resource, "--all-namespaces", "--as", "system:serviceaccount:" + namespace + ":" + sa]
                if resource == "configmaps":
                    self.assertEqual(self.kubectl(*args).strip(), "yes")
                else:
                    with self.assertRaises(subprocess.CalledProcessError) as denied:
                        self.kubectl(*args)
                    self.assertEqual(denied.exception.output.strip(), "no")
            with self.assertRaises(subprocess.CalledProcessError) as denied:
                self.kubectl("get", "secrets", "-n", "fixture-a", "--as", "system:serviceaccount:" + namespace + ":" + sa)
            self.assertIn("Forbidden", denied.exception.output)
        def fixture(namespace: str, alert: str) -> dict:
            rule = {"groups": [{"name": namespace, "rules": [{"alert": alert, "expr": 'sum(count_over_time({app="isolated-fixture"}[1m])) > 999', "labels": {"severity": "warning"}}]}]}
            return {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "shared", "namespace": namespace, "labels": {"loki_rule": "true"}}, "data": {"rules.yaml": yaml.safe_dump(rule)}}
        self.apply(fixture("fixture-a", "FixtureA"), fixture("fixture-b", "FixtureB"))
        self.apply({"apiVersion": "v1", "kind": "Secret", "metadata": {"name": "ignored", "namespace": "fixture-a", "labels": {"loki_rule": "true"}}, "stringData": {"ignored.yaml": "secret-fixture-must-not-be-discovered"}})
        for ns in ("monitoring", "openebs-system"):
            self.eventually(lambda: "FixtureA" in self.files(ns) and "FixtureB" in self.files(ns), "Cross-namespace collision-safe discovery failed: " + ns)
            self.assertNotIn("secret-fixture", self.files(ns))
        self.eventually(lambda: {"FixtureA", "FixtureB"} <= self.rule_names(), "Fixture rules not evaluated")
        self.apply(fixture("fixture-a", "FixtureAUpdated"))
        self.eventually(lambda: "FixtureAUpdated" in self.rule_names() and "FixtureA" not in self.rule_names(), "Update did not reload")
        self.kubectl("-n", "fixture-b", "delete", "configmap", "shared")
        self.eventually(lambda: "FixtureB" not in self.rule_names(), "Deletion did not reload")
        for ns in ("monitoring", "openebs-system"):
            self.eventually(lambda: "FixtureAUpdated" in self.files(ns) and "FixtureB" not in self.files(ns), "Update/deletion failed: " + ns)
        self.apply(yaml.safe_load((ROOT / "kubernetes/apps/monitoring/loki/app/rules.yaml").read_text()) | {"metadata": {"name": "loki-alert-rules", "namespace": "monitoring", "labels": {"loki_rule": "true"}}})
        expected = {"FrigateCameraRepeatedFailures", "IronBridgeDeliveryExhausted", "ApplicationStorageWriteFailure"}
        self.eventually(lambda: expected <= self.rule_names(), "Approved alerts not healthy in ruler")
        print("Both Rust watchers passed discovery, collisions, updates, deletion and Secret denial; all three Loki rules evaluate healthily.")

if __name__ == "__main__":
    unittest.main()
