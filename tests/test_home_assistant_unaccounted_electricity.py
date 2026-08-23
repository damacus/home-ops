from __future__ import annotations

import importlib.util
import pathlib
import sys
import unittest


SCRIPT_PATH = (
    pathlib.Path(__file__).resolve().parents[1]
    / "scripts"
    / "home_assistant_unaccounted_electricity.py"
)


def load_module():
    spec = importlib.util.spec_from_file_location(
        "home_assistant_unaccounted_electricity",
        SCRIPT_PATH,
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"unable to load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules["home_assistant_unaccounted_electricity"] = module
    spec.loader.exec_module(module)
    return module


class UnaccountedElectricityTest(unittest.TestCase):
    def test_percentile_interpolates_values(self) -> None:
        module = load_module()

        self.assertEqual(module.percentile([10.0, 20.0, 30.0], 0.25), 15.0)

    def test_energy_totals_subtract_accounted_devices(self) -> None:
        module = load_module()

        result = module.energy_totals(
            grid_start=100.0,
            grid_end=108.0,
            device_ranges={
                "sensor.rack": (10.0, 13.5),
                "sensor.fridge": (20.0, 21.5),
            },
        )

        self.assertEqual(result["whole_home_kwh"], 8.0)
        self.assertEqual(result["accounted_kwh"], 5.0)
        self.assertEqual(result["unaccounted_kwh"], 3.0)
        self.assertEqual(result["unaccounted_percent"], 37.5)

    def test_residual_points_use_latest_power_and_five_minute_median(self) -> None:
        module = load_module()
        demand = [
            (0.0, 100.0),
            (60.0, 110.0),
            (120.0, 120.0),
            (300.0, 150.0),
            (360.0, 160.0),
        ]
        power = {
            "sensor.device": [
                (-1.0, 40.0),
                (330.0, 50.0),
            ]
        }

        points = module.residual_points(demand, power)

        self.assertEqual(
            points,
            [
                {"timestamp": 0.0, "residual_w": 70.0},
                {"timestamp": 300.0, "residual_w": 110.0},
            ],
        )

    def test_sustained_spikes_require_two_consecutive_bins(self) -> None:
        module = load_module()
        points = [
            {"timestamp": 0.0, "residual_w": 70.0},
            {"timestamp": 300.0, "residual_w": 90.0},
            {"timestamp": 600.0, "residual_w": 91.0},
            {"timestamp": 900.0, "residual_w": 70.0},
            {"timestamp": 1200.0, "residual_w": 95.0},
        ]

        spikes = module.sustained_spikes(points, threshold_w=80.0)

        self.assertEqual(
            spikes,
            [
                {
                    "start_timestamp": 300.0,
                    "end_timestamp": 600.0,
                    "peak_w": 91.0,
                    "bins": 2,
                }
            ],
        )

    def test_summary_reports_base_and_average_unaccounted_power(self) -> None:
        module = load_module()
        totals = {
            "whole_home_kwh": 8.0,
            "accounted_kwh": 6.4,
            "unaccounted_kwh": 1.6,
            "unaccounted_percent": 20.0,
        }
        points = [
            {"timestamp": float(index * 300), "residual_w": value}
            for index, value in enumerate([50.0, 60.0, 70.0, 80.0])
        ]

        result = module.analysis_summary(
            totals,
            points,
            window_start=0.0,
            window_end=86_400.0,
        )

        self.assertEqual(result["average_unaccounted_w"], 66.7)
        self.assertEqual(result["base_w"], 53.0)
        self.assertEqual(result["median_w"], 65.0)
        self.assertEqual(result["max_5m_w"], 80.0)


if __name__ == "__main__":
    unittest.main()
