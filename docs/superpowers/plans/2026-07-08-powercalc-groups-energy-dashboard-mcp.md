# PowerCalc Groups and Assist MCP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a repeatable Home Assistant power-insight workflow that groups individual PowerCalc light/device sensors into room groups, rolls those room groups into area groups for the Energy Dashboard, and exposes the resulting read-only sensors through the Home Assistant MCP Server.

**Architecture:** Treat Home Assistant's entity/device registries as read-only inputs, keep the desired grouping hierarchy in source control, and render a Home Assistant package that PowerCalc can load from `/config/packages/powercalc_groups.yaml`. The Energy Dashboard and Assist/MCP exposure remain UI/API-managed because `.storage/energy` and `.storage/homeassistant.exposed_entities` are not stable public configuration interfaces.

**Tech Stack:** Home Assistant 2026.7.1, PowerCalc v1.21.2, Kubernetes `kubectl exec` against the `home-automation` namespace, Python stdlib `unittest`, Home Assistant packages, Home Assistant MCP Server `/api/mcp`.

---

## Current State

- Home Assistant runs in Kubernetes as `home-assistant-0` in namespace `home-automation`.
- The HA config PVC is mounted at `/config` in both `home-assistant-0` and the `code` pod.
- `/config/configuration.yaml` currently does not enable `homeassistant.packages`.
- PowerCalc is installed and currently managed mostly through config entries and storage, not YAML.
- The live HA instance already has an `mcp_server` config entry named `Assist` with `data.llm_hass_api == ["assist"]`.
- The Assist exposure store currently exposes no useful power entities to Assist; it only contains `sun.sun`, `zone.home`, and `conversation.home_assistant`, all with `should_expose: false`.
- Existing group sensors include `sensor.kitchen_lights_energy`, `sensor.living_room_lights_energy`, `sensor.hall_lights_energy`, `sensor.main_bedroom_energy`, `sensor.garden_lights_energy`, `sensor.porch_energy`, and `sensor.downstairs_lights_energy`.

## Desired Grouping Rules

- Leaf sensors are individual PowerCalc or physical metering sensors:
  - Example: `sensor.loft_ambiance_power` and `sensor.loft_ambiance_energy`.
  - Example: `sensor.kitchen_spot_left_2_power` and `sensor.kitchen_spot_left_2_energy`.
- Room groups aggregate leaf sensors for one room:
  - Example: `sensor.kitchen_lights_power` and `sensor.kitchen_lights_energy`.
- Area groups aggregate room groups or one-room leaf groups:
  - Example: `sensor.downstairs_lights_power` and `sensor.downstairs_lights_energy` include kitchen, living room, hall, and downstairs toilet light groups.
  - Example: `sensor.loft_lights_power` and `sensor.loft_lights_energy` can include the loft light directly when there is no separate room layer.
- The Energy Dashboard should include only the top-level area energy sensors as individual devices. Do not add both `sensor.kitchen_lights_energy` and `sensor.downstairs_lights_energy` to Energy Dashboard, because that double-counts the same consumption.
- The MCP/Assist exposure should expose only read-only power and energy sensors at first. Do not expose `light.*`, `switch.*`, `cover.*`, locks, garage doors, or climate controls while the goal is insight rather than control.

## File Structure

- Create `docs/home-assistant/power/powercalc-groups.json`
  - Source-of-truth grouping hierarchy.
  - Uses JSON so scripts/tests can parse it with Python stdlib only.
- Create `scripts/home_assistant_power_groups.py`
  - Reads `powercalc-groups.json`.
  - Renders `/config/packages/powercalc_groups.yaml`.
  - Produces a coverage report from HA registry exports.
  - Validates duplicate dashboard membership before any live config is applied.
- Create `tests/test_home_assistant_power_groups.py`
  - Unit tests for group validation, package rendering, and uncovered-light reporting.
- Create `docs/home-assistant/power/README.md`
  - Operator notes for applying the generated package and adding Energy Dashboard devices.
- Create `docs/home-assistant/assist-mcp.md`
  - Operator notes for fixing Home Assistant MCP access and Assist exposure.
