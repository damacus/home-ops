import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("mealie_litellm", Path(__file__).parents[1] / "scripts/mealie_litellm.py")
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ProviderMigrationTest(unittest.TestCase):
    def test_maps_legacy_models_to_v6(self) -> None:
        original = {"id": "existing", "name": "GPT-5", "model": "gpt-5", "timeout": 400,
                    "baseUrl": "https://api.openai.com/v1", "requestHeaders": {}, "requestParams": {}}
        update = module.provider_update(original, "sk-client", "http://gateway/v1")
        self.assertEqual(update["model"], "gpt-6.1-terra")

    def test_maps_whisper_to_current_transcription_model(self) -> None:
        original = {"id": "existing", "name": "Whisper", "model": "whisper-1", "timeout": 400,
                    "baseUrl": "https://api.openai.com/v1", "requestHeaders": {}, "requestParams": {}}
        update = module.provider_update(original, "sk-client", "http://gateway/v1")
        self.assertEqual(update["model"], "gpt-4o-mini-transcribe")

    def test_preserves_unmapped_model_name_and_timeout(self) -> None:
        original = {"id": "existing", "name": "Future", "model": "future-openai-model", "timeout": 400,
                    "baseUrl": "https://api.openai.com/v1", "requestHeaders": {}, "requestParams": {}}
        update = module.provider_update(original, "sk-client", "http://gateway/v1")
        self.assertEqual(update["model"], "future-openai-model")
        self.assertEqual(update["name"], original["name"])
        self.assertEqual(update["timeout"], 400)
        self.assertEqual(update["apiKey"], "sk-client")
        self.assertEqual(original["baseUrl"], "https://api.openai.com/v1")

    def test_custom_auth_stops_cutover(self) -> None:
        for provider in [{"model": "gpt-5", "requestHeaders": {"Authorization": "secret"}}]:
            with self.assertRaises(ValueError):
                module.provider_update(provider, "sk-client", "http://gateway/v1")
