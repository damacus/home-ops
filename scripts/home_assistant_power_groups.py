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