- Modify live file `/config/configuration.yaml`
  - Add `packages: !include_dir_named packages` under the existing `homeassistant:` block.
  - This file is on the HA PVC, not in the repository.
- Create live file `/config/packages/powercalc_groups.yaml`
  - Rendered package consumed by Home Assistant.

## Task 1: Add the Power Group Tool Skeleton

**Files:**
- Create: `scripts/home_assistant_power_groups.py`
- Test: `tests/test_home_assistant_power_groups.py`

- [ ] **Step 1: Write the failing import test**

Create `tests/test_home_assistant_power_groups.py` with this content:

```python
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
python -m unittest tests/test_home_assistant_power_groups.py
```

Expected: FAIL with `FileNotFoundError` for `scripts/home_assistant_power_groups.py`.

- [ ] **Step 3: Create the minimal script**

Create `scripts/home_assistant_power_groups.py` with this content:

```python
from __future__ import annotations

PACKAGE_HEADER = "powercalc:"
```

- [ ] **Step 4: Run the test to verify it passes**

Run:

```bash
python -m unittest tests/test_home_assistant_power_groups.py
```

Expected: PASS with `Ran 1 test`.

- [ ] **Step 5: Commit**

```bash
git add scripts/home_assistant_power_groups.py tests/test_home_assistant_power_groups.py
git commit -m "test: start home assistant power group tooling"
```

## Task 2: Define and Validate the Group Source of Truth

**Files:**
- Create: `docs/home-assistant/power/powercalc-groups.json`
- Modify: `scripts/home_assistant_power_groups.py`
- Modify: `tests/test_home_assistant_power_groups.py`

- [ ] **Step 1: Create the initial group config**

Create `docs/home-assistant/power/powercalc-groups.json` with this content:

```json
{
  "room_groups": [
    {
      "name": "Kitchen lights",
      "power_sensor_id": "sensor.kitchen_lights_power",
      "energy_sensor_id": "sensor.kitchen_lights_energy"
    },
    {
      "name": "Living room lights",
      "power_sensor_id": "sensor.living_room_lights_power",
      "energy_sensor_id": "sensor.living_room_lights_energy"
    },
    {
      "name": "Hall lights",
      "power_sensor_id": "sensor.hall_lights_power",
      "energy_sensor_id": "sensor.hall_lights_energy"
    },
    {
      "name": "Main bedroom lights",
      "power_sensor_id": "sensor.main_bedroom_power",
      "energy_sensor_id": "sensor.main_bedroom_energy"
    },
    {
      "name": "Garden lights",
      "power_sensor_id": "sensor.garden_lights_power",
      "energy_sensor_id": "sensor.garden_lights_energy"
    },
    {
      "name": "Porch lights",
      "power_sensor_id": "sensor.porch_power",
      "energy_sensor_id": "sensor.porch_energy"
    },
    {
      "name": "Loft lights",
      "power_sensor_id": "sensor.loft_ambiance_power",
      "energy_sensor_id": "sensor.loft_ambiance_energy"
    }
  ],
  "area_groups": [
    {
      "name": "Downstairs lights",
      "dashboard": true,
      "members": [
        "Kitchen lights",
        "Living room lights",
        "Hall lights"
      ]
    },
    {
      "name": "Main bedroom lights area",
      "dashboard": true,
      "members": [
        "Main bedroom lights"
      ]
    },
    {
      "name": "Outdoor lights",
      "dashboard": true,
      "members": [
        "Garden lights",
        "Porch lights"
      ]
    },
    {
      "name": "Loft lights area",
      "dashboard": true,
      "members": [
        "Loft lights"
      ]
    }
  ]
}
```

- [ ] **Step 2: Add failing validation tests**

Append these tests to `PowerGroupConfigTest` in `tests/test_home_assistant_power_groups.py`:

```python
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
```

- [ ] **Step 3: Run tests to verify they fail**

Run:

```bash
python -m unittest tests/test_home_assistant_power_groups.py
```

Expected: FAIL with `AttributeError: module 'home_assistant_power_groups' has no attribute 'validate_config'`.

- [ ] **Step 4: Implement validation**

