"""Offline Oasis automation protocol helpers.

This module deliberately performs no network I/O. It models the structures
decoded from Oasis Android 2.7.0 and preserves unknown JSON fields when merging.
"""

from __future__ import annotations

from copy import deepcopy
import math
from typing import Any, Iterable, Mapping, MutableMapping, Sequence


LOCATION_COMMAND = 2049
TIMEZONE_COMMAND = 2050
AUTOMATION_COMMAND = 2051
COMMAND_TIMEOUT_SECONDS = 2_592_000
LOCATION_BLE_OPCODE = 0xCF
TIMEZONE_BLE_OPCODE = 0xC9
OASIS_COMPANY_ID = 0x02E5
WEEKDAYS = ("sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday")


def decode_days(mask: int) -> tuple[str, ...]:
    """Return weekday names represented by Oasis's Sunday-first bitmask."""
    if not isinstance(mask, int) or mask < 0 or mask > 0x7F:
        raise ValueError("daysOfWeek must be an integer from 0 through 127")
    return tuple(day for bit, day in enumerate(WEEKDAYS) if mask & (1 << bit))


def encode_days(days: Iterable[str]) -> int:
    """Encode weekday names as Oasis's Sunday-first bitmask."""
    normalized = {day.casefold() for day in days}
    unknown = normalized.difference(WEEKDAYS)
    if unknown:
        raise ValueError(f"unknown weekdays: {sorted(unknown)}")
    return sum(1 << bit for bit, day in enumerate(WEEKDAYS) if day in normalized)


def validate_start_time(value: Mapping[str, Any]) -> None:
    """Validate an Oasis fixed, sunrise, or sunset start-time object."""
    kind = value.get("type")
    expected_value = "minutes" if kind == "fixed" else "offset"
    if kind not in {"fixed", "sunrise", "sunset"}:
        raise ValueError("startTime.type must be fixed, sunrise, or sunset")
    if not isinstance(value.get(expected_value), int):
        raise ValueError(f"startTime.{expected_value} must be an integer")


def validate_automation(value: Mapping[str, Any]) -> None:
    """Validate the fields Oasis needs while allowing unknown future fields."""
    required = {
        "id",
        "name",
        "enabled",
        "brightness",
        "temperature",
        "fadeDuration",
        "daysOfWeek",
        "startTime",
        "roomIDs",
    }
    missing = required.difference(value)
    if missing:
        raise ValueError(f"automation is missing fields: {sorted(missing)}")
    if not isinstance(value["id"], str) or not value["id"]:
        raise ValueError("automation.id must be a non-empty string")
    if not isinstance(value["name"], str):
        raise ValueError("automation.name must be a string")
    if not isinstance(value["enabled"], bool):
        raise ValueError("automation.enabled must be boolean")
    for key in ("brightness", "temperature", "fadeDuration"):
        if not isinstance(value[key], int):
            raise ValueError(f"automation.{key} must be an integer")
    decode_days(value["daysOfWeek"])
    if not isinstance(value["startTime"], Mapping):
        raise ValueError("automation.startTime must be an object")
    validate_start_time(value["startTime"])
    if not isinstance(value["roomIDs"], list) or not all(
        isinstance(room_id, str) for room_id in value["roomIDs"]
    ):
        raise ValueError("automation.roomIDs must be a list of strings")


def merge_automation(
    custom_data: Mapping[str, Any],
    replacement: Mapping[str, Any],
) -> dict[str, Any]:
    """Replace one automation by ID without dropping Home Group fields.

    Unknown fields on both the Home Group and the prior automation are retained.
    Fields in ``replacement`` win.
    """
    validate_automation(replacement)
    result = deepcopy(dict(custom_data))
    automations = result.get("automations")
    if not isinstance(automations, list):
        raise ValueError("custom_data.automations must be a list")

    replacement_id = replacement["id"]
    matches = [index for index, item in enumerate(automations) if isinstance(item, Mapping) and item.get("id") == replacement_id]
    if len(matches) != 1:
        raise ValueError(f"expected one automation with id {replacement_id!r}, found {len(matches)}")

    index = matches[0]
    prior = automations[index]
    merged: MutableMapping[str, Any] = deepcopy(dict(prior))
    merged.update(deepcopy(dict(replacement)))
    validate_automation(merged)
    automations[index] = dict(merged)
    return result


def find_home_group(snapshot: Mapping[str, Any]) -> dict[str, Any]:
    """Return the single cached/API node group marked as the Oasis Home Group."""
    groups = snapshot.get("groups")
    if not isinstance(groups, list):
        raise ValueError("snapshot.groups must be a list")
    matches = [
        group
        for group in groups
        if isinstance(group, Mapping)
        and isinstance(group.get("custom_data"), Mapping)
        and group["custom_data"].get("home_group") is True
    ]
    if len(matches) != 1:
        raise ValueError(f"expected one Home Group, found {len(matches)}")
    return deepcopy(dict(matches[0]))


