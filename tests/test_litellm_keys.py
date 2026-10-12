"""Behavioural checks for credential-safe, repeatable key provisioning."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import MagicMock, patch
from urllib.error import HTTPError

spec = importlib.util.spec_from_file_location("litellm_keys", Path(__file__).parents[1] / "scripts/litellm_keys.py")
assert spec and spec.loader
keys = importlib.util.module_from_spec(spec)
spec.loader.exec_module(keys)


class KeyProvisioningTest(unittest.TestCase):
    def setUp(self) -> None:
        self.policy = {"key_alias": "frigate", "models": ["home-generation"], "max_budget": 10,
                       "budget_duration": "1mo", "object_permission": {"mcp_servers": []}}

    @patch.object(keys, "request")
    def test_missing_key_is_created_with_budget_and_no_mcp(self, request: MagicMock) -> None:
        request.side_effect = [HTTPError("", 404, "missing", {}, None), {}]
        self.assertEqual(keys.reconcile("https://gateway", "sk-master", "sk-client", self.policy), "created")
        self.assertEqual(request.call_args.args[3], "/key/generate")
        self.assertEqual(request.call_args.args[4], {**self.policy, "key": "sk-client"})
        self.assertNotIn("sk-client", request.call_args_list[0].args[3])

    @patch.object(keys, "request", return_value={})
    def test_existing_key_update_preserves_accrued_spend(self, request: MagicMock) -> None:
        self.assertEqual(keys.reconcile("https://gateway", "sk-master", "sk-client", self.policy), "updated")
        self.assertEqual(request.call_args.args[3], "/key/update")
        self.assertNotIn("spend", request.call_args.args[4])
        self.assertNotIn("budget_reset_at", request.call_args.args[4])

    @patch.object(keys, "request")
    def test_auth_or_server_failure_does_not_create_a_key(self, request: MagicMock) -> None:
        for code in [401, 403, 500]:
            request.reset_mock()
            request.side_effect = HTTPError("", code, "failed", {}, None)
            with self.assertRaises(HTTPError):
                keys.reconcile("https://gateway", "sk-master", "sk-client", self.policy)
            self.assertEqual(request.call_count, 1)


if __name__ == "__main__":
    unittest.main()
