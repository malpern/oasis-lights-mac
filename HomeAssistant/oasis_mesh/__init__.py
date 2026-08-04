"""Oasis Bluetooth Mesh integration."""

from __future__ import annotations

from homeassistant.config_entries import ConfigEntry
from homeassistant.const import Platform
from homeassistant.core import HomeAssistant
from homeassistant.helpers import config_validation as cv
from homeassistant.helpers.typing import ConfigType

from .manager import OasisMeshManager

DOMAIN = "oasis_mesh"
PLATFORMS = [Platform.LIGHT]
CONFIG_SCHEMA = cv.empty_config_schema(DOMAIN)


async def async_setup(hass: HomeAssistant, config: ConfigType) -> bool:
    """Set up the Oasis Mesh package."""
    return True


async def async_setup_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    """Set up Oasis Mesh from a config entry."""
    entry.runtime_data = OasisMeshManager(
        bridge_host=entry.data.get("bridge_host", "127.0.0.1"),
        bridge_port=int(entry.data.get("bridge_port", 18765)),
    )
    await hass.config_entries.async_forward_entry_setups(entry, PLATFORMS)
    return True


async def async_unload_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    """Unload Oasis Mesh."""
    return await hass.config_entries.async_unload_platforms(entry, PLATFORMS)