def automations_for_room(
    automations: Sequence[Mapping[str, Any]], room_id: str
) -> list[dict[str, Any]]:
    """Return the complete Oasis schedule dispatched to one room."""
    selected: list[dict[str, Any]] = []
    for automation in automations:
        validate_automation(automation)
        if room_id in automation["roomIDs"]:
            selected.append(deepcopy(dict(automation)))
    if len(selected) > 20:
        raise ValueError("Oasis supports at most 20 automations per room")
    return selected


def _node_command(node_ids: Sequence[str], command: int, data: Mapping[str, Any]) -> dict[str, Any]:
    if not node_ids or not all(isinstance(node_id, str) and node_id for node_id in node_ids):
        raise ValueError("node_ids must contain non-empty strings")
    return {
        "cmd": command,
        "node_ids": list(node_ids),
        "timeout": COMMAND_TIMEOUT_SECONDS,
        "override": True,
        "data": deepcopy(dict(data)),
    }


def _validate_location(latitude: float, longitude: float) -> None:
    if isinstance(latitude, bool) or not isinstance(latitude, (int, float)) or not math.isfinite(latitude):
        raise ValueError("latitude must be a finite number")
    if isinstance(longitude, bool) or not isinstance(longitude, (int, float)) or not math.isfinite(longitude):
        raise ValueError("longitude must be a finite number")
    if not -90 <= latitude <= 90:
        raise ValueError("latitude must be between -90 and 90")
    if not -180 <= longitude <= 180:
        raise ValueError("longitude must be between -180 and 180")


def encode_location_ble(latitude: float, longitude: float) -> bytes:
    """Encode Oasis BLE opcode CF payload: signed microdegrees, big-endian."""
    _validate_location(latitude, longitude)
    latitude_microdegrees = int(latitude * 1_000_000)
    longitude_microdegrees = int(longitude * 1_000_000)
    return latitude_microdegrees.to_bytes(4, "big", signed=True) + longitude_microdegrees.to_bytes(
        4, "big", signed=True
    )


def encode_timezone_ble(timezone: str) -> bytes:
    """Encode Oasis BLE opcode C9 payload as the UTF-8 IANA timezone name."""
    if not isinstance(timezone, str) or not timezone or "\x00" in timezone:
        raise ValueError("timezone must be a non-empty string without NUL bytes")
    return timezone.encode("utf-8")


def location_command(node_ids: Sequence[str], latitude: float, longitude: float) -> dict[str, Any]:
    """Build the decoded RainMaker command-2049 location request body."""
    _validate_location(latitude, longitude)
    return _node_command(node_ids, LOCATION_COMMAND, {"lat": latitude, "lng": longitude})


def timezone_command(node_ids: Sequence[str], timezone: str) -> dict[str, Any]:
    """Build the decoded RainMaker command-2050 timezone request body."""
    encode_timezone_ble(timezone)
    return _node_command(node_ids, TIMEZONE_COMMAND, {"timezone": timezone})


def location_analytics_event(latitude: float, longitude: float) -> tuple[str, dict[str, float]]:
    """Return the analytics event recorded after command 2049 succeeds."""
    _validate_location(latitude, longitude)
    return "Location Set", {"latitude": latitude, "longitude": longitude}


def timezone_analytics_event(timezone: str) -> tuple[str, dict[str, str]]:
    """Return the analytics event recorded after command 2050 succeeds."""
    encode_timezone_ble(timezone)
    return "Timezone Set", {"timezone": timezone}


def node_command(node_ids: Sequence[str], automations: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    """Build the decoded RainMaker command-2051 automation request body."""
    payload = [deepcopy(dict(item)) for item in automations]
    for automation in payload:
        validate_automation(automation)
    return _node_command(node_ids, AUTOMATION_COMMAND, {"automations": payload})


def room_automation_commands(snapshot: Mapping[str, Any]) -> dict[str, dict[str, Any]]:
    """Build the complete command-2051 envelope for every Home Group room.

    The returned dictionary is keyed by node-group ``group_id`` because live
    Oasis data confirms automation ``roomIDs`` refers to that identifier, not
    to the separate ``custom_data.room_id`` value.
    """
    home = find_home_group(snapshot)
    custom_data = home["custom_data"]
    automations = custom_data.get("automations")
    rooms = home.get("sub_groups")
    if not isinstance(automations, list):
        raise ValueError("Home Group custom_data.automations must be a list")
    if not isinstance(rooms, list):
        raise ValueError("Home Group sub_groups must be a list")
    commands: dict[str, dict[str, Any]] = {}
    for room in rooms:
        if not isinstance(room, Mapping):
            raise ValueError("each Home Group room must be an object")
        room_id = room.get("group_id")
        nodes = room.get("nodes")
        if not isinstance(room_id, str) or not room_id:
            raise ValueError("room.group_id must be a non-empty string")
        if not isinstance(nodes, list):
            raise ValueError("room.nodes must be a list")
        commands[room_id] = node_command(nodes, automations_for_room(automations, room_id))
    return commands
