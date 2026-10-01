"""Render dashboard activation and check secret and bypass boundaries."""
import unittest
from test_ironbridge_deployment import render, DEV

class DashboardActivationTest(unittest.TestCase):
    def test_enabled_dashboard_requires_secrets_and_keeps_shadow_mode(self) -> None:
        resources = render(DEV / "ironbridge/app")
        deployment = next(r for r in resources if r["kind"] == "Deployment")
        container = deployment["spec"]["template"]["spec"]["containers"][0]
        env = {e["name"]: e["value"] for e in container["env"]}
        self.assertEqual(env["DASHBOARD_ENABLED"], "true")
        self.assertEqual(env["MODERATION_SHADOW"], "true")
        self.assertEqual(env["MODERATION_NOTIFICATIONS_ENABLED"], "false")
        self.assertIn({"secretRef": {"name": "ironbridge-dashboard"}}, container["envFrom"])
        self.assertIn({"secretRef": {"name": "ironbridge-moderation", "optional": True}}, container["envFrom"])
        self.assertEqual(container["image"].split("@sha256:")[1], "c2d1342ba98da2610eb23e21422533484fb56b69ef9284a5c546c31581110a9c")
        self.assertEqual({r["metadata"]["name"] for r in resources if r["kind"] == "ExternalSecret"}, {"ironbridge", "ironbridge-dashboard", "ironbridge-moderation"})

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

    def test_dashboard_and_moderation_secrets_are_flux_managed(self) -> None:
        resources = render(DEV / "ironbridge/app")
        names = {r["metadata"]["name"] for r in resources if r["kind"] == "ExternalSecret"}
        self.assertEqual(names, {"ironbridge", "ironbridge-dashboard", "ironbridge-moderation"})
        self.assertFalse((DEV / "ironbridge/prepare-secrets").exists())
        self.assertNotIn("prepare-secrets", (DEV / "ironbridge/ks.yaml").read_text())
        northbot = next(r for r in render(DEV / "northbot/app") if r["kind"] == "Deployment")
        self.assertIn({"name":"PROACTIVE_ENABLED", "value":"true"}, northbot["spec"]["template"]["spec"]["containers"][0]["env"])

    def test_dashboard_credentials_use_reviewed_items(self) -> None:
        resources = render(DEV / "ironbridge/app")
        dashboard = next(r for r in resources if r["metadata"]["name"] == "ironbridge-dashboard")
        keys = {d["secretKey"] for d in dashboard["spec"]["data"]}
        self.assertEqual(keys, {"DASHBOARD_OIDC_AUDIENCE", "DASHBOARD_JWKS_URL", "DASHBOARD_ADMIN_SUBJECT", "DASHBOARD_CSRF_SECRET"})
        audience = next(d for d in dashboard["spec"]["data"] if d["secretKey"] == "DASHBOARD_OIDC_AUDIENCE")
        self.assertEqual(audience["remoteRef"], {"key": "zitadel-oauth2-proxy-oidc", "property": "client_id"})
        for field in ("DASHBOARD_JWKS_URL", "DASHBOARD_ADMIN_SUBJECT", "DASHBOARD_CSRF_SECRET"):
            entry = next(d for d in dashboard["spec"]["data"] if d["secretKey"] == field)
            self.assertEqual(entry["remoteRef"], {"key": "ironbridge-dashboard", "property": field})
        moderation = next(r for r in resources if r["metadata"]["name"] == "ironbridge-moderation")
        self.assertEqual(moderation["spec"]["data"], [{"secretKey": "JEV_API_KEY", "remoteRef": {"key": "JEV_API_KEY", "property": "credential"}}])

    def test_discord_administrator_uses_operational_secret(self) -> None:
        resources = render(DEV / "ironbridge/app")
        operational = next(r for r in resources if r["kind"] == "ExternalSecret" and r["metadata"]["name"] == "ironbridge")
        self.assertEqual(operational["spec"]["target"]["template"]["data"]["DISCORD_ADMIN_USER_ID"], "{{ .discord_admin_user_id }}")
        entry = next(d for d in operational["spec"]["data"] if d["secretKey"] == "discord_admin_user_id")
        self.assertEqual(entry["remoteRef"], {"key": "ironbridge", "property": "DISCORD_ADMIN_USER_ID"})

if __name__ == "__main__":
    unittest.main()
