import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
HELMRELEASE = (
    REPO_ROOT / "kubernetes/apps/authentication/zitadel/app/helmrelease.yaml"
)
ACCESS_POLICY = (
    REPO_ROOT / "kubernetes/apps/authentication/zitadel/app/access-policy.yaml"
)
ACCESS_POLICY_RECONCILER = (
    REPO_ROOT
    / "kubernetes/apps/authentication/zitadel/app/reconcile-access-policy.rb"
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


class ZitadelConfigTests(unittest.TestCase):
    def test_access_policy_is_complete_and_safe(self) -> None:
        policy = load_yaml(ACCESS_POLICY)

        subprocess.run(
            [
                "ruby",
                str(ACCESS_POLICY_RECONCILER),
                "--validate-policy",
                str(ACCESS_POLICY),
            ],
            check=True,
            capture_output=True,
            text=True,
        )

        with tempfile.TemporaryDirectory() as temp_dir:
            partial_policy = json.loads(json.dumps(policy))
            del partial_policy["loginPolicy"]["allowExternalIdp"]
            partial_path = Path(temp_dir) / "partial-policy.json"
            partial_path.write_text(json.dumps(partial_policy), encoding="utf-8")

            unsafe_policy = json.loads(json.dumps(policy))
            unsafe_policy["identityProviders"][0]["providerOptions"][
                "isAutoCreation"
            ] = True
            unsafe_path = Path(temp_dir) / "unsafe-policy.json"
            unsafe_path.write_text(json.dumps(unsafe_policy), encoding="utf-8")

            for invalid_path in (partial_path, unsafe_path):
                with self.subTest(policy=invalid_path.name):
                    validation = subprocess.run(
                        [
                            "ruby",
                            str(ACCESS_POLICY_RECONCILER),
                            "--validate-policy",
                            str(invalid_path),
                        ],
                        check=False,
                        capture_output=True,
                        text=True,
                    )
                    self.assertNotEqual(0, validation.returncode)

    def test_kubectl_hook_image_uses_available_arm64_tag(self) -> None:
        values = load_yaml(HELMRELEASE)["spec"]["values"]

        self.assertEqual("rancher/k3s", values["tools"]["kubectl"]["image"]["repository"])
        self.assertEqual(
            "v1.36.3-k3s1",
            values["tools"]["kubectl"]["image"]["tag"],
        )
        self.assertNotIn("setupJob", values)


if __name__ == "__main__":
    unittest.main()