Replace `scripts/home_assistant_power_groups.py` with this content:

```python
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

PACKAGE_HEADER = "powercalc:"


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return data


def validate_config(config: dict[str, Any]) -> None:
    room_groups = config.get("room_groups")
    area_groups = config.get("area_groups")
    if not isinstance(room_groups, list):
        raise ValueError("room_groups must be a list")
    if not isinstance(area_groups, list):
        raise ValueError("area_groups must be a list")

    room_names: set[str] = set()
    for room in room_groups:
        if not isinstance(room, dict):
            raise ValueError("room group entries must be objects")
        name = room.get("name")
        power_sensor_id = room.get("power_sensor_id")
        energy_sensor_id = room.get("energy_sensor_id")
        if not isinstance(name, str) or not name:
            raise ValueError("room group name must be a non-empty string")
        if name in room_names:
            raise ValueError(f"Duplicate room group: {name}")
        if not isinstance(power_sensor_id, str) or not power_sensor_id.startswith("sensor."):
            raise ValueError(f"{name} power_sensor_id must be a sensor entity")
        if not isinstance(energy_sensor_id, str) or not energy_sensor_id.startswith("sensor."):
            raise ValueError(f"{name} energy_sensor_id must be a sensor entity")
        room_names.add(name)

    dashboard_members: dict[str, str] = {}
    for area in area_groups:
        if not isinstance(area, dict):
            raise ValueError("area group entries must be objects")
        area_name = area.get("name")
        members = area.get("members")
        dashboard = area.get("dashboard", False)
        if not isinstance(area_name, str) or not area_name:
            raise ValueError("area group name must be a non-empty string")
        if not isinstance(members, list) or not members:
            raise ValueError(f"{area_name} members must be a non-empty list")
        for member in members:
            if member not in room_names:
                raise ValueError(f"Unknown room group {member!r} in area {area_name!r}")
            if dashboard is True and member in dashboard_members:
                other = dashboard_members[member]
                raise ValueError(f"Dashboard double count: {member!r} is in {other!r} and {area_name!r}")
            if dashboard is True:
                dashboard_members[member] = area_name
```

- [ ] **Step 5: Run tests to verify they pass**

Run:

```bash
python -m unittest tests/test_home_assistant_power_groups.py
```

Expected: PASS with `Ran 4 tests`.

- [ ] **Step 6: Commit**

```bash
git add docs/home-assistant/power/powercalc-groups.json scripts/home_assistant_power_groups.py tests/test_home_assistant_power_groups.py
git commit -m "feat: define home assistant power group hierarchy"
```

## Task 3: Render the PowerCalc Package

**Files:**
- Modify: `scripts/home_assistant_power_groups.py`
- Modify: `tests/test_home_assistant_power_groups.py`

- [ ] **Step 1: Add failing render tests**

Append these tests to `PowerGroupConfigTest`:

```python
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
python -m unittest tests/test_home_assistant_power_groups.py
```

Expected: FAIL with missing `render_package` and `dashboard_energy_sensors`.

- [ ] **Step 3: Implement package rendering**

Append this code to `scripts/home_assistant_power_groups.py`:

```python

def slugify(name: str) -> str:
    slug = []
    previous_underscore = False
    for char in name.lower():
        if char.isalnum():
            slug.append(char)
            previous_underscore = False
        elif not previous_underscore:
            slug.append("_")
            previous_underscore = True
    return "".join(slug).strip("_")


def render_package(config: dict[str, Any]) -> str:
    validate_config(config)
    room_by_name = {room["name"]: room for room in config["room_groups"]}
    lines = [
        "powercalc:",
        "  create_utility_meters: true",
        "  sensors:",
    ]
    for area in config["area_groups"]:
        lines.append(f"    - create_group: {area['name']}")
        lines.append("      entities:")
        for member_name in area["members"]:
            member = room_by_name[member_name]
            lines.append(f"        - power_sensor_id: {member['power_sensor_id']}")
            lines.append(f"          energy_sensor_id: {member['energy_sensor_id']}")
    return "\n".join(lines) + "\n"


def dashboard_energy_sensors(config: dict[str, Any]) -> list[str]:
    validate_config(config)
    return [
        f"sensor.{slugify(area['name'])}_energy"
        for area in config["area_groups"]
        if area.get("dashboard") is True
    ]
```

