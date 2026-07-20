"""Reusable Distant Horizon protocol client.

This is the seed of the permanent protocol test harness: tests and
benchmarks talk to the server through DHClient rather than raw sockets,
so protocol changes stay in one place.

Wire protocol v1: every message is a JSON object with a "v" version field
and a "type" discriminator (see server/src/dh_server/protocol.gleam).
"""

from __future__ import annotations

import asyncio
import json
import os
from dataclasses import dataclass
from typing import Any, AsyncIterator, Optional

import websockets

PROTOCOL_VERSION = 1
# Follows DH_PORT so harness clients land on whatever port the harness
# started the server on (the `server` fixture sets DH_PORT to its
# dedicated test port, 8585 by default); falls back to 8484 -- the
# server's own default -- when DH_PORT is unset.
def _default_url() -> str:
    # Late-bound so the URL reflects DH_PORT at DHClient() construction time,
    # not at import time -- correctness no longer depends on whether the
    # `server` fixture's env stamp ran before this module was first imported.
    return "ws://127.0.0.1:%s/ws" % os.environ.get("DH_PORT", "8484")


DEFAULT_URL = _default_url()  # snapshot for back-compat references / docs

# Default per-call timeout (seconds) for every reply-waiting API method
# (login, dock, undock, next_snapshot, get_stats, recv_type). A server
# regression that stops replying should fail the run fast with a clear
# error, not hang it forever. Pass timeout=None to wait indefinitely.
DEFAULT_TIMEOUT = 10.0


class ProtocolError(Exception):
    """A message violated the wire protocol."""


@dataclass(frozen=True)
class CharacterView:
    """One character from a `walkers` message, as a typed view. Tests reach
    entities through this (me.x, me.seat) rather than string-indexing dicts;
    raw message dicts remain the tool only where a test asserts on the wire
    shape itself. Positions are in the frame of the character's current
    `space` — ship-local while flying, composite (concourse + docked-ship
    moorings) while docked."""

    id: int
    name: str
    x: float
    y: float
    seat: Optional[str]

    @staticmethod
    def from_wire(data: dict) -> "CharacterView":
        return CharacterView(
            id=int(data.get("id", -1)),
            name=str(data.get("name", "")),
            x=float(data.get("x", 0.0)),
            y=float(data.get("y", 0.0)),
            seat=data.get("seat"),
        )


