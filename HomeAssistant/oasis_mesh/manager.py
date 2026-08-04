"""Semantic local transport for the Oasis Bluetooth Mesh bridge."""

from __future__ import annotations

import asyncio


class OasisMeshManager:
    """Send Oasis commands through the single sequence-owning local bridge."""

    def __init__(self, *, bridge_host: str, bridge_port: int) -> None:
        self._host = bridge_host
        self._port = bridge_port
        self._lock = asyncio.Lock()

    async def async_send_power(self, destination: int, on: bool) -> None:
        """Ask the bridge to construct and send one replay-safe power command."""
        async with self._lock:
            await self._send_command(f"POWER {destination} {int(on)}")

    async def async_send_brightness(self, destination: int, brightness: int) -> None:
        """Set brightness using Oasis's 0-100 scale."""
        if not 0 <= brightness <= 100:
            raise ValueError("brightness must be between 0 and 100")
        async with self._lock:
            await self._send_command(f"BRIGHTNESS {destination} {brightness}")

    async def async_send_color_temperature(
        self, destination: int, temperature: int, brightness: int
    ) -> None:
        """Set white temperature and brightness in one Oasis command."""
        if not 2700 <= temperature <= 6500:
            raise ValueError("temperature must be between 2700 and 6500 kelvin")
        if not 0 <= brightness <= 100:
            raise ValueError("brightness must be between 0 and 100")
        async with self._lock:
            await self._send_command(
                f"CCTB {destination} {temperature} {brightness}"
            )

    async def _send_command(self, command: str) -> str:
        last_response = "no response"
        for attempt in range(4):
            try:
                reader, writer = await asyncio.wait_for(
                    asyncio.open_connection(self._host, self._port), timeout=3
                )
                writer.write(command.encode("ascii") + b"\n")
                await writer.drain()
                response = await asyncio.wait_for(reader.readline(), timeout=3)
                writer.close()
                await writer.wait_closed()
                last_response = response.decode("ascii", "replace").strip()
                if last_response == "OK":
                    return last_response
                if last_response != "ERR bluetooth_not_ready":
                    break
            except (OSError, TimeoutError) as error:
                last_response = type(error).__name__
            if attempt < 3:
                await asyncio.sleep(1)
        raise RuntimeError(f"Oasis bridge rejected command: {last_response}")

    async def async_bridge_ready(self) -> bool:
        """Return whether the bridge has an active Bluetooth Mesh Proxy link."""
        try:
            reader, writer = await asyncio.wait_for(
                asyncio.open_connection(self._host, self._port), timeout=2
            )
            writer.write(b"STATUS\n")
            await writer.drain()
            response = await asyncio.wait_for(reader.readline(), timeout=2)
            writer.close()
            await writer.wait_closed()
            return response == b"READY\n"
        except (OSError, TimeoutError):
            return False