- [ ] **Step 4: Run tests to verify they pass**

Run:

```bash
python -m unittest tests/test_home_assistant_power_groups.py
```

Expected: PASS with `Ran 6 tests`.

- [ ] **Step 5: Render the package locally**

Run:

```bash
python - <<'PY'
from pathlib import Path
import importlib.util
spec = importlib.util.spec_from_file_location("groups", "scripts/home_assistant_power_groups.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
config = module.load_json(Path("docs/home-assistant/power/powercalc-groups.json"))
Path("/tmp/powercalc_groups.yaml").write_text(module.render_package(config), encoding="utf-8")
print("\n".join(module.dashboard_energy_sensors(config)))
PY
```

Expected output:

```text
sensor.downstairs_lights_energy
sensor.main_bedroom_lights_area_energy
sensor.outdoor_lights_energy
sensor.loft_lights_area_energy
```

- [ ] **Step 6: Commit**

```bash
git add scripts/home_assistant_power_groups.py tests/test_home_assistant_power_groups.py
git commit -m "feat: render powercalc area groups"
```

## Task 4: Add Registry Coverage Reporting

**Files:**
- Modify: `scripts/home_assistant_power_groups.py`
- Modify: `tests/test_home_assistant_power_groups.py`

- [ ] **Step 1: Add failing coverage tests**

Append this test to `PowerGroupConfigTest`:

```python
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
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
python -m unittest tests/test_home_assistant_power_groups.py
```

Expected: FAIL with missing `uncovered_lights`.

- [ ] **Step 3: Implement coverage reporting**

Append this code to `scripts/home_assistant_power_groups.py`:

```python

def active_entities(entities: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [entity for entity in entities if entity.get("disabled_by") is None]


def device_by_id(devices: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    return {device["id"]: device for device in devices if isinstance(device.get("id"), str)}


def powercalc_device_ids(entities: list[dict[str, Any]]) -> set[str]:
    return {
        entity["device_id"]
        for entity in active_entities(entities)
        if entity.get("platform") == "powercalc"
        and isinstance(entity.get("entity_id"), str)
        and entity["entity_id"].endswith("_power")
        and isinstance(entity.get("device_id"), str)
    }


def uncovered_lights(entities: list[dict[str, Any]], devices: list[dict[str, Any]]) -> list[str]:
    devices_by_id = device_by_id(devices)
    covered_devices = powercalc_device_ids(entities)
    rows: list[str] = []
    for entity in active_entities(entities):
        entity_id = entity.get("entity_id")
        if not isinstance(entity_id, str) or not entity_id.startswith("light."):
            continue
        device_id = entity.get("device_id")
        if isinstance(device_id, str) and device_id in covered_devices:
            continue
        device = devices_by_id.get(device_id, {})
        if device.get("entry_type") == "service":
            continue
        name = device.get("name_by_user") or device.get("name") or entity.get("name") or entity.get("original_name") or ""
        manufacturer = device.get("manufacturer") or ""
        model = device.get("model") or ""
        rows.append(f"{entity_id}\t{name}\t{manufacturer}\t{model}")
    return sorted(rows)
```

- [ ] **Step 4: Run tests to verify they pass**

Run:

```bash
python -m unittest tests/test_home_assistant_power_groups.py
```

Expected: PASS with `Ran 7 tests`.

- [ ] **Step 5: Run the live read-only coverage report**

Run:

```bash
jq -s -r '
  .[0].data.entities as $entities |
  .[1].data.devices as $devices |
  [$entities[] | select(.platform=="powercalc" and (.entity_id|test("_power$")) and .disabled_by==null and .device_id!=null) | .device_id] as $covered |
  $entities[]
  | select(.entity_id|startswith("light."))
  | select(.disabled_by==null)
  | . as $entity
  | ($devices[] | select(.id==$entity.device_id)) as $device
  | select(($device.entry_type // "") != "service")
  | select(([$entity.device_id] - $covered) | length > 0)
  | [$entity.entity_id, ($device.name_by_user // $device.name // ""), ($device.manufacturer // ""), ($device.model // "")]
  | @tsv
' \
  <(kubectl exec -n home-automation code-7f49489ccf-f6bzp -- cat /config/.storage/core.entity_registry) \
  <(kubectl exec -n home-automation code-7f49489ccf-f6bzp -- cat /config/.storage/core.device_registry)
```

