"""M3.1 integration tests: stitched interiors.

One space, not two: docking grafts the ship's deck onto the station
concourse (airlock to airlock, ids namespaced s{ship_id}:*), everyone in
the composite walks one shared plan, and undocking splits bodies by tile
ownership. Composite geometry cheat-sheet lives in
docs/superpowers/plans/2026-07-16-m3.1-stitched-interiors.md; the walk-leg
math and draining helpers below (_airlock_center_x, _graft_dx,
_wait_for_own_position) mirror test_m3_trade.py's, duplicated per-file
rather than imported -- the same convention test_m2_interior.py follows.
World numbers come from server/worlds/m1_system.json: spawn station
meridian_highport, three berths.
"""

import pytest

from dh_client import AuthError, DHClient

pytestmark = pytest.mark.asyncio

STATION_SPACE = "station:meridian_highport"
CONCOURSE_FLOOR_Y = 7.2  # a y >= here is safely on the concourse floor (rows 6..8)


def _airlock_center_x(graft_dx: int) -> float:
    """Composite x-center of a ship's airlock column: the sparrow spawns at
    ship-local x=5, so the airlock column is graft_dx + 5, center + 0.5."""
    return float(graft_dx + 5) + 0.5


def _graft_dx(space: dict, ship_id: int) -> int:
    """The dx of `ship_id`'s graft in a `space` message (its berth offset)."""
    for graft in space["grafts"]:
        if graft["ship_id"] == ship_id:
            return int(graft["dx"])
    raise AssertionError(f"ship {ship_id} not grafted in space {space.get('space')!r}")


async def _wait_for_own_position(
    client: DHClient,
    space: str,
    predicate,
    max_messages: int = 120,
    strict_space: bool = True,
):
    """Drain `walkers` until our own character's position satisfies
    `predicate`. With `strict_space` (default) every frame must be for
    `space` -- proving no dock/undock swapped us into another space
    mid-walk. 120 messages is 8 s at 15 Hz walkers, several times over the
    longest single leg here (~5 tiles, ~1.7 s of walking at 3 tiles/s)."""
    me = None
    for _ in range(max_messages):
        message = await client.next_walkers()
        if message.get("space") != space:
            if strict_space:
                raise AssertionError(
                    f"walkers space changed to {message.get('space')!r}; "
                    f"expected {space!r} throughout"
                )
            continue
        me = client.character_in(message, client.character_id)
        if me is not None and predicate(me):
            return me
    raise AssertionError(f"character never reached expected position; last: {me}")


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
        # Our ship is grafted at a berth and our seat is namespaced to it.
        grafts = {g["ship_id"]: g for g in space["grafts"]}
        assert ship_id in grafts
        assert space["you"]["seat"] == f"s{ship_id}:helm_main"
        # The composite plan carries both our helm and the concourse broker.
        console_ids = {c["id"] for c in space["plan"]["consoles"]}
        assert f"s{ship_id}:helm_main" in console_ids
        assert "broker_main" in console_ids
    finally:
        await client.close()


async def test_docking_regrafts_everyones_plan(server):
    a, welcome_a, space_a = await _login("m31_resident")
    try:
        epoch_before = space_a["epoch"]
        b, welcome_b, _space_b = await _login("m31_arrival")
        try:
            # b's arrival grafted a second ship: a receives a fresh space
            # with a bumped epoch and b's graft in it.
            space = await a.next_space()
            assert space["epoch"] > epoch_before
            graft_ships = {g["ship_id"] for g in space["grafts"]}
            assert welcome_b["ship_id"] in graft_ships
            assert welcome_a["ship_id"] in graft_ships
        finally:
            await b.close()
    finally:
        await a.close()


async def test_undock_splits_by_tile(server):
    pilot, pilot_welcome, _pilot_login_space = await _login("m31_pilot")
    stayer, stayer_welcome, stayer_login_space = await _login("m31_stayer")
    try:
        # The stayer walks off their own ship onto the concourse floor: east
        # to clear the single-tile airlock pinch (column derived from their
        # own login graft), then south onto the floor -- mirrors
        # test_m3_trade.py's _descend_to_broker legs.
        assert (await stayer.stand())["ok"]
        stayer_airlock_x = _airlock_center_x(
            _graft_dx(stayer_login_space, stayer_welcome["ship_id"])
        )
        await stayer.move(1, 0)
        await _wait_for_own_position(
            stayer, STATION_SPACE, lambda me: me.x >= stayer_airlock_x - 0.1
        )
        await stayer.move(0, 1)
        await _wait_for_own_position(
            stayer, STATION_SPACE, lambda me: me.y >= 7.2
        )
        await stayer.move(0, 0)

        # The pilot undocks: pilot leaves in their own ship space, the
        # stayer stays ashore, crew membership (cargo feed) untouched.
        assert (await pilot.undock())["ok"]
        pilot_space = await pilot.next_space()
        assert pilot_space["space"] == f"ship:{pilot_welcome['ship_id']}"
        assert pilot_space["you"]["seat"] == "helm_main"
        stayer_space = await stayer.next_space()
        assert stayer_space["space"] == STATION_SPACE
        graft_ships = {g["ship_id"] for g in stayer_space["grafts"]}
        assert pilot_welcome["ship_id"] not in graft_ships
        assert stayer_welcome["ship_id"] in graft_ships
    finally:
        await pilot.close()
        await stayer.close()


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
        with pytest.raises(AuthError) as excinfo:
            await overflow.login("m31_overflow", "pw")
        assert excinfo.value.code == "station_full"
        await overflow.close()
    finally:
        for c in clients:
            await c.close()
