"""Reusable Distant Horizon protocol client.

This is the seed of the permanent protocol test harness: tests and
benchmarks talk to the server through DHClient rather than raw sockets,
so protocol changes stay in one place.

Wire protocol v1: every message is a JSON object with a "v" version field
and a "type" discriminator (see server/src/dh_server/protocol.gleam).
"""

from __future__ import annotations

import json
from typing import Any, AsyncIterator, Optional

import websockets

PROTOCOL_VERSION = 1
DEFAULT_URL = "ws://127.0.0.1:8484/ws"


class ProtocolError(Exception):
    """A message violated the wire protocol."""


class DHClient:
    """Async client for the Distant Horizon WebSocket protocol.

    Usage:
        client = DHClient()
        await client.connect()
        async for message in client.messages():
            ...
        await client.close()

    Or as an async context manager:
        async with DHClient() as client:
            snapshot = await client.recv()
    """

    def __init__(self, url: str = DEFAULT_URL, name: str = "client"):
        self.url = url
        self.name = name
        self._ws: Optional[websockets.ClientConnection] = None

    async def connect(self) -> None:
        self._ws = await websockets.connect(
            self.url,
            max_size=16 * 1024 * 1024,
            compression=None,
        )

    async def close(self) -> None:
        if self._ws is not None:
            await self._ws.close()
            self._ws = None

    async def __aenter__(self) -> "DHClient":
        await self.connect()
        return self

    async def __aexit__(self, *exc_info: Any) -> None:
        await self.close()

    @property
    def connected(self) -> bool:
        return self._ws is not None

    async def send(self, message: dict) -> None:
        """Send a client->server message; fills in the protocol version."""
        assert self._ws is not None, "not connected"
        message.setdefault("v", PROTOCOL_VERSION)
        await self._ws.send(json.dumps(message))

    async def recv(self) -> dict:
        """Receive and parse one server message (any type)."""
        assert self._ws is not None, "not connected"
        raw = await self._ws.recv()
        try:
            message = json.loads(raw)
        except json.JSONDecodeError as e:
            raise ProtocolError(f"unparseable frame: {e}") from e
        if not isinstance(message, dict):
            raise ProtocolError(f"expected object, got {type(message).__name__}")
        if message.get("v") != PROTOCOL_VERSION:
            raise ProtocolError(f"unexpected protocol version: {message.get('v')!r}")
        if "type" not in message:
            raise ProtocolError("message missing 'type'")
        return message

    async def messages(self) -> AsyncIterator[dict]:
        """Iterate over incoming messages until the connection closes."""
        while True:
            try:
                yield await self.recv()
            except websockets.ConnectionClosed:
                return

    async def recv_type(self, expected_type: str, skip: int = 1000) -> dict:
        """Receive messages until one of `expected_type` arrives.

        Other message types (e.g. snapshots still streaming in) are skipped,
        up to `skip` of them.
        """
        for _ in range(skip):
            message = await self.recv()
            if message["type"] == expected_type:
                return message
        raise ProtocolError(f"no '{expected_type}' message within {skip} frames")

    # --- Convenience wrappers for specific protocol messages ---

    async def get_stats(self) -> dict:
        """Request server stats and wait for the stats response."""
        await self.send({"type": "get_stats"})
        return await self.recv_type("stats")


def validate_snapshot(message: dict, expected_ships: int) -> None:
    """Raise ProtocolError unless `message` is a well-formed snapshot."""
    if message.get("type") != "snapshot":
        raise ProtocolError(f"expected snapshot, got {message.get('type')!r}")
    if not isinstance(message.get("tick"), int):
        raise ProtocolError("snapshot 'tick' is not an int")
    ships = message.get("ships")
    if not isinstance(ships, list) or len(ships) != expected_ships:
        got = len(ships) if isinstance(ships, list) else type(ships).__name__
        raise ProtocolError(f"expected {expected_ships} ships, got {got}")
    for ship in ships:
        if not isinstance(ship.get("id"), int):
            raise ProtocolError(f"ship id missing/bad: {ship!r}")
        for key in ("x", "y", "vx", "vy"):
            value = ship.get(key)
            if not isinstance(value, (int, float)):
                raise ProtocolError(f"ship {ship.get('id')} field {key!r} bad: {value!r}")