Expected current candidates include:

```text
light.cooker_light_strip	Cooker light strip	VEWsmart by TLW	Dimmable light
light.hue_color_spot_1	Hall spot 4	Signify Netherlands B.V.	Hue color spot
light.hue_ambiance_lamp_1	ambiance lamp	Signify Netherlands B.V.	Hue ambiance lamp
light.unity_light_2	Unity Office	LoopOn	Unity
```

- [ ] **Step 6: Commit**

```bash
git add scripts/home_assistant_power_groups.py tests/test_home_assistant_power_groups.py
git commit -m "feat: report home assistant light power coverage"
```

## Task 5: Apply the PowerCalc Package to Live Home Assistant

**Files:**
- Live create: `/config/packages/powercalc_groups.yaml`
- Live modify: `/config/configuration.yaml`
- Repository read: `docs/home-assistant/power/powercalc-groups.json`
- Repository read: `scripts/home_assistant_power_groups.py`

- [ ] **Step 1: Render the package**

Run:

```bash
python - <<'PY'
from pathlib import Path
import importlib.util
spec = importlib.util.spec_from_file_location("groups", "scripts/home_assistant_power_groups.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
config = module.load_json(Path("docs/home-assistant/power/powercalc-groups.json"))
Path("/tmp/powercalc_groups.yaml").write_text(module.render_package(config), encoding="utf-8")
print(Path("/tmp/powercalc_groups.yaml").read_text(encoding="utf-8"))
PY
```

Expected: `/tmp/powercalc_groups.yaml` starts with:

```yaml
powercalc:
  create_utility_meters: true
  sensors:
    - create_group: Downstairs lights
```

- [ ] **Step 2: Back up the live HA config file**

Run:

```bash
kubectl exec -n home-automation code-7f49489ccf-f6bzp -- cp /config/configuration.yaml /config/configuration.yaml.pre-powercalc-groups
```

Expected: command exits `0`.

- [ ] **Step 3: Enable HA packages under the existing `homeassistant:` block**

Open `/config/configuration.yaml` through the `code` pod or code-server and change the existing block to include `packages`:

```yaml
homeassistant:
  name: !env_var HASS_name
  latitude: !env_var HASS_latitude
  longitude: !env_var HASS_longitude
  elevation: !env_var HASS_elevation
  unit_system: metric
  external_url: !env_var HASS_EXTERNAL_URL
  internal_url: !env_var HASS_INTERNAL_URL
  packages: !include_dir_named packages
  customize:
    sensor.sonos_beam_audio_input_format:
      hidden: true
```

- [ ] **Step 4: Copy the package into the HA config PVC**

Run:

```bash
kubectl exec -n home-automation code-7f49489ccf-f6bzp -- mkdir -p /config/packages
kubectl cp /tmp/powercalc_groups.yaml home-automation/code-7f49489ccf-f6bzp:/config/packages/powercalc_groups.yaml
```

Expected: both commands exit `0`.

- [ ] **Step 5: Check Home Assistant configuration**

Run:

```bash
kubectl exec -n home-automation home-assistant-0 -- python -m homeassistant --script check_config --config /config
```

Expected: output includes `Testing configuration at /config` and ends without an error traceback.

- [ ] **Step 6: Restart Home Assistant to load PowerCalc YAML**

Run:

```bash
kubectl rollout restart statefulset/home-assistant -n home-automation
kubectl rollout status statefulset/home-assistant -n home-automation --timeout=5m
kubectl get pod -n home-automation home-assistant-0
```

Expected: rollout status reports success and `home-assistant-0` returns `1/1 Running`.

- [ ] **Step 7: Verify group sensors exist**

Run with a long-lived HA token:

