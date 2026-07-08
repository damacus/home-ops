from __future__ import annotations

import argparse
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
        if not isinstance(dashboard, bool):
            raise ValueError(f"{area_name} dashboard must be a boolean")
        for member in members:
            if not isinstance(member, str) or not member:
                raise ValueError(f"{area_name} members must contain non-empty strings")
            if member not in room_names:
                raise ValueError(f"Unknown room group {member!r} in area {area_name!r}")
            if dashboard is True and member in dashboard_members:
                other = dashboard_members[member]
                raise ValueError(f"Dashboard double count: {member!r} is in {other!r} and {area_name!r}")
            if dashboard is True:
                dashboard_members[member] = area_name


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


def yaml_double_quote(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def render_package(config: dict[str, Any]) -> str:
    validate_config(config)
    room_by_name = {room["name"]: room for room in config["room_groups"]}
    lines = [
        PACKAGE_HEADER,
        "  create_utility_meters: true",
        "  sensors:",
    ]
    for area in config["area_groups"]:
        lines.append(f"    - create_group: {yaml_double_quote(area['name'])}")
        lines.append("      entities:")
        for member_name in area["members"]:
            member = room_by_name[member_name]
            power_sensor_id = yaml_double_quote(member["power_sensor_id"])
            energy_sensor_id = yaml_double_quote(member["energy_sensor_id"])
            lines.append(f"        - power_sensor_id: {power_sensor_id}")
            lines.append(f"          energy_sensor_id: {energy_sensor_id}")
    return "\n".join(lines) + "\n"


def dashboard_energy_sensors(config: dict[str, Any]) -> list[str]:
    validate_config(config)
    sensors: list[str] = []
    dashboard_slugs: dict[str, str] = {}
    for area in config["area_groups"]:
        if area.get("dashboard") is not True:
            continue
        slug = slugify(area["name"])
        if not slug:
            raise ValueError(f"Dashboard energy sensor slug is empty for {area['name']!r}")
        if slug in dashboard_slugs:
            other = dashboard_slugs[slug]
            raise ValueError(
                f"Duplicate dashboard energy sensor slug: {slug} "
                f"({other!r} and {area['name']!r})"
            )
        dashboard_slugs[slug] = area["name"]
        sensors.append(f"sensor.{slug}_energy")
    return sensors


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


def registry_data_list(registry: dict[str, Any], key: str) -> list[dict[str, Any]]:
    data = registry.get("data")
    if not isinstance(data, dict):
        raise ValueError(f"registry must contain data.{key}")
    records = data.get(key)
    if not isinstance(records, list):
        raise ValueError(f"registry data.{key} must be a list")
    typed_records: list[dict[str, Any]] = []
    for record in records:
        if not isinstance(record, dict):
            raise ValueError(f"registry data.{key} entries must be objects")
        typed_records.append(record)
    return typed_records


def uncovered_lights_from_registry_exports(
    entity_registry: dict[str, Any],
    device_registry: dict[str, Any],
) -> list[str]:
    entities = registry_data_list(entity_registry, "entities")
    devices = registry_data_list(device_registry, "devices")
    return uncovered_lights(entities, devices)


def load_uncovered_lights(entity_registry_path: Path, device_registry_path: Path) -> list[str]:
    entity_registry = load_json(entity_registry_path)
    device_registry = load_json(device_registry_path)
    return uncovered_lights_from_registry_exports(entity_registry, device_registry)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Report active Home Assistant light entities without PowerCalc power sensors.",
    )
    parser.add_argument("entity_registry", type=Path, help="Path to core.entity_registry JSON export")
    parser.add_argument("device_registry", type=Path, help="Path to core.device_registry JSON export")
    args = parser.parse_args(argv)

    for row in load_uncovered_lights(args.entity_registry, args.device_registry):
        print(row)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