class AuthError(Exception):
    """A login attempt was rejected by the server."""

    def __init__(self, code: Optional[str], message: Optional[str]):
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message


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

    def __init__(self, url: Optional[str] = None, name: str = "client"):
        self.url = url if url is not None else _default_url()
        self.name = name
        self._ws: Optional[websockets.ClientConnection] = None
        # Populated by login(): the M2 character embodiment for this
        # connection and the (whole-document) ship class it spawned into.
        self.character_id: Optional[int] = None
        self.ship_class: Optional[dict] = None

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

    async def recv_type(
        self,
        expected_type: str,
        skip: int = 1000,
        timeout: Optional[float] = DEFAULT_TIMEOUT,
    ) -> dict:
        """Receive messages until one of `expected_type` arrives.

        Other message types (e.g. snapshots still streaming in) are skipped,
        up to `skip` of them. Raises `ProtocolError` if no such message
        arrives within `timeout` seconds (None waits forever).
        """

        async def drain() -> dict:
            for _ in range(skip):
                message = await self.recv()
                if message["type"] == expected_type:
                    return message
            raise ProtocolError(f"no '{expected_type}' message within {skip} frames")

        if timeout is None:
            return await drain()
        try:
            return await asyncio.wait_for(drain(), timeout)
        except TimeoutError:
            raise ProtocolError(
                f"timed out after {timeout}s waiting for '{expected_type}'"
            ) from None

    # --- Convenience wrappers for specific protocol messages ---

    async def login(
        self,
        username: str,
        password: str,
        timeout: Optional[float] = DEFAULT_TIMEOUT,
    ) -> dict:
        """Log in and wait for the `welcome` reply.

        Raises `AuthError` if the server sends `error` instead. Failure
        codes include `auth_failed` (bad credentials) and `station_full`
        (M3.1: no free berth at the spawn station to dock into). Raises
        `ProtocolError` if neither reply arrives within `timeout` seconds.
        Other message types (there normally aren't any yet, since the server
        sends no snapshots pre-login) are skipped.

        On success, also stashes `character_id` and `ship_class` (the M2
        embodiment spawned at login) as attributes on the client for
        convenience, alongside returning the full `welcome` dict.
        """
        await self.send({"type": "login", "username": username, "password": password})

        async def drain() -> dict:
            for _ in range(1000):
                message = await self.recv()
                if message["type"] == "welcome":
                    return message
                if message["type"] == "error":
                    raise AuthError(message.get("code"), message.get("message"))
            raise ProtocolError("no 'welcome'/'error' message within 1000 frames")

        if timeout is None:
            welcome = await drain()
        else:
            try:
                welcome = await asyncio.wait_for(drain(), timeout)
            except TimeoutError:
                raise ProtocolError(
                    f"timed out after {timeout}s waiting for 'welcome'/'error'"
                ) from None

        self.character_id = welcome.get("character_id")
        self.ship_class = welcome.get("ship_class")
        return welcome

    async def send_helm(self, rotate: float, thrust: float) -> None:
        """Send helm input. Ignored server-side while docked or pre-login."""
        await self.send({"type": "helm", "rotate": rotate, "thrust": thrust})

    async def dock(self, timeout: Optional[float] = DEFAULT_TIMEOUT) -> dict:
        """Request docking at the nearest station; wait for `dock_result`."""
        await self.send({"type": "dock"})
        return await self.recv_type("dock_result", timeout=timeout)

    async def undock(self, timeout: Optional[float] = DEFAULT_TIMEOUT) -> dict:
        """Request undocking; wait for `dock_result`."""
        await self.send({"type": "undock"})
        return await self.recv_type("dock_result", timeout=timeout)

    async def move(self, dx: float, dy: float) -> None:
        """Send walk intent (M2). Ignored server-side while seated.

        `dx`/`dy` are sent as JSON floats even for whole-number input (e.g.
        `1` becomes `1.0`): the Gleam decoder requires a float and rejects
        a bare int.
        """
        await self.send({"type": "move", "dx": float(dx), "dy": float(dy)})

    async def sit(
        self, console_id: str, timeout: Optional[float] = DEFAULT_TIMEOUT
    ) -> dict:
        """Request to sit at `console_id` (M2); wait for `seat_result`."""
        await self.send({"type": "sit", "console": console_id})
        return await self.recv_type("seat_result", timeout=timeout)

    async def stand(self, timeout: Optional[float] = DEFAULT_TIMEOUT) -> dict:
        """Leave the current seat (M2); wait for `seat_result`."""
        await self.send({"type": "stand"})
        return await self.recv_type("seat_result", timeout=timeout)

    async def buy(
        self, commodity: str, quantity: int, timeout: Optional[float] = DEFAULT_TIMEOUT
    ) -> dict:
        """Buy at the seated broker (M3); wait for `trade_result`.

        `quantity` is sent as a JSON int — the Gleam decoder rejects floats
        here (the inverse of the move/helm float rule).
        """
        await self.send(
            {"type": "buy", "commodity": commodity, "quantity": int(quantity)}
        )
        return await self.recv_type("trade_result", timeout=timeout)

    async def sell(
        self, commodity: str, quantity: int, timeout: Optional[float] = DEFAULT_TIMEOUT
    ) -> dict:
        """Sell at the seated broker (M3); wait for `trade_result`."""
        await self.send(
            {"type": "sell", "commodity": commodity, "quantity": int(quantity)}
        )
        return await self.recv_type("trade_result", timeout=timeout)

    async def get_market(self, timeout: Optional[float] = DEFAULT_TIMEOUT) -> dict:
        """Request the local station's market (M3); wait for `market`.

        Works ashore or docked-aboard. If neither applies the server sends
        `error` with code `no_market` instead, which this call will time out
        waiting on — use recv_type("error") in tests that expect that.
        """
        await self.send({"type": "get_market"})
        return await self.recv_type("market", timeout=timeout)

    async def next_cargo(self, timeout: Optional[float] = DEFAULT_TIMEOUT) -> dict:
        """Wait for the next `cargo` message (M3). Sent at 15 Hz to a
        ship's crew, wherever their bodies are."""
        return await self.recv_type("cargo", timeout=timeout)

    async def next_space(self, timeout: Optional[float] = DEFAULT_TIMEOUT) -> dict:
        """Wait for the next `space` message (M3.1): the plan we should now
        be walking (ship interior while flying, station composite while
        docked), with our own position in its frame under "you"."""
        return await self.recv_type("space", timeout=timeout)

    async def next_walkers(
        self,
        space: Optional[str] = None,
        timeout: Optional[float] = DEFAULT_TIMEOUT,
    ) -> dict:
        """Wait for the next `walkers` message (M3.1), optionally skipping
        until one for `space` ("ship:3" / "station:meridian_highport")
        arrives - stale frames for a previous space can still be buffered
        right after a dock/undock."""
        for _ in range(1000):
            message = await self.recv_type("walkers", timeout=timeout)
            if space is None or message.get("space") == space:
                return message
        raise ProtocolError(f"no walkers for space {space!r}")

    def store_in(self, market: dict, commodity: str) -> Optional[dict]:
        """Find a commodity's store in a `market` message, if present."""
        for store in market.get("stores", []):
            if store.get("commodity") == commodity:
                return store
        return None

    def hold_quantity(self, cargo: dict, commodity: str) -> int:
        """Units of `commodity` in a `cargo` message's hold list."""
        for entry in cargo.get("hold", []):
            if entry.get("commodity") == commodity:
                return int(entry.get("quantity", 0))
        return 0

    async def next_snapshot(self, timeout: Optional[float] = DEFAULT_TIMEOUT) -> dict:
        """Wait for the next `snapshot` message."""
        return await self.recv_type("snapshot", timeout=timeout)

    def ship_in(self, snapshot: dict, ship_id: int) -> Optional[dict]:
        """Find the ship with `ship_id` in a snapshot's ship list, if present."""
        for ship in snapshot.get("ships", []):
            if ship.get("id") == ship_id:
                return ship
        return None

    def character_in(self, walkers: dict, character_id: int) -> Optional[CharacterView]:
        """Find the character with `character_id` in a `walkers` message's
        crew list, as a typed CharacterView."""
        for character in walkers.get("characters", []):
            if character.get("id") == character_id:
                return CharacterView.from_wire(character)
        return None

    async def get_stats(self, timeout: Optional[float] = DEFAULT_TIMEOUT) -> dict:
        """Request server stats and wait for the stats response."""
        await self.send({"type": "get_stats"})
        return await self.recv_type("stats", timeout=timeout)


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