```bash
for sensor in \
  sensor.downstairs_lights_energy \
  sensor.main_bedroom_lights_area_energy \
  sensor.outdoor_lights_energy \
  sensor.loft_lights_area_energy
do
  curl -fsS \
    -H "Authorization: Bearer ${HOMEASSISTANT_TOKEN}" \
    -H "Content-Type: application/json" \
    "https://home-assistant.ironstone.casa/api/states/${sensor}" \
    | jq -r '.entity_id + " " + (.attributes.device_class // "") + " " + (.attributes.state_class // "") + " " + (.attributes.unit_of_measurement // "")'
done
```

Expected:

```text
sensor.downstairs_lights_energy energy total kWh
sensor.main_bedroom_lights_area_energy energy total kWh
sensor.outdoor_lights_energy energy total kWh
sensor.loft_lights_area_energy energy total kWh
```

- [ ] **Step 8: Commit repository-side tooling**

Do not commit live `/config` files from the PVC. Commit only the source-controlled files:

```bash
git add docs/home-assistant/power/powercalc-groups.json scripts/home_assistant_power_groups.py tests/test_home_assistant_power_groups.py
git commit -m "feat: add repeatable powercalc group generation"
```

## Task 6: Add Area Sensors to the Energy Dashboard

**Files:**
- Live UI/storage: Home Assistant Energy Dashboard
- Repository create: `docs/home-assistant/power/README.md`

- [ ] **Step 1: Create operator documentation**

Create `docs/home-assistant/power/README.md` with this content:

````markdown
# Home Assistant Power Groups

PowerCalc light/device sensors are grouped in two layers:

1. Leaf or room sensors, such as `sensor.kitchen_lights_energy`.
2. Area sensors, such as `sensor.downstairs_lights_energy`.

Only area energy sensors should be added to the Energy Dashboard. Adding both a room sensor and its area parent double-counts the same energy.

## Energy Dashboard Sensors

Add these as individual devices:

- `sensor.downstairs_lights_energy`
- `sensor.main_bedroom_lights_area_energy`
- `sensor.outdoor_lights_energy`
- `sensor.loft_lights_area_energy`

## UI Steps

1. Open Home Assistant.
2. Go to Settings > Dashboards > Energy.
3. Under Individual devices, choose Add device.
4. Add each area energy sensor listed above.
5. Save the Energy configuration.
6. Wait for the Energy dashboard statistics card to refresh.

## Verification

Run:

```bash
kubectl exec -n home-automation code-7f49489ccf-f6bzp -- cat /config/.storage/energy \
  | jq -r '.. | strings | select(startswith("sensor."))' \
  | sort
```

The output should include the four area sensors listed above and should not include their child room sensors.
````

- [ ] **Step 2: Add the sensors through the UI**

Follow `docs/home-assistant/power/README.md`.

Expected: Home Assistant accepts all four sensors as individual devices.

- [ ] **Step 3: Verify Energy Dashboard storage**

Run:

```bash
kubectl exec -n home-automation code-7f49489ccf-f6bzp -- cat /config/.storage/energy \
  | jq -r '.. | strings | select(startswith("sensor."))' \
  | sort
```

Expected output includes:

```text
sensor.downstairs_lights_energy
sensor.loft_lights_area_energy
sensor.main_bedroom_lights_area_energy
sensor.outdoor_lights_energy
```

Expected output does not include these child room sensors as Energy Dashboard individual devices:

```text
sensor.kitchen_lights_energy
sensor.living_room_lights_energy
sensor.hall_lights_energy
sensor.main_bedroom_energy
sensor.garden_lights_energy
sensor.porch_energy
sensor.loft_ambiance_energy
```

- [ ] **Step 4: Commit docs**

```bash
git add docs/home-assistant/power/README.md
git commit -m "docs: document home assistant power dashboard groups"
```

## Task 7: Fix Assist MCP Exposure and Client Instructions

**Files:**
- Repository create: `docs/home-assistant/assist-mcp.md`
- Live UI/storage: Settings > Voice assistants > Expose
- Local user action: create a Home Assistant long-lived access token

- [ ] **Step 1: Verify the MCP server integration exists**

Run:

