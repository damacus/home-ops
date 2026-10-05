"""Protect the ESPHome route without breaking mDNS-dependent devices."""
import unittest
from pathlib import Path
import yaml
ROOT=Path(__file__).resolve().parents[1]
APP=ROOT/"kubernetes/apps/home-automation/esphome/app"
class EspHomeDashboardAuthTests(unittest.TestCase):
    def test_route_requires_existing_zitadel_middleware(self):
        route=yaml.safe_load((APP/"httproute-traefik.yaml").read_text())
        for rule in route["spec"]["rules"]:
            self.assertTrue(any(f.get("extensionRef",{}).get("name")=="oauth2-proxy-forward-auth" for f in rule.get("filters",[])))
    def test_direct_load_balancer_is_removed_and_mdns_preserved(self):
        values=yaml.safe_load((APP/"HelmRelease.yaml").read_text())["spec"]["values"]
        service=values["service"]["app"]
        self.assertEqual(service["type"],"ClusterIP")
        self.assertNotIn("lbipam.cilium.io/ips",service.get("annotations",{}))
        self.assertIs(values["controllers"]["esphome"]["pod"]["hostNetwork"],True)
    def test_route_waits_for_authentication_dependency(self):
        config=yaml.safe_load((APP.parent/"ks.yaml").read_text())
        self.assertIn({"name":"oauth2-proxy"},config["spec"]["dependsOn"])
if __name__=="__main__": unittest.main()
