"""Config flow for Oasis Bluetooth Mesh."""

from __future__ import annotations

from typing import Any

from homeassistant.config_entries import ConfigFlow, ConfigFlowResult

from . import DOMAIN


class OasisMeshConfigFlow(ConfigFlow, domain=DOMAIN):
    """Configure the local Oasis bridge."""

    VERSION = 1

    async def async_step_import(
        self, import_data: dict[str, Any]
    ) -> ConfigFlowResult:
        """Import configuration.yaml settings."""
        await self.async_set_unique_id("oasis-mesh-local")
        self._abort_if_unique_id_configured(updates=import_data)
        return self.async_create_entry(title="Oasis Lights", data=import_data)

    async def async_step_user(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        """Create the default localhost bridge entry."""
        if user_input is not None:
            return await self.async_step_import(user_input)
        return self.async_show_form(step_id="user")
