from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import pathlib
import sys
import tempfile
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

    def test_validate_config_rejects_non_boolean_render_flag(self) -> None:
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
                    "render": "false",
                    "members": ["Kitchen lights"],
                }
            ],
        }

        with self.assertRaisesRegex(
            ValueError,
            "Downstairs lights render must be a boolean",
        ):
            module.validate_config(config)

    def test_validate_config_rejects_invalid_dashboard_energy_sensor_override(self) -> None:
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
                    "dashboard_energy_sensor_id": "binary_sensor.downstairs_lights",
                    "members": ["Kitchen lights"],
                }
            ],
        }

        with self.assertRaisesRegex(
            ValueError,
            "Downstairs lights dashboard_energy_sensor_id must be a sensor entity",
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

        self.assertEqual(
            rendered,
            "\n".join(
                [
                    "powercalc:",
                    "  create_utility_meters: true",
                    "  sensors:",
                    '    - create_group: "Downstairs lights"',
                    '      unique_id: "Downstairs lights"',
                    "      create_energy_sensor: true",
                    "      entities:",
                    '        - power_sensor_id: "sensor.kitchen_lights_power"',
                    '          energy_sensor_id: "sensor.kitchen_lights_energy"',
                    '        - power_sensor_id: "sensor.living_room_lights_power"',
                    '          energy_sensor_id: "sensor.living_room_lights_energy"',
                ]
            )
            + "\n",
        )

    def test_render_powercalc_package_creates_package_managed_room_group(self) -> None:
        module = load_module()
        config = {
            "room_groups": [
                {
                    "name": "Kitchen light fixtures",
                    "members": [
                        {
                            "power_sensor_id": "sensor.kitchen_spot_power",
                            "energy_sensor_id": "sensor.kitchen_spot_energy",
                        },
                        {
                            "power_sensor_id": "sensor.kitchen_strip_power",
                            "energy_sensor_id": "sensor.kitchen_strip_energy",
                        },
                    ],
                }
            ],
            "area_groups": [
                {
                    "name": "Downstairs light fixtures",
                    "dashboard": True,
                    "members": ["Kitchen light fixtures"],
                }
            ],
        }

        rendered = module.render_package(config)

        self.assertEqual(
            rendered,
            "\n".join(
                [
                    "powercalc:",
                    "  create_utility_meters: true",
                    "  sensors:",
                    '    - create_group: "Downstairs light fixtures"',
                    '      unique_id: "Downstairs light fixtures"',
                    "      create_energy_sensor: true",
                    "      entities:",
                    '        - create_group: "Kitchen light fixtures"',
                    '          unique_id: "Kitchen light fixtures"',
                    "          create_energy_sensor: true",
                    "          entities:",
                    '            - power_sensor_id: "sensor.kitchen_spot_power"',
                    '              energy_sensor_id: "sensor.kitchen_spot_energy"',
                    '            - power_sensor_id: "sensor.kitchen_strip_power"',
                    '              energy_sensor_id: "sensor.kitchen_strip_energy"',
                ]
            )
            + "\n",
        )

    def test_render_powercalc_package_escapes_yaml_string_scalars(self) -> None:
        module = load_module()
        config = {
            "room_groups": [
                {
                    "name": "Kitchen lights",
                    "power_sensor_id": 'sensor.kitchen_"lights"_power',
                    "energy_sensor_id": r"sensor.kitchen\lights_energy",
                }
            ],
            "area_groups": [
                {
                    "name": r'Downstairs "main" \ lights',
                    "dashboard": True,
                    "members": ["Kitchen lights"],
                }
            ],
        }

        rendered = module.render_package(config)

        self.assertEqual(
            rendered,
            "\n".join(
                [
                    "powercalc:",
                    "  create_utility_meters: true",
                    "  sensors:",
                    '    - create_group: "Downstairs \\"main\\" \\\\ lights"',
                    '      unique_id: "Downstairs \\"main\\" \\\\ lights"',
                    "      create_energy_sensor: true",
                    "      entities:",
                    '        - power_sensor_id: "sensor.kitchen_\\"lights\\"_power"',
                    '          energy_sensor_id: "sensor.kitchen\\\\lights_energy"',
                ]
            )
            + "\n",
        )

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

    def test_dashboard_energy_sensors_uses_explicit_energy_sensor_override(self) -> None:
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
                    "dashboard_energy_sensor_id": "sensor.downstairs_lights_energy_2",
                    "members": ["Kitchen lights"],
                },
            ],
        }

        sensors = module.dashboard_energy_sensors(config)

        self.assertEqual(sensors, ["sensor.downstairs_lights_energy_2"])

    def test_render_powercalc_package_skips_unmanaged_area_groups(self) -> None:
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
                    "name": "Existing downstairs lights",
                    "dashboard": True,
                    "render": False,
                    "members": ["Kitchen lights"],
                },
                {
                    "name": "Rendered upstairs lights",
                    "dashboard": True,
                    "members": ["Living room lights"],
                },
            ],
        }

        rendered = module.render_package(config)
        sensors = module.dashboard_energy_sensors(config)

        self.assertNotIn("Existing downstairs lights", rendered)
        self.assertIn('    - create_group: "Rendered upstairs lights"', rendered)
        self.assertEqual(
            sensors,
            [
                "sensor.existing_downstairs_lights_energy",
                "sensor.rendered_upstairs_lights_energy",
            ],
        )

    def test_dashboard_energy_sensors_matches_checked_in_group_config(self) -> None:
        module = load_module()
        config = module.load_json(CONFIG_PATH)

        sensors = module.dashboard_energy_sensors(config)

        self.assertEqual(
            sensors,
            [
                "sensor.downstairs_light_fixtures_energy",
                "sensor.upstairs_lights_energy",
                "sensor.outdoor_lights_energy",
                "sensor.loft_lights_energy",
            ],
        )

    def test_dashboard_energy_sensors_rejects_duplicate_dashboard_slugs(self) -> None:
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
                    "name": "Main lights",
                    "dashboard": True,
                    "members": ["Kitchen lights"],
                },
                {
                    "name": "Main-lights",
                    "dashboard": True,
                    "members": ["Living room lights"],
                },
            ],
        }

        with self.assertRaisesRegex(
            ValueError,
            "Duplicate dashboard energy sensor slug: main_lights",
        ):
            module.dashboard_energy_sensors(config)

    def test_dashboard_energy_sensors_rejects_empty_dashboard_slug(self) -> None:
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
                    "name": "!!!",
                    "dashboard": True,
                    "members": ["Kitchen lights"],
                },
            ],
        }

        with self.assertRaisesRegex(ValueError, "Dashboard energy sensor slug is empty"):
            module.dashboard_energy_sensors(config)

    def test_uncovered_lights_excludes_hue_rooms_and_powercalc_devices(self) -> None:
        module = load_module()
        entities = [
            {
                "entity_id": "light.kitchen",
                "platform": "hue",
                "device_id": "room-device",
                "disabled_by": None,
            },
            {
                "entity_id": "light.loft_ambiance",
                "platform": "hue",
                "device_id": "light-device",
                "disabled_by": None,
            },
            {
                "entity_id": "light.unity_light_2",
                "platform": "esphome",
                "device_id": "missing-device",
                "disabled_by": None,
            },
            {
                "entity_id": "sensor.loft_ambiance_power",
                "platform": "powercalc",
                "device_id": "light-device",
                "disabled_by": None,
            },
        ]
        devices = [
            {
                "id": "room-device",
                "name_by_user": None,
                "name": "Kitchen",
                "manufacturer": "Signify Netherlands B.V.",
                "model": "Room",
                "entry_type": "service",
            },
            {
                "id": "light-device",
                "name_by_user": None,
                "name": "Loft ambiance",
                "manufacturer": "Signify Netherlands B.V.",
                "model": "Hue ambiance lamp",
                "entry_type": None,
            },
            {
                "id": "missing-device",
                "name_by_user": "Unity Office",
                "name": "Unity",
                "manufacturer": "LoopOn",
                "model": "Unity",
                "entry_type": None,
            },
        ]

        uncovered = module.uncovered_lights(entities, devices)

        self.assertEqual(uncovered, ["light.unity_light_2\tUnity Office\tLoopOn\tUnity"])

    def test_uncovered_lights_from_registry_exports_extracts_data_lists(self) -> None:
        module = load_module()
        entity_registry = {
            "data": {
                "entities": [
                    {
                        "entity_id": "light.loft_ambiance",
                        "platform": "hue",
                        "device_id": "light-device",
                        "disabled_by": None,
                    },
                    {
                        "entity_id": "light.unity_light_2",
                        "platform": "esphome",
                        "device_id": "missing-device",
                        "disabled_by": None,
                    },
                    {
                        "entity_id": "sensor.loft_ambiance_power",
                        "platform": "powercalc",
                        "device_id": "light-device",
                        "disabled_by": None,
                    },
                ],
            },
        }
        device_registry = {
            "data": {
                "devices": [
                    {
                        "id": "light-device",
                        "name_by_user": None,
                        "name": "Loft ambiance",
                        "manufacturer": "Signify Netherlands B.V.",
                        "model": "Hue ambiance lamp",
                        "entry_type": None,
                    },
                    {
                        "id": "missing-device",
                        "name_by_user": "Unity Office",
                        "name": "Unity",
                        "manufacturer": "LoopOn",
                        "model": "Unity",
                        "entry_type": None,
                    },
                ],
            },
        }

        uncovered = module.uncovered_lights_from_registry_exports(entity_registry, device_registry)

        self.assertEqual(uncovered, ["light.unity_light_2\tUnity Office\tLoopOn\tUnity"])

    def test_main_prints_uncovered_light_report_from_registry_exports(self) -> None:
        module = load_module()
        entity_registry = {
            "data": {
                "entities": [
                    {
                        "entity_id": "light.unity_light_2",
                        "platform": "esphome",
                        "device_id": "missing-device",
                        "disabled_by": None,
                    },
                ],
            },
        }
        device_registry = {
            "data": {
                "devices": [
                    {
                        "id": "missing-device",
                        "name_by_user": "Unity Office",
                        "name": "Unity",
                        "manufacturer": "LoopOn",
                        "model": "Unity",
                        "entry_type": None,
                    },
                ],
            },
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            entity_path = pathlib.Path(temp_dir) / "core.entity_registry"
            device_path = pathlib.Path(temp_dir) / "core.device_registry"
            entity_path.write_text(json.dumps(entity_registry), encoding="utf-8")
            device_path.write_text(json.dumps(device_registry), encoding="utf-8")
            output = io.StringIO()

            with contextlib.redirect_stdout(output):
                exit_code = module.main([str(entity_path), str(device_path)])

        self.assertEqual(exit_code, 0)
        self.assertEqual(output.getvalue(), "light.unity_light_2\tUnity Office\tLoopOn\tUnity\n")


if __name__ == "__main__":
    unittest.main()
