"""Expose authenticated VMUI reads while keeping ingestion/admin internal."""
import unittest
import re
from pathlib import Path
import yaml
ROOT=Path(__file__).resolve().parents[1]
APP=ROOT/"kubernetes/apps/monitoring/victoria-metrics/app"
class MetricsUiAuthTests(unittest.TestCase):
    def test_browser_route_has_no_unrestricted_backend(self):
        route=yaml.safe_load((APP/"httproute.yaml").read_text())
        backend_rules=[r for r in route["spec"]["rules"] if "backendRefs" in r]
        self.assertTrue(backend_rules)
        allowed=set()
        for rule in backend_rules:
            filters=rule.get("filters",[])
            self.assertTrue(any(f.get("extensionRef",{}).get("name")=="oauth2-proxy-forward-auth" for f in filters))
            for match in rule["matches"]:
                allowed.add(match["path"]["value"])
                self.assertNotEqual(match["path"]["value"],"/")
        self.assertEqual(allowed, {"/vmui", "/api/v1/query", "/api/v1/query_range", "/api/v1/labels", "/api/v1/label", "/api/v1/series", "/api/v1/status/tsdb", "/api/v1/status/top_queries", "/api/v1/status/active_queries"})
    def test_backend_has_restricted_client_ingress(self):
        policy=yaml.safe_load((APP/"networkpolicy.yaml").read_text())
        rules=policy["spec"]["ingress"]
        self.assertEqual(policy["spec"]["endpointSelector"]["matchLabels"]["app.kubernetes.io/name"],"vmsingle")
        traefik=[r for r in rules if any(x.get("matchLabels",{}).get("app.kubernetes.io/name")=="traefik" for x in r.get("fromEndpoints",[]))]
        self.assertEqual(len(traefik),1)
        self.assertTrue(traefik[0]["toPorts"][0]["rules"]["http"])
        for r in rules:
            self.assertNotIn("fromEntities",r)
            self.assertEqual(r["toPorts"][0]["ports"],[{"port":"8428","protocol":"TCP"}])
    def test_traefik_cannot_reach_write_or_admin_endpoints(self):
        policy=yaml.safe_load((APP/"networkpolicy.yaml").read_text())
        rules=policy["spec"]["ingress"][-1]["toPorts"][0]["rules"]["http"]
        def allowed(method, path):
            return any(re.fullmatch(r["method"],method) and re.fullmatch(r["path"],path) for r in rules)
        for path in ("/vmui/", "/vmui/assets/main.js", "/api/v1/query", "/api/v1/query_range", "/api/v1/label/__name__/values"):
            self.assertTrue(allowed("GET",path),path)
        self.assertTrue(allowed("POST","/api/v1/query"))
        for path in ("/api/v1/write", "/api/v1/import", "/api/v1/admin/tsdb/delete_series", "/opentelemetry/api/v1/push", "/snapshot/create", "/flags", "/metrics"):
            for method in ("GET","POST","DELETE"):
                self.assertFalse(allowed(method,path),(method,path))
    def test_policy_is_included(self):
        k=yaml.safe_load((APP/"kustomization.yaml").read_text())
        self.assertIn("./networkpolicy.yaml",k["resources"])
if __name__=="__main__": unittest.main()
