"""Pure helpers for the statically decoded Oasis device protocol.

This module performs no Bluetooth, network, cloud, or filesystem I/O.  It only
encodes message bodies whose layouts are confirmed by static analysis or a
redacted live capture of Oasis iOS 2.7.1.
"""

from __future__ import annotations

import math
from typing import Mapping


OASIS_COMPANY_ID = 0x02E5
OASIS_VENDOR_MODEL_ID = 0x02E5C00A

POWER_OPCODE = 0xC3
BRIGHTNESS_OPCODE = 0xC4
TEMPERATURE_OPCODE = 0xC5
LIGHT_SET_OPCODE = 0xC6
LIGHT_SET_COMMAND_ID = LIGHT_SET_OPCODE
TRANSITION_PREVIEW_OPCODE = 0xC7
LIGHT_BLINK_COMMAND_ID = 0xCB
EFFECT_RAINMAKER_COMMAND_ID = 0xCB
LIGHT_MODE_OPCODE = 0xCC
LIGHT_MODE_COLOR = 0x01
LIGHT_MODE_TEMPERATURE = 0x02
RGB_TRIPLET_OPCODE = LIGHT_SET_OPCODE
WIFI_CREDENTIALS_OPCODE = 0xC1
TIMEZONE_OPCODE = 0xC9
PROVISIONING_MODE_OPCODE = 0xCD
RESPONSE_OPCODE = 0xCE
LOCATION_OPCODE = 0xCF
MISSING_DATA_OPCODE = 0xD1
TEMPERATURE_BRIGHTNESS_OPCODE = 0xD2


