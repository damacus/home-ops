"""Keep Frigate browser authentication separate from trusted integrations."""
import unittest
from pathlib import Path
import yaml

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "kubernetes/apps/home-automation/frigate/app"

class FrigateBrowserAuthTests(unittest.TestCase):
    def test_browser_route_uses_authenticated_port(self):
        values = yaml.safe_load((APP / "HelmRelease.yaml").read_text())["spec"]["values"]
        self.assertEqual(values["service"]["app"]["ports"]["http"]["port"], 5000)
        self.assertEqual(values["service"]["app"]["ports"]["authenticated"]["port"], 8971)
        backends = values["route"]["app"]["rules"][0]["backendRefs"]
        self.assertEqual(backends, [{"kind": "Service", "name": "frigate", "port": 8971}])

    def test_auth_enabled_and_tls_terminated_by_traefik(self):
        config = yaml.safe_load((APP / "config.yml").read_text())
        self.assertIs(config["auth"]["enabled"], True)
        self.assertIs(config["tls"]["enabled"], False)

    def test_internal_access_is_limited_to_integrations_and_nodes(self):
        policy = yaml.safe_load((APP / "networkpolicy.yaml").read_text())
        self.assertEqual(policy["kind"], "CiliumNetworkPolicy")
        spec = policy["spec"]
        self.assertEqual(spec["endpointSelector"]["matchLabels"]["app.kubernetes.io/name"], "frigate")
        rules = spec["ingress"]
        self.assertEqual(len(rules), 3)
        self.assertEqual(rules[0]["fromEndpoints"], [{"matchLabels": {"k8s:io.kubernetes.pod.namespace": "network", "app.kubernetes.io/name": "traefik"}}])
        self.assertEqual(rules[0]["toPorts"][0]["ports"], [{"port": "8971", "protocol": "TCP"}])
        self.assertEqual(rules[1]["fromEndpoints"], [{"matchLabels": {"k8s:io.kubernetes.pod.namespace": "home-automation", "app.kubernetes.io/name": "home-assistant"}}])
        self.assertEqual(rules[2]["fromEntities"], ["host", "remote-node"])
        for rule in rules[1:]:
            self.assertEqual(rule["toPorts"][0]["ports"], [{"port": "5000", "protocol": "TCP"}, {"port": "8554", "protocol": "TCP"}])
            self.assertNotIn("fromCIDR", rule)
        self.assertNotIn("egress", spec)

    def test_policy_is_included_in_gitops(self):
        config = yaml.safe_load((APP / "kustomization.yaml").read_text())
        self.assertIn("./networkpolicy.yaml", config["resources"])

if __name__ == "__main__":
    unittest.main()