```bash
kubectl exec -n home-automation code-7f49489ccf-f6bzp -- cat /config/.storage/core.config_entries \
  | jq -r '.data.entries[] | select(.domain=="mcp_server") | {title, disabled_by, data, options}'
```

Expected output:

```json
{
  "title": "Assist",
  "disabled_by": null,
  "data": {
    "llm_hass_api": [
      "assist"
    ]
  },
  "options": {}
}
```

- [ ] **Step 2: Create MCP operator documentation**

Create `docs/home-assistant/assist-mcp.md` with this content:

````markdown
# Home Assistant Assist MCP

Home Assistant exposes its MCP server at:

```text
https://home-assistant.ironstone.casa/api/mcp
```

The server requires authentication and only exposes entities allowed through Assist exposure settings.

## Expose Read-Only Power Sensors

1. Open Home Assistant.
2. Go to Settings > Voice assistants.
3. Open the Expose tab.
4. Choose Assist.
5. Expose these sensor entities:
   - `sensor.downstairs_lights_power`
   - `sensor.downstairs_lights_energy`
   - `sensor.main_bedroom_lights_area_power`
   - `sensor.main_bedroom_lights_area_energy`
   - `sensor.outdoor_lights_power`
   - `sensor.outdoor_lights_energy`
   - `sensor.loft_lights_area_power`
   - `sensor.loft_lights_area_energy`
   - `sensor.washing_machine_current_consumption`
   - `sensor.washing_machine_today_s_consumption`
   - `sensor.tv_socket_current_consumption`
   - `sensor.tv_socket_today_s_consumption`
   - `sensor.office_switch_current_consumption`
   - `sensor.office_switch_today_s_consumption`
   - `sensor.rack_switch_power`
   - `sensor.rack_switch_energy`
   - `sensor.spare_power`
   - `sensor.spare_energy`
6. Do not expose `light.*`, `switch.*`, `cover.*`, `lock.*`, `climate.*`, or alarm entities for the power-insight use case.

## Create a Token

1. Open the user profile page in Home Assistant.
2. Under Security, create a long-lived access token named `codex-home-assistant-mcp`.
3. Store it locally as `HOMEASSISTANT_TOKEN`.

## Direct Streamable HTTP Client Config

Use this shape for clients that support remote streamable HTTP MCP directly:

```json
{
  "mcpServers": {
    "homeassistant": {
      "serverUrl": "https://home-assistant.ironstone.casa/api/mcp",
      "headers": {
        "Authorization": "Bearer ${HOMEASSISTANT_TOKEN}"
      }
    }
  }
}
```

## mcp-proxy Client Config

Use this shape for stdio-only MCP clients:

```json
{
  "mcpServers": {
    "homeassistant": {
      "command": "mcp-proxy",
      "args": [
        "--transport=streamablehttp",
        "--stateless",
        "https://home-assistant.ironstone.casa/api/mcp"
      ],
      "env": {
        "API_ACCESS_TOKEN": "${HOMEASSISTANT_TOKEN}"
      }
    }
  }
}
```

## Endpoint Checks

No token should fail:

```bash
curl -i https://home-assistant.ironstone.casa/api/mcp
```

Expected: `401 Unauthorized` or another authentication failure.

With token:

```bash
curl -i \
  -H "Authorization: Bearer ${HOMEASSISTANT_TOKEN}" \
  https://home-assistant.ironstone.casa/api/mcp
```

Expected: not `401`. A method or content-type error is acceptable for raw `curl`, because MCP clients use the MCP protocol over this endpoint.

## Fallback When Codex Cannot Attach the MCP Server

If the current Codex environment cannot add a user MCP server, use the Home Assistant REST API for the first audit pass:

```bash
curl -fsS \
  -H "Authorization: Bearer ${HOMEASSISTANT_TOKEN}" \
  -H "Content-Type: application/json" \
  https://home-assistant.ironstone.casa/api/states/sensor.downstairs_lights_energy
```

This fallback is read-only and enough for power insight reports. MCP can be enabled later in the desktop app or host settings using one of the configs above.
````

- [ ] **Step 3: Expose the read-only sensors through Assist**

