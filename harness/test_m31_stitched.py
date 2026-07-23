"""M3.1 integration tests: stitched interiors.

One space, not two: docking moors the ship's deck onto the station
concourse (airlock to airlock, ids namespaced s{ship_id}:*), everyone in
the composite walks one shared plan, and undocking splits bodies by tile
ownership. Composite geometry cheat-sheet lives in
docs/superpowers/plans/2026-07-16-m3.1-stitched-interiors.md. Cross-deck
walking is driven by the BFS `walk_to_console` driver (walk.py, twin of
server/test/walk.gleam) against the composite plan the server sent -- no
hardcoded composite row/column math, since berth assignment and ship
rotation are never assumed. World numbers come from
server/worlds/m1_system.json: spawn station meridian_highport, three
berths.
"""

import asyncio
import contextlib

import pytest

from dh_client import AuthError, DHClient
from walk import walk_to_console

pytestmark = pytest.mark.asyncio

STATION_SPACE = "station:meridian_highport"


def _mooring_dx(space: dict, ship_id: int) -> int:
    """The dx of `ship_id`'s mooring in a `space` message (its berth offset)."""
    for mooring in space["moorings"]:
        if mooring["ship_id"] == ship_id:
            return int(mooring["dx"])
    raise AssertionError(f"ship {ship_id} not moored in space {space.get('space')!r}")


@contextlib.asynccontextmanager
async def _kept_drained(client: DHClient):
    """Keep `client`'s incoming queue emptied out for the duration of the
    `with` body, discarding whatever arrives -- walkers/snapshots stream to
    every connected client regardless of who's doing something slow, and a
    cross-composite BFS walk on another client (`walk_to_console` can take
    many seconds on a large station) would otherwise let this client's
    unread queue grow past `recv_type`'s 1000-frame skip cap before the
    next explicit read. Twin of test_m2_interior.py's helper of the same
    name; only wrap spans where nothing on `client` is being read for
    real."""
    stop = asyncio.Event()

    async def _drain() -> None:
        while not stop.is_set():
            try:
                await asyncio.wait_for(client.recv(), timeout=0.05)
            except asyncio.TimeoutError:
                continue
            except Exception:
                return

    task = asyncio.create_task(_drain())
    try:
        yield
    finally:
        stop.set()
        task.cancel()
        with contextlib.suppress(asyncio.CancelledError, Exception):
            await task


async def _login(name: str) -> tuple[DHClient, dict, dict]:
    """Connect, log in, and collect the login `space` push."""
    client = DHClient(name=name)
    await client.connect()
    welcome = await client.login(name, "pw")
    space = await client.next_space()
    return client, welcome, space


async def test_login_space_is_the_station_composite(server):
    client, welcome, space = await _login("m31_spawn")
    try:
        ship_id = welcome["ship_id"]
        assert space["space"] == STATION_SPACE
        # Our ship is moored at a berth and our seat is namespaced to it.
        moorings = {g["ship_id"]: g for g in space["moorings"]}
        assert ship_id in moorings
        assert space["you"]["seat"] == f"s{ship_id}:helm"
        # The composite plan carries both our helm and the concourse broker.
        console_ids = {c["id"] for c in space["plan"]["consoles"]}
        assert f"s{ship_id}:helm" in console_ids
        assert any(c["kind"] == "broker" for c in space["plan"]["consoles"])
    finally:
        await client.close()


async def test_docking_remoors_everyones_plan(server):
    a, welcome_a, space_a = await _login("m31_resident")
    try:
        epoch_before = space_a["epoch"]
        b, welcome_b, _space_b = await _login("m31_arrival")
        try:
            # b's arrival moored a second ship: a receives a fresh space
            # with a bumped epoch and b's mooring in it.
            space = await a.next_space()
            assert space["epoch"] > epoch_before
            mooring_ships = {g["ship_id"] for g in space["moorings"]}
            assert welcome_b["ship_id"] in mooring_ships
            assert welcome_a["ship_id"] in mooring_ships
        finally:
            await b.close()
    finally:
        await a.close()


async def test_undock_splits_by_tile(server):
    pilot, pilot_welcome, _pilot_login_space = await _login("m31_pilot")
    try:
        stayer, stayer_welcome, stayer_login_space = await _login("m31_stayer")
        try:
            # The stayer walks off their own ship onto the concourse floor,
            # driven by the BFS driver to a station console (never namespaced
            # to a ship, so reaching it proves they're off *any* ship's
            # moored tiles) rather than any hardcoded airlock/composite math.
            assert (await stayer.stand())["ok"]
            broker_id = next(
                c["id"] for c in stayer_login_space["plan"]["consoles"]
                if c["kind"] == "broker"
            )
            async with _kept_drained(pilot):
                await walk_to_console(
                    stayer, STATION_SPACE, stayer_login_space["plan"], broker_id
                )

            # The pilot undocks: pilot leaves in their own ship space, the
            # stayer stays ashore, crew membership (cargo feed) untouched.
            assert (await pilot.undock())["ok"]
            pilot_space = await pilot.next_space()
            assert pilot_space["space"] == f"ship:{pilot_welcome['ship_id']}"
            assert pilot_space["you"]["seat"] == "helm"
            stayer_space = await stayer.next_space()
            assert stayer_space["space"] == STATION_SPACE
            mooring_ships = {g["ship_id"] for g in stayer_space["moorings"]}
            assert pilot_welcome["ship_id"] not in mooring_ships
            assert stayer_welcome["ship_id"] in mooring_ships
        finally:
            await stayer.close()
    finally:
        await pilot.close()


async def test_walkers_are_scoped_and_epoch_tagged(server):
    a, _wa, space_a = await _login("m31_scope_a")
    try:
        w = await a.next_walkers(STATION_SPACE)
        assert w["epoch"] == space_a["epoch"]
        ids = {c["id"] for c in w["characters"]}
        assert a.character_id in ids
    finally:
        await a.close()


async def test_fourth_login_is_refused_station_full(server):
    """M3.1: Meridian Highport authors three berths; three concurrent
    connections hold them all, so a fourth login is refused wire-level with
    `AuthError.code == "station_full"`."""
    clients = []
    try:
        for i in range(3):
            c, _w, _s = await _login(f"m31_full_{i}")
            clients.append(c)
        overflow = DHClient(name="m31_overflow")
        await overflow.connect()
        try:
            with pytest.raises(AuthError) as excinfo:
                await overflow.login("m31_overflow", "pw")
            assert excinfo.value.code == "station_full"
        finally:
            await overflow.close()
    finally:
        for c in clients:
            await c.close()
