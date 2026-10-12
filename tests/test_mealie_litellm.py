import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("mealie_litellm", Path(__file__).parents[1] / "scripts/mealie_litellm.py")
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ProviderMigrationTest(unittest.TestCase):
    def test_preserves_model_name_and_timeout(self) -> None:
        original = {"id": "existing", "name": "GPT-5", "model": "gpt-5", "timeout": 400,
                    "baseUrl": "https://api.openai.com/v1", "requestHeaders": {}, "requestParams": {}}
        update = module.provider_update(original, "sk-client", "http://gateway/v1")
        self.assertEqual(update["model"], original["model"])
        self.assertEqual(update["name"], original["name"])
        self.assertEqual(update["timeout"], 400)
        self.assertEqual(update["apiKey"], "sk-client")
        self.assertEqual(original["baseUrl"], "https://api.openai.com/v1")

    def test_unreviewed_model_or_custom_auth_stops_cutover(self) -> None:
        for provider in [{"model": "unknown"}, {"model": "gpt-5", "requestHeaders": {"Authorization": "secret"}}]:
            with self.assertRaises(ValueError):
                module.provider_update(provider, "sk-client", "http://gateway/v1")
