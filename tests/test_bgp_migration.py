"""Guard the separation between existing L2 services and opt-in BGP services."""

from __future__ import annotations

import ipaddress
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "kubernetes/apps/kube-system/cilium/config"
LABEL = "network.ironstone.casa/advertisement"


def selected(selector: dict, labels: dict[str, str]) -> bool:
    if any(labels.get(k) != v for k, v in selector.get("matchLabels", {}).items()):
        return False
    for expression in selector.get("matchExpressions", []):
        key, operator = expression["key"], expression["operator"]
        values = expression.get("values", [])
        if operator == "In" and labels.get(key) not in values:
            return False
        if operator == "NotIn" and labels.get(key) in values:
            return False
    return True


class BGPMigrationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        rendered = subprocess.check_output(["kubectl", "kustomize", str(CONFIG)], text=True)
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", encoding="utf-8") as manifest:
            manifest.write(rendered)
            manifest.flush()
            converted = subprocess.check_output(
                ["yq", "-o=json", "-I=0", ".", manifest.name], text=True
            )
        cls.resources = [json.loads(line) for line in converted.splitlines() if line.strip()]

    def resource(self, kind: str, name: str | None = None) -> dict:
        return next(r for r in self.resources if r["kind"] == kind and
                    (name is None or r["metadata"]["name"] == name))

    def test_existing_and_bgp_services_have_exclusive_pools_and_advertisements(self) -> None:
        bgp = self.resource("CiliumLoadBalancerIPPool", "lb-pool")["spec"]
        l2 = self.resource("CiliumLoadBalancerIPPool", "l2-pool")["spec"]
        announcement = self.resource("CiliumL2AnnouncementPolicy")["spec"]
        advert = self.resource("CiliumBGPAdvertisement")["spec"]["advertisements"][0]
        for labels, wants_bgp in [({}, False), ({"app": "mqtt"}, False), ({LABEL: "bgp"}, True)]:
            with self.subTest(labels=labels):
                self.assertEqual(selected(bgp.get("serviceSelector", {}), labels), wants_bgp)
                self.assertEqual(selected(advert["selector"], labels), wants_bgp)
                self.assertEqual(selected(l2.get("serviceSelector", {}), labels), not wants_bgp)
                self.assertEqual(selected(announcement.get("serviceSelector", {}), labels), not wants_bgp)

    def test_pool_excludes_gateway_and_ipv6(self) -> None:
        blocks = self.resource("CiliumLoadBalancerIPPool", "lb-pool")["spec"]["blocks"]
        self.assertEqual(blocks, [{"start": "192.168.3.2", "stop": "192.168.3.254"}])
        for block in blocks:
            self.assertEqual(ipaddress.ip_address(block["start"]).version, 4)

    def test_existing_services_request_unique_bgp_addresses(self) -> None:
        expected = {"esphome": 227, "mosquitto": 229, "wyoming-piper": 231,
                    "wyoming-whisper": 232, "matter-server": 234,
                    "wyoming-openwakeword": 235, "forgejo": 236, "traefik": 238}
        seen: set[str] = set()
        bgp = self.resource("CiliumLoadBalancerIPPool", "lb-pool")["spec"]["serviceSelector"]
        l2 = self.resource("CiliumL2AnnouncementPolicy")["spec"]["serviceSelector"]
        for path in (ROOT / "kubernetes/apps").rglob("*.yaml"):
            if (path.name.lower() != "helmrelease.yaml" or path.parent.parent.name not in
                    {"esphome", "mosquitto", "piper", "whisper", "matter", "wakeword", "forgejo", "traefik"}):
                continue
            hr = json.loads(subprocess.check_output(["yq", "-o=json", ".", str(path)], text=True))
            name = hr["metadata"]["name"]
            if name not in expected:
                continue
            with self.subTest(service=name):
                service = hr["spec"]["values"]["service"]
                if name != "traefik":
                    service = service["ssh" if name == "forgejo" else "app"]
                self.assertTrue(selected(bgp, service.get("labels", {})))
                self.assertFalse(selected(l2, service.get("labels", {})))
                self.assertEqual(service["annotations"]["lbipam.cilium.io/ips"],
                                 f"192.168.3.{expected[name]}")
                if name == "mosquitto":
                    self.assertEqual(
                        service["annotations"].get("external-dns.alpha.kubernetes.io/hostname"),
                        "mosquitto.ironstone.casa",
                    )
                self.assertNotIn("loadBalancerIP", service)
                self.assertNotIn("io.cilium/lb-ipam-ips", service["annotations"])
                seen.add(name)
        self.assertEqual(seen, set(expected))

    def test_peer_requires_authentication(self) -> None:
        spec = self.resource("CiliumBGPPeerConfig")["spec"]
        self.assertEqual(spec.get("authSecretRef"), "cilium-bgp-auth")

    def test_router_accepts_only_service_host_routes_and_exports_nothing(self) -> None:
        config = (ROOT / "scripts/unifi/bgp.cfg").read_text()
        self.assertIn("bgp listen range 192.168.1.0/24 peer-group home-kubernetes", config)
        self.assertIn("neighbor home-kubernetes password BGP_PASSWORD", config)
        self.assertIn("neighbor home-kubernetes prefix-list K3S-SERVICES in", config)
        self.assertIn("neighbor home-kubernetes prefix-list K3S-EXPORT out", config)
        self.assertIn("ip prefix-list K3S-SERVICES seq 5 deny 192.168.3.1/32", config)
        self.assertIn("ip prefix-list K3S-SERVICES seq 10 permit 192.168.3.0/24 ge 32 le 32", config)
        self.assertIn("ip prefix-list K3S-EXPORT seq 10 deny 0.0.0.0/0 le 32", config)
        self.assertNotIn("redistribute", config)


if __name__ == "__main__":
    unittest.main()