Follow `docs/home-assistant/assist-mcp.md`.

Expected: the Expose tab shows the listed sensors exposed to Assist.

- [ ] **Step 4: Verify the exposure storage**

Run:

```bash
kubectl exec -n home-automation code-7f49489ccf-f6bzp -- cat /config/.storage/homeassistant.exposed_entities \
  | jq -r '.data.exposed_entities | to_entries[] | select(.value.assistants.conversation.should_expose == true) | .key' \
  | sort
```

Expected output includes:

```text
sensor.downstairs_lights_energy
sensor.downstairs_lights_power
sensor.loft_lights_area_energy
sensor.loft_lights_area_power
sensor.main_bedroom_lights_area_energy
sensor.main_bedroom_lights_area_power
sensor.outdoor_lights_energy
sensor.outdoor_lights_power
```

- [ ] **Step 5: Verify the MCP endpoint behavior**

Run:

```bash
curl -i https://home-assistant.ironstone.casa/api/mcp
```

Expected: `401 Unauthorized` or another authentication failure.

Run:

```bash
curl -i \
  -H "Authorization: Bearer ${HOMEASSISTANT_TOKEN}" \
  https://home-assistant.ironstone.casa/api/mcp
```

Expected: not `401`.

- [ ] **Step 6: Commit MCP docs**

```bash
git add docs/home-assistant/assist-mcp.md
git commit -m "docs: document home assistant assist mcp access"
```

## Task 8: Final Verification and Cleanup

**Files:**
- Read: `docs/home-assistant/power/powercalc-groups.json`
- Read: `docs/home-assistant/power/README.md`
- Read: `docs/home-assistant/assist-mcp.md`
- Read: `/config/packages/powercalc_groups.yaml`

- [ ] **Step 1: Run local unit tests**

Run:

```bash
python -m unittest tests/test_home_assistant_power_groups.py
```

Expected: PASS.

- [ ] **Step 2: Run repository YAML validation**

Run:

```bash
task kubernetes:yayamlls
```

Expected: PASS. This should not validate live HA PVC files, but it confirms repo changes did not break Kubernetes manifests.

- [ ] **Step 3: Check Home Assistant logs for PowerCalc errors**

Run:

```bash
kubectl logs -n home-automation home-assistant-0 --since=20m | rg -i 'powercalc|energy|mcp|assist'
```

Expected: no PowerCalc traceback and no repeated MCP/Assist errors.

- [ ] **Step 4: Confirm Energy Dashboard sensors are top-level groups**

Run:

```bash
kubectl exec -n home-automation code-7f49489ccf-f6bzp -- cat /config/.storage/energy \
  | jq -r '.. | strings | select(startswith("sensor."))' \
  | sort
```

Expected: includes top-level area sensors and excludes child room sensors listed in Task 6.

- [ ] **Step 5: Confirm Assist exposure remains read-only**

Run:

```bash
kubectl exec -n home-automation code-7f49489ccf-f6bzp -- cat /config/.storage/homeassistant.exposed_entities \
  | jq -r '.data.exposed_entities | to_entries[] | select(.value.assistants.conversation.should_expose == true) | .key' \
  | sort
```

Expected: output contains only `sensor.*` entities for power/energy insight.

- [ ] **Step 6: Commit final verification notes if docs changed**

```bash
git status --short
git add docs/home-assistant/power/README.md docs/home-assistant/assist-mcp.md
git commit -m "docs: record home assistant power verification"
```

If `git status --short` shows no changes, skip this commit.

## Self-Review Notes

- Spec coverage: PowerCalc leaf-to-room-to-area grouping is covered in Tasks 2, 3, and 5. Energy Dashboard inclusion is covered in Task 6. Assist MCP repair and fallback instructions are covered in Task 7.
- Placeholder scan: no open-ended implementation markers remain.
- Type consistency: `room_groups`, `area_groups`, `power_sensor_id`, `energy_sensor_id`, `dashboard`, and `members` are used consistently across JSON, tests, and renderer code.
- Safety: the plan avoids direct writes to Home Assistant `.storage` files and keeps controllable entities out of Assist exposure for the first pass.
