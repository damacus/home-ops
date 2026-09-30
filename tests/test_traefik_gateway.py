"""Protect HTTP routing from unavailable experimental Gateway API watches."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]


class TraefikGatewayTest(unittest.TestCase):
    def test_http_gateway_does_not_require_experimental_apis(self) -> None:
        manifest = ROOT / "kubernetes/apps/network/traefik/app/HelmRelease.yaml"
        release = json.loads(
            subprocess.check_output(["yq", "-o=json", str(manifest)], text=True)
        )
        provider = release["spec"]["values"]["providers"]["kubernetesGateway"]
        self.assertTrue(provider["enabled"])
        self.assertFalse(
            provider.get("experimentalChannel", False),
            "Unavailable alpha route APIs prevent HTTP routes and TLS certificates loading",
        )


if __name__ == "__main__":
    unittest.main()
