from __future__ import annotations

import importlib.util
import pathlib
import sys
import unittest


SCRIPT_PATH = pathlib.Path(__file__).resolve().parents[1] / "scripts" / "home_assistant_power_groups.py"


def load_module():
    spec = importlib.util.spec_from_file_location("home_assistant_power_groups", SCRIPT_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"unable to load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules["home_assistant_power_groups"] = module
    spec.loader.exec_module(module)
    return module


class PowerGroupConfigTest(unittest.TestCase):
    def test_module_loads(self) -> None:
        module = load_module()

        self.assertEqual(module.PACKAGE_HEADER, "powercalc:")


if __name__ == "__main__":
    unittest.main()
