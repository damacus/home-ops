import json
import subprocess
import unittest
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
HELMRELEASE = (
    REPO_ROOT
    / "kubernetes/apps/home-automation/paperless/app/helmrelease.yaml"
)
YAML_TO_JSON = (
    "puts JSON.generate(YAML.safe_load(File.read(ARGV.fetch(0)), aliases: false))"
)


def load_yaml(path: Path) -> dict[str, Any]:
    result = subprocess.run(
        ["ruby", "-ryaml", "-rjson", "-e", YAML_TO_JSON, str(path)],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


class PaperlessV3ConfigTests(unittest.TestCase):
    def test_v3_settings_preserve_v2_behaviour(self) -> None:
        environment = load_yaml(HELMRELEASE)["spec"]["values"]["controllers"][
            "paperless"
        ]["containers"]["app"]["env"]

        self.assertNotIn("PAPERLESS_CONSUMER_POLLING", environment)
        self.assertNotIn("PAPERLESS_DB_TIMEOUT", environment)
        self.assertEqual(
            "60",
            environment["PAPERLESS_CONSUMER_POLLING_INTERVAL"],
        )
        self.assertEqual("timeout=30", environment["PAPERLESS_DB_OPTIONS"])
        self.assertEqual(
            "true",
            environment["PAPERLESS_CONSUMER_DELETE_DUPLICATES"],
        )
        self.assertEqual(
            "always",
            environment["PAPERLESS_ARCHIVE_FILE_GENERATION"],
        )
        self.assertIn("PAPERLESS_SECRET_KEY", environment)


if __name__ == "__main__":
    unittest.main()
