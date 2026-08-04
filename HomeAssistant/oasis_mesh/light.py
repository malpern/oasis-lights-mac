"""Oasis Bluetooth Mesh light entities."""

from __future__ import annotations

from typing import Any

import voluptuous as vol

from homeassistant.components.light import (
    ATTR_BRIGHTNESS,
    ATTR_COLOR_TEMP_KELVIN,
    PLATFORM_SCHEMA,
    ColorMode,
    LightEntity,
)
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers import config_validation as cv
from homeassistant.helpers.entity_platform import AddEntitiesCallback
from homeassistant.helpers.restore_state import RestoreEntity
from homeassistant.helpers.typing import ConfigType, DiscoveryInfoType

from .manager import OasisMeshManager

LIGHTS = (
    ("Oasis Ambient 1", "oasis_ambient_unicast_0002", 0x0002),
    ("Oasis Ambient 2", "oasis_ambient_unicast_0003", 0x0003),
)

PLATFORM_SCHEMA = PLATFORM_SCHEMA.extend(
    {
        vol.Optional("bridge_host", default="127.0.0.1"): cv.string,
        vol.Optional("bridge_port", default=18765): cv.port,
    }
)


async def async_setup_platform(
    hass: HomeAssistant,
    config: ConfigType,
    async_add_entities: AddEntitiesCallback,
    discovery_info: DiscoveryInfoType | None = None,
) -> None:
    """Add the two provisioned Oasis lights from YAML."""
    manager = OasisMeshManager(
        bridge_host=config["bridge_host"],
        bridge_port=config["bridge_port"],
    )
    async_add_entities(
        OasisMeshLight(manager, name, unique_id, destination)
        for name, unique_id, destination in LIGHTS
    )


async def async_setup_entry(
    hass: HomeAssistant,
    entry: ConfigEntry,
    async_add_entities: AddEntitiesCallback,
) -> None:
    """Add the two provisioned Oasis lights."""
    manager: OasisMeshManager = entry.runtime_data
    async_add_entities(
        OasisMeshLight(manager, name, unique_id, destination)
        for name, unique_id, destination in LIGHTS
    )


class OasisMeshLight(RestoreEntity, LightEntity):
    """An optimistic local Oasis light."""

    _attr_should_poll = True
    _attr_supported_color_modes = {ColorMode.COLOR_TEMP}
    _attr_color_mode = ColorMode.COLOR_TEMP
    _attr_min_color_temp_kelvin = 2700
    _attr_max_color_temp_kelvin = 6500

    def __init__(
        self,
        manager: OasisMeshManager,
        name: str,
        unique_id: str,
        destination: int,
    ) -> None:
        self._manager = manager
        self._destination = destination
        self._attr_name = name
        self._attr_unique_id = unique_id
        self._attr_is_on: bool | None = None
        self._attr_brightness = 255
        self._attr_color_temp_kelvin = 3500
        self._attr_available = False

    async def async_added_to_hass(self) -> None:
        await super().async_added_to_hass()
        if (state := await self.async_get_last_state()) is not None:
            self._attr_is_on = state.state == "on"
            if (brightness := state.attributes.get(ATTR_BRIGHTNESS)) is not None:
                self._attr_brightness = int(brightness)
            if (
                temperature := state.attributes.get(ATTR_COLOR_TEMP_KELVIN)
            ) is not None:
                self._attr_color_temp_kelvin = int(temperature)

    async def async_turn_on(self, **kwargs: Any) -> None:
        brightness = int(kwargs.get(ATTR_BRIGHTNESS, self._attr_brightness or 255))
        if brightness <= 0:
            await self.async_turn_off()
            return

        temperature = kwargs.get(ATTR_COLOR_TEMP_KELVIN)
        protocol_brightness = max(1, min(100, round(brightness * 100 / 255)))
        if temperature is not None:
            temperature = max(2700, min(6500, int(temperature)))
            await self._manager.async_send_color_temperature(
                self._destination, temperature, protocol_brightness
            )
            self._attr_color_temp_kelvin = temperature
        elif ATTR_BRIGHTNESS in kwargs:
            await self._manager.async_send_brightness(
                self._destination, protocol_brightness
            )
        else:
            await self._manager.async_send_power(self._destination, True)

        self._attr_brightness = brightness
        self._attr_is_on = True
        self.async_write_ha_state()

    async def async_turn_off(self, **kwargs: Any) -> None:
        await self._manager.async_send_power(self._destination, False)
        self._attr_is_on = False
        self.async_write_ha_state()

    async def async_update(self) -> None:
        self._attr_available = await self._manager.async_bridge_ready()
