from __future__ import annotations

import importlib.util
import pathlib
import sys
import unittest


SCRIPT_PATH = pathlib.Path(__file__).resolve().parents[1] / "scripts" / "home_assistant_power_groups.py"
CONFIG_PATH = (
    pathlib.Path(__file__).resolve().parents[1]
    / "docs"
    / "home-assistant"
    / "power"
    / "powercalc-groups.json"
)


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

    def test_validate_config_accepts_known_room_members(self) -> None:
        module = load_module()
        config = {
            "room_groups": [
                {
                    "name": "Kitchen lights",
                    "power_sensor_id": "sensor.kitchen_lights_power",
                    "energy_sensor_id": "sensor.kitchen_lights_energy",
                }
            ],
            "area_groups": [
                {
                    "name": "Downstairs lights",
                    "dashboard": True,
                    "members": ["Kitchen lights"],
                }
            ],
        }

        module.validate_config(config)

    def test_validate_config_accepts_checked_in_group_config(self) -> None:
        module = load_module()
        config = module.load_json(CONFIG_PATH)

        module.validate_config(config)

    def test_validate_config_rejects_unknown_area_member(self) -> None:
        module = load_module()
        config = {
            "room_groups": [
                {
                    "name": "Kitchen lights",
                    "power_sensor_id": "sensor.kitchen_lights_power",
                    "energy_sensor_id": "sensor.kitchen_lights_energy",
                }
            ],
            "area_groups": [
                {
                    "name": "Downstairs lights",
                    "dashboard": True,
                    "members": ["Missing room"],
                }
            ],
        }

        with self.assertRaisesRegex(ValueError, "Unknown room group"):
            module.validate_config(config)

    def test_validate_config_rejects_duplicate_dashboard_member(self) -> None:
        module = load_module()
        config = {
            "room_groups": [
                {
                    "name": "Kitchen lights",
                    "power_sensor_id": "sensor.kitchen_lights_power",
                    "energy_sensor_id": "sensor.kitchen_lights_energy",
                }
            ],
            "area_groups": [
                {
                    "name": "Downstairs lights",
                    "dashboard": True,
                    "members": ["Kitchen lights"],
                },
                {
                    "name": "Also downstairs lights",
                    "dashboard": True,
                    "members": ["Kitchen lights"],
                },
            ],
        }

        with self.assertRaisesRegex(ValueError, "Dashboard double count"):
            module.validate_config(config)

    def test_validate_config_rejects_non_boolean_dashboard_flag(self) -> None:
        module = load_module()
        config = {
            "room_groups": [
                {
                    "name": "Kitchen lights",
                    "power_sensor_id": "sensor.kitchen_lights_power",
                    "energy_sensor_id": "sensor.kitchen_lights_energy",
                }
            ],
            "area_groups": [
                {
                    "name": "Downstairs lights",
                    "dashboard": "true",
                    "members": ["Kitchen lights"],
                }
            ],
        }

        with self.assertRaisesRegex(
            ValueError,
            "Downstairs lights dashboard must be a boolean",
        ):
            module.validate_config(config)

    def test_validate_config_rejects_invalid_area_member_type(self) -> None:
        module = load_module()
        config = {
            "room_groups": [
                {
                    "name": "Kitchen lights",
                    "power_sensor_id": "sensor.kitchen_lights_power",
                    "energy_sensor_id": "sensor.kitchen_lights_energy",
                }
            ],
            "area_groups": [
                {
                    "name": "Downstairs lights",
                    "dashboard": True,
                    "members": [""],
                }
            ],
        }

        with self.assertRaisesRegex(
            ValueError,
            "Downstairs lights members must contain non-empty strings",
        ):
            module.validate_config(config)

    def test_render_powercalc_package_creates_nested_area_group(self) -> None:
        module = load_module()
        config = {
            "room_groups": [
                {
                    "name": "Kitchen lights",
                    "power_sensor_id": "sensor.kitchen_lights_power",
                    "energy_sensor_id": "sensor.kitchen_lights_energy",
                },
                {
                    "name": "Living room lights",
                    "power_sensor_id": "sensor.living_room_lights_power",
                    "energy_sensor_id": "sensor.living_room_lights_energy",
                },
            ],
            "area_groups": [
                {
                    "name": "Downstairs lights",
                    "dashboard": True,
                    "members": ["Kitchen lights", "Living room lights"],
                }
            ],
        }

        rendered = module.render_package(config)

        self.assertIn("powercalc:\n", rendered)
        self.assertIn("  create_utility_meters: true\n", rendered)
        self.assertIn("    - create_group: Downstairs lights\n", rendered)
        self.assertIn("        - power_sensor_id: sensor.kitchen_lights_power\n", rendered)
        self.assertIn("          energy_sensor_id: sensor.kitchen_lights_energy\n", rendered)
        self.assertTrue(rendered.endswith("\n"))

    def test_dashboard_energy_sensors_returns_only_area_groups(self) -> None:
        module = load_module()
        config = {
            "room_groups": [
                {
                    "name": "Kitchen lights",
                    "power_sensor_id": "sensor.kitchen_lights_power",
                    "energy_sensor_id": "sensor.kitchen_lights_energy",
                }
            ],
            "area_groups": [
                {
                    "name": "Downstairs lights",
                    "dashboard": True,
                    "members": ["Kitchen lights"],
                },
                {
                    "name": "Reference lights",
                    "dashboard": False,
                    "members": ["Kitchen lights"],
                },
            ],
        }

        sensors = module.dashboard_energy_sensors(config)

        self.assertEqual(sensors, ["sensor.downstairs_lights_energy"])


if __name__ == "__main__":
    unittest.main()
