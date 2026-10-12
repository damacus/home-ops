"""Opt-in behaviour tests against a disposable localhost gateway with mock models.

Never point this at production. Set LITELLM_TEST_URL and LITELLM_TEST_MASTER_KEY.
The fixture gateway must expose home-generation and home-embeddings aliases.
"""
from __future__ import annotations

import json
import os
import unittest
from typing import Any
from urllib.error import HTTPError
from urllib.parse import urlparse
from urllib.request import Request, urlopen
from uuid import uuid4


@unittest.skipUnless(os.environ.get("LITELLM_TEST_URL"), "requires disposable gateway")
class GatewayTest(unittest.TestCase):
    def setUp(self) -> None:
        self.url = os.environ["LITELLM_TEST_URL"]
        self.master = os.environ["LITELLM_TEST_MASTER_KEY"]
        if urlparse(self.url).hostname not in {"localhost", "127.0.0.1"}:
            self.fail("Tests may run only against localhost")
        self.keys: list[str] = []

    def call(self, path: str, key: str | None, body: dict | None = None) -> tuple[int, dict]:
        headers = {"Content-Type": "application/json"}
        if key:
            headers["Authorization"] = "Bearer " + key
        req = Request(self.url + path, headers=headers, data=json.dumps(body).encode() if body is not None else None)
        try:
            with urlopen(req, timeout=30) as response:
                return response.status, json.load(response)
        except HTTPError as error:
            with error:
                return error.code, json.load(error)

    def create(self, **policy: Any) -> str:
        key = "sk-verification-" + uuid4().hex
        code, _ = self.call("/key/generate", self.master, {"key": key, "key_alias": "verification-" + uuid4().hex,
            "models": ["home-generation"], "max_budget": 10, "budget_duration": "1mo",
            "object_permission": {"mcp_servers": []}, **policy})
        self.assertEqual(code, 200)
        self.keys.append(key)
        return key

    def completion(self, key: str | None, model: str = "home-generation") -> int:
        return self.call("/v1/chat/completions", key, {"model": model, "messages": [{"role": "user", "content": "Synthetic test"}]})[0]

    def tearDown(self) -> None:
        if self.keys:
            self.call("/key/delete", self.master, {"keys": self.keys})

    def test_auth_model_isolation_and_revocation(self) -> None:
        self.assertIn(self.completion(None), [401, 403])
        key = self.create()
        self.assertEqual(self.completion(key), 200)
        self.assertIn(self.completion(key, "home-embeddings"), [400, 401, 403])
        self.assertIn(self.call("/key/generate", key, {"models": ["gpt-5"]})[0], [400, 401, 403])
        self.assertEqual(self.call("/key/delete", self.master, {"keys": [key]})[0], 200)
        self.assertIn(self.completion(key), [401, 403])
        self.keys.remove(key)

    def test_exhausted_budget_stops_requests(self) -> None:
        key = self.create(spend=11)
        code, body = self.call("/v1/chat/completions", key, {"model": "home-generation", "messages": [{"role": "user", "content": "Synthetic test"}]})
        self.assertEqual(code, 422)
        self.assertIn("Budget has been exceeded", body["error"]["message"])

    def test_agent_key_cannot_infer(self) -> None:
        key = self.create(models=["__mcp_only__"])
        self.assertIn(self.completion(key), [400, 401, 403])

    def test_paperless_embedding_alias(self) -> None:
        key = self.create(models=["home-generation", "home-embeddings"])
        code, body = self.call("/v1/embeddings", key, {"model": "home-embeddings", "input": "Synthetic document"})
        self.assertEqual(code, 200)
        self.assertIsInstance(body["data"][0]["embedding"], list)

    def mcp(self, key: str, method: str, params: dict | None = None) -> tuple[int, dict]:
        req = Request(self.url + "/mcp", headers={"Authorization": "Bearer " + key,
            "Content-Type": "application/json", "Accept": "application/json, text/event-stream"},
            data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}).encode())
        try:
            with urlopen(req, timeout=30) as response:
                text = response.read().decode()
                if "text/event-stream" in response.headers.get("Content-Type", ""):
                    text = next(line[6:] for line in text.splitlines() if line.startswith("data: "))
                return response.status, json.loads(text)
        except HTTPError as error:
            with error:
                return error.code, json.load(error)

    @unittest.skipUnless(os.environ.get("LITELLM_TEST_MCP"), "requires synthetic HA and read-only Grafana fixtures")
    def test_mcp_grants_preserve_ha_writes_and_deny_app_access(self) -> None:
        app = self.create()
        code, body = self.mcp(app, "tools/list")
        if code == 200:
            self.assertEqual(body.get("result", {}).get("tools", []), [])
        else:
            self.assertIn(code, [401, 403])
        agent = self.create(models=["__mcp_only__"], object_permission={"mcp_servers": ["home_assistant", "grafana"]})
        code, body = self.mcp(agent, "tools/list")
        self.assertEqual(code, 200)
        tools = [tool["name"] for tool in body["result"]["tools"]]
        read = next(name for name in tools if name.endswith("get_state"))
        write = next(name for name in tools if name.endswith("set_state"))
        self.assertTrue(any("search_dashboards" in name for name in tools))
        self.assertFalse(any("update_dashboard" in name or "create_dashboard" in name for name in tools))
        self.assertEqual(self.mcp(agent, "tools/call", {"name": write, "arguments": {"value": "on"}})[0], 200)
        code, state = self.mcp(agent, "tools/call", {"name": read, "arguments": {}})
        self.assertEqual(code, 200)
        self.assertIn("on", json.dumps(state))
        code, denied = self.mcp(app, "tools/call", {"name": write, "arguments": {"value": "off"}})
        self.assertTrue(code in [401, 403] or "error" in denied or denied.get("result", {}).get("isError"))
        code, state = self.mcp(agent, "tools/call", {"name": read, "arguments": {}})
        self.assertIn("on", json.dumps(state))
        self.mcp(agent, "tools/call", {"name": write, "arguments": {"value": "off"}})
