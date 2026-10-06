"""Guard application reservations while preserving existing burst limits.

Budgets follow the October 2026 usage audit. Memory floors retain headroom
above the observed working set; limits must remain available for burst work.
"""
import json
import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def quantity(value: str | int) -> float:
    match = re.fullmatch(r"([\d.]+)([A-Za-z]*)", str(value))
    if match is None:
        raise ValueError(f"unsupported resource quantity: {value}")
    factors = {"": 1, "m": 0.001, "Ki": 1024, "Mi": 1024**2,
               "Gi": 1024**3, "K": 1000, "M": 1000**2, "G": 1000**3}
    return float(match[1]) * factors[match[2]]


class ApplicationRequestBudgetsTest(unittest.TestCase):
    def test_requests_fit_budgets_without_removing_burst_capacity(self) -> None:
        policies = json.loads((ROOT / "tests/fixtures/application-request-budgets.json").read_text())
        documents = {}
        for policy in policies:
            file = policy["file"]
            if file not in documents:
                documents[file] = json.loads(subprocess.check_output(
                    ["yq", "-o=json", ".", str(ROOT / file)], text=True))
            resources = documents[file]
            for part in policy["path"]:
                resources = resources[part]
            with self.subTest(file=file, path=policy["path"]):
                requests = resources["requests"]
                self.assertEqual(resources.get("limits", {}), policy["limits"])
                for resource, ceiling in policy["request_ceilings"].items():
                    self.assertGreater(quantity(requests[resource]), 0)
                    self.assertLessEqual(quantity(requests[resource]), quantity(ceiling))
                self.assertGreaterEqual(quantity(requests["memory"]),
                                        policy["memory_floor_mib"] * 1024**2)
                for resource, limit in resources.get("limits", {}).items():
                    if resource in requests:
                        self.assertLessEqual(quantity(requests[resource]), quantity(limit))


if __name__ == "__main__":
    unittest.main()
