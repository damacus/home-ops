"""Render the dashboard preparation and check activation and bypass boundaries."""
from pathlib import Path
import unittest
from test_ironbridge_deployment import render, DEV

class DashboardPreparationTest(unittest.TestCase):
    def test_disabled_default_and_optional_secrets(self) -> None:
        resources = render(DEV / "ironbridge/app")
        deployment = next(r for r in resources if r["kind"] == "Deployment")
        container = deployment["spec"]["template"]["spec"]["containers"][0]
        env = {e["name"]: e["value"] for e in container["env"]}
        self.assertEqual(env["DASHBOARD_ENABLED"], "false")
        self.assertEqual(env["MODERATION_SHADOW"], "true")
        self.assertEqual(env["MODERATION_NOTIFICATIONS_ENABLED"], "false")
        for name in ("ironbridge-dashboard", "ironbridge-moderation"):
            self.assertIn({"secretRef": {"name": name, "optional": True}}, container["envFrom"])
        self.assertEqual(container["image"].split("@sha256:")[1], "f44c083a4bb985ba0d0642fb33d8a7ce6378f0c0a9aaaba4cc9ceaec7e198ca7")
        self.assertEqual([r["metadata"]["name"] for r in resources if r["kind"] == "ExternalSecret"], ["ironbridge"])

    def test_tls_auth_and_no_direct_ingress(self) -> None:
        by_kind = {r["kind"]: r for r in render(DEV / "ironbridge/app")}
        service = by_kind["Service"]
        self.assertEqual(service["spec"].get("type", "ClusterIP"), "ClusterIP")
        self.assertEqual(service["spec"]["selector"], {"app": "ironbridge"})
        self.assertEqual(service["spec"]["ports"][0]["port"], 8080)
        route = by_kind["HTTPRoute"]["spec"]
        self.assertEqual(route["hostnames"], ["ironbridge.ironstone.casa"])
        self.assertEqual(route["parentRefs"], [{"name":"traefik-internal", "namespace":"network", "sectionName":"websecure"}])
        self.assertEqual(route["rules"][0]["filters"], [{"type":"ExtensionRef", "extensionRef":{"group":"traefik.io", "kind":"Middleware", "name":"ironbridge-forward-auth"}}])
        middleware = by_kind["Middleware"]["spec"]["forwardAuth"]
        self.assertIn("Authorization", middleware["authResponseHeaders"])
        policy = by_kind["NetworkPolicy"]["spec"]
        self.assertEqual(policy["podSelector"], {"matchLabels":{"app":"ironbridge"}})
        self.assertEqual(policy["policyTypes"], ["Ingress"])
        self.assertEqual(policy["ingress"], [{"from":[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"network"}}, "podSelector":{"matchLabels":{"app.kubernetes.io/name":"traefik"}}}], "ports":[{"port":8080,"protocol":"TCP"}]}])

    def test_optional_preparation_is_not_flux_managed(self) -> None:
        resources = render(DEV / "ironbridge/prepare-secrets")
        names = {r["metadata"]["name"] for r in resources}
        self.assertEqual(names, {"ironbridge-dashboard", "ironbridge-moderation"})
        dashboard = next(r for r in resources if r["metadata"]["name"] == "ironbridge-dashboard")
        keys = {d["secretKey"] for d in dashboard["spec"]["data"]}
        self.assertEqual(keys, {"DASHBOARD_OIDC_AUDIENCE", "DASHBOARD_JWKS_URL", "DASHBOARD_ADMIN_SUBJECT", "DASHBOARD_CSRF_SECRET"})
        audience = next(d for d in dashboard["spec"]["data"] if d["secretKey"] == "DASHBOARD_OIDC_AUDIENCE")
        self.assertEqual(audience["remoteRef"], {"key": "zitadel-oauth2-proxy-oidc", "property": "client_id"})
        self.assertNotIn("prepare-secrets", (DEV / "ironbridge/ks.yaml").read_text())
        northbot = next(r for r in render(DEV / "northbot/app") if r["kind"] == "Deployment")
        self.assertIn({"name":"PROACTIVE_ENABLED", "value":"true"}, northbot["spec"]["template"]["spec"]["containers"][0]["env"])

if __name__ == "__main__":
    unittest.main()
