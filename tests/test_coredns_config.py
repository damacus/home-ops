import json
import subprocess
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
KUSTOMIZATION = REPO_ROOT / "kubernetes/apps/kube-system/coredns/ks.yaml"
DEPLOYMENT = (
    REPO_ROOT / "kubernetes/apps/kube-system/coredns/app/deployment.yaml"
)


def load_yaml(path: Path) -> dict[str, object]:
    result = subprocess.run(
        ["yq", "-o=json", str(path)],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


class CoreDnsConfigTests(unittest.TestCase):
    def test_flux_owns_two_coredns_replicas(self) -> None:
        deployment = load_yaml(DEPLOYMENT)
        kustomization = load_yaml(KUSTOMIZATION)

        self.assertEqual(2, deployment["spec"]["replicas"])
        self.assertEqual(
            "Override",
            deployment["metadata"]["annotations"][
                "kustomize.toolkit.fluxcd.io/ssa"
            ],
        )
        self.assertNotIn("force", kustomization["spec"])


if __name__ == "__main__":
    unittest.main()