def _require_byte(value: int, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= 0xFF:
        raise ValueError(f"{name} must be an integer from 0 through 255")
    return value


def _require_u32(value: int, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= 0xFFFFFFFF:
        raise ValueError(f"{name} must be an unsigned 32-bit integer")
    return value


def _require_unit_number(value: float, name: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError(f"{name} must be a finite number from 0 through 1")
    result = float(value)
    if not 0.0 <= result <= 1.0:
        raise ValueError(f"{name} must be a finite number from 0 through 1")
    return result


def vendor_message_id(opcode: int, company_id: int = OASIS_COMPANY_ID) -> int:
    """Pack an opcode and company ID as the integer expected by Oasis Android.

    The native bridge receives the three on-air access bytes as one integer:
    ``opcode, company-low-byte, company-high-byte``.  For example, power is
    ``0xC3E502``.
    """
    _require_byte(opcode, "opcode")
    if isinstance(company_id, bool) or not isinstance(company_id, int) or not 0 <= company_id <= 0xFFFF:
        raise ValueError("company_id must be an unsigned 16-bit integer")
    swapped_company = ((company_id & 0xFF) << 8) | (company_id >> 8)
    return (opcode << 16) | swapped_company


def unpack_vendor_message_id(message_id: int) -> tuple[int, int]:
    """Return ``(opcode, company_id)`` from an Oasis native message integer."""
    if isinstance(message_id, bool) or not isinstance(message_id, int) or not 0 <= message_id <= 0xFFFFFF:
        raise ValueError("message_id must be an unsigned 24-bit integer")
    opcode = message_id >> 16
    packed_company = message_id & 0xFFFF
    company_id = ((packed_company & 0xFF) << 8) | (packed_company >> 8)
    return opcode, company_id


def encode_power(on: bool) -> bytes:
    """Encode opcode C3's one-byte power payload."""
    if not isinstance(on, bool):
        raise ValueError("on must be boolean")
    return bytes((1 if on else 0,))


def encode_brightness(brightness: int, timestamp: int) -> bytes:
    """Encode opcode C4: percent followed by a little-endian Unix timestamp."""
    if isinstance(brightness, bool) or not isinstance(brightness, int) or not 0 <= brightness <= 100:
        raise ValueError("brightness must be an integer from 0 through 100")
    _require_u32(timestamp, "timestamp")
    return bytes((brightness,)) + timestamp.to_bytes(4, "little")


def encode_temperature(kelvin: int) -> bytes:
    """Encode live iOS opcode C5: a little-endian Kelvin value."""
    if isinstance(kelvin, bool) or not isinstance(kelvin, int) or not 0 <= kelvin <= 0xFFFF:
        raise ValueError("kelvin must be an unsigned 16-bit integer")
    return kelvin.to_bytes(2, "little")


def light_set_rainmaker_data(
    red: float,
    green: float,
    blue: float,
    cold: float,
    warm: float,
) -> dict[str, float]:
    """Build command C6's normalized five-channel RainMaker data object."""
    return {
        "red": _require_unit_number(red, "red"),
        "green": _require_unit_number(green, "green"),
        "blue": _require_unit_number(blue, "blue"),
        "cold": _require_unit_number(cold, "cold"),
        "warm": _require_unit_number(warm, "warm"),
    }


def encode_rgb_triplet(red: float, green: float, blue: float) -> bytes:
    """Encode C6's local-Mesh RGB bytes from normalized channel values.

    The app multiplies each channel by 255 and truncates toward zero.  The
    corresponding RainMaker command carries the same RGB values plus separate
    cold and warm channels.
    """
    channels = (
        _require_unit_number(red, "red"),
        _require_unit_number(green, "green"),
        _require_unit_number(blue, "blue"),
    )
    return bytes(int(channel * 255.0) for channel in channels)


def encode_transition_preview(kelvin: int, brightness: int, duration_millis: int) -> bytes:
    """Encode C7's temporary temperature/brightness preview transition.

    Oasis uses this while previewing a Light Cycle step.  The app's editor
    supplies 60,000 milliseconds; its session teardown sends three zeroes.
    This is not the persisted Light Cycle schedule format.
    """
    if isinstance(kelvin, bool) or not isinstance(kelvin, int) or not 0 <= kelvin <= 0xFFFF:
        raise ValueError("kelvin must be an unsigned 16-bit integer")
    if isinstance(brightness, bool) or not isinstance(brightness, int) or not 0 <= brightness <= 100:
        raise ValueError("brightness must be an integer from 0 through 100")
    _require_u32(duration_millis, "duration_millis")
    return kelvin.to_bytes(2, "little") + bytes((brightness,)) + duration_millis.to_bytes(4, "little")


def encode_light_mode(mode: str) -> bytes:
    """Encode CC's one-byte normal-controls mode selector."""
    values = {
        "color": LIGHT_MODE_COLOR,
        "temperature": LIGHT_MODE_TEMPERATURE,
    }
    if mode not in values:
        raise ValueError("mode must be 'color' or 'temperature'")
    return bytes((values[mode],))


def encode_light_blink(
    red: int,
    green: int,
    blue: int,
    cct: int,
    brightness: int,
    transition_millis: int,
    times: int,
) -> bytes:
    """Encode command CB's fully decoded 11-byte Light Blink payload."""
    rgb = bytes(
        (
            _require_byte(red, "red"),
            _require_byte(green, "green"),
            _require_byte(blue, "blue"),
        )
    )
    if isinstance(cct, bool) or not isinstance(cct, int) or not 0 <= cct <= 0xFFFF:
        raise ValueError("cct must be an unsigned 16-bit integer")
    if isinstance(brightness, bool) or not isinstance(brightness, int) or not 0 <= brightness <= 100:
        raise ValueError("brightness must be an integer from 0 through 100")
    _require_u32(transition_millis, "transition_millis")
    _require_byte(times, "times")
    return (
        rgb
        + cct.to_bytes(2, "little")
        + bytes((brightness,))
        + transition_millis.to_bytes(4, "little")
        + bytes((times,))
    )


def encode_temperature_brightness(kelvin: int, brightness: int, timestamp: int) -> bytes:
    """Encode opcode D2: little-endian kelvin, percent, and Unix timestamp."""
    if isinstance(kelvin, bool) or not isinstance(kelvin, int) or not 0 <= kelvin <= 0xFFFF:
        raise ValueError("kelvin must be an unsigned 16-bit integer")
    if isinstance(brightness, bool) or not isinstance(brightness, int) or not 0 <= brightness <= 100:
        raise ValueError("brightness must be an integer from 0 through 100")
    _require_u32(timestamp, "timestamp")
    return kelvin.to_bytes(2, "little") + bytes((brightness,)) + timestamp.to_bytes(4, "little")


def encode_wifi_credentials(ssid: str, password: str) -> bytes:
    """Encode opcode C1 without logging or retaining either credential."""
    if not isinstance(ssid, str) or not isinstance(password, str):
        raise ValueError("ssid and password must be strings")
    ssid_bytes = ssid.encode("utf-8")
    password_bytes = password.encode("utf-8")
    if not ssid_bytes or len(ssid_bytes) > 0xFF:
        raise ValueError("UTF-8 SSID must contain 1 through 255 bytes")
    if len(password_bytes) > 0xFF:
        raise ValueError("UTF-8 password must contain at most 255 bytes")
    return bytes((len(ssid_bytes),)) + ssid_bytes + bytes((len(password_bytes),)) + password_bytes


def encode_provisioning_mode(mode: int, timeout_ms: int) -> bytes:
    """Encode opcode CD: mode byte and little-endian timeout in milliseconds."""
    _require_byte(mode, "mode")
    _require_u32(timeout_ms, "timeout_ms")
    return bytes((mode,)) + timeout_ms.to_bytes(4, "little")


def decode_response(payload: bytes) -> dict[str, int | bool | None]:
    """Decode the shared CE response shape without guessing its request type."""
    if not isinstance(payload, bytes) or not payload:
        raise ValueError("response payload must contain at least one byte")
    return {
        "success": payload[0] == 1,
        "status": payload[0],
        "detail": payload[1] if len(payload) > 1 else None,
    }


def decode_missing_data_flags(payload: bytes) -> dict[str, bool]:
    """Decode opcode D1's first-byte device-configuration bitmask."""
    if not isinstance(payload, bytes) or not payload:
        raise ValueError("missing-data payload must contain at least one byte")
    flags = payload[0]
    return {
        "needsTimezone": bool(flags & 0x01),
        "needsLocation": bool(flags & 0x02),
        "needsSolarCycle": bool(flags & 0x04),
    }


def effect_rainmaker_data(effect: str, params: Mapping[str, float]) -> dict[str, float | str]:
    """Build Oasis's flattened RainMaker effect data object.

    Oasis sends ``effect`` and each tuning parameter at the same JSON level;
    the parameter map is not nested under a ``params`` key.
    """
    if not isinstance(effect, str) or not effect:
        raise ValueError("effect must be a non-empty string")
    if not isinstance(params, Mapping):
        raise ValueError("params must be a mapping")
    result: dict[str, float | str] = {"effect": effect}
    for key, value in params.items():
        if not isinstance(key, str) or not key or key == "effect":
            raise ValueError("effect parameter names must be non-empty strings other than 'effect'")
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
            raise ValueError(f"effect parameter {key!r} must be a finite number")
        result[key] = float(value)
    return result
