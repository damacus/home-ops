import json
import subprocess
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
KUSTOMIZATION = REPO_ROOT / "kubernetes/apps/kube-system/coredns/ks.yaml"
AUTOSCALER = (
    REPO_ROOT / "kubernetes/apps/kube-system/coredns/app/autoscaler.yaml"
)
DISRUPTION_BUDGET = (
    REPO_ROOT
    / "kubernetes/apps/kube-system/coredns/app/poddisruptionbudget.yaml"
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
    def test_autoscaler_maintains_two_coredns_replicas(self) -> None:
        autoscaler = load_yaml(AUTOSCALER)
        kustomization = load_yaml(KUSTOMIZATION)

        self.assertEqual("HorizontalPodAutoscaler", autoscaler["kind"])
        self.assertEqual("coredns", autoscaler["spec"]["scaleTargetRef"]["name"])
        self.assertEqual(2, autoscaler["spec"]["minReplicas"])
        self.assertGreaterEqual(autoscaler["spec"]["maxReplicas"], 2)
        self.assertNotIn("force", kustomization["spec"])

    def test_disruption_budget_keeps_one_coredns_available(self) -> None:
        disruption_budget = load_yaml(DISRUPTION_BUDGET)

        self.assertEqual(
            1,
            disruption_budget["spec"]["minAvailable"],
        )
        self.assertEqual(
            "kube-dns",
            disruption_budget["spec"]["selector"]["matchLabels"]["k8s-app"],
        )


if __name__ == "__main__":
    unittest.main()
