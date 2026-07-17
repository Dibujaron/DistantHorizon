"""M3.1 integration tests: trade on foot in the stitched station space.

Exercises the full loop over the wire: from the helm seat, stand and walk
the composite (concourse + docked-ship grafts) to a broker, sit, buy with a
timed robot transfer, watch the hold fill through `cargo` messages, sell it
back, and prove undock is blocked mid-transfer. Under M3.1 there is no
`board`/`disembark` any more: a docked ship's deck and the concourse are one
stitched space, so crossing between them is plain `move` input. Login seats
you at your own namespaced helm in that space already.

World numbers come from server/worlds/m1_system.json: spawn station
meridian_highport, machinery base 55 +/- 4, starting wallet 2000, hold
capacity 40, robot rate 1.0 unit/s, three berths.

Composite geometry (verified by server/test/sim_test.gleam; y-down, tile
units): first login claims berth 0, graft (+1, 0), so the sparrow's helm
tile (1,2) lands at composite center (2.5, 2.5) with seat "s{ship}:helm_main",
and its airlock (spawn tile [5,4]) at composite (6, 4). A ship's airlock
COLUMN in the composite is graft_dx + 5 (sparrow spawn x = 5); its center is
that + 0.5. The concourse floor is composite rows 6..8; broker_main sits at
composite center (10.5, 7.5). Walk legs mirror sim_test.gleam's
`walk_to_broker`: character radius 0.3, so descending the single-tile berth
pinch needs the center at column + 0.4 or more (east of column + 0.4, THEN
south). Walkers stream at 15 Hz, walk speed 3 tiles/s.
"""

import math

import pytest

from dh_client import DHClient

pytestmark = pytest.mark.asyncio

SPAWN_STATION = "meridian_highport"
SPAWN_STATION_SPACE = f"station:{SPAWN_STATION}"
MACHINERY_MIN, MACHINERY_MAX = 51, 59  # base 55, elasticity 4
STARTING_WALLET = 2000

BROKER_CENTER = (10.5, 7.5)  # broker_main: concourse (10,3) grafted to (10,7)
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


async def _login(server, name: str) -> tuple[DHClient, dict]:
    client = DHClient(name=name)
    await client.connect()
    welcome = await client.login(name, "pw")
    return client, welcome


async def _own_position(client: DHClient, space: str, max_messages: int = 120):
    """Drain walkers for `space` until our own character first appears,
    returning its CharacterView."""
    me = None
    for _ in range(max_messages):
        message = await client.next_walkers()
        if message.get("space") != space:
            continue
        me = client.character_in(message, client.character_id)
        if me is not None:
            return me
    raise AssertionError(f"character never appeared in walkers for {space!r}")


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
    mid-walk. Without it, frames for other spaces are skipped (draining
    stale frames buffered across a dock/undock rebuild). 120 messages is 8 s
    at 15 Hz; the longest single leg here is ~5 tiles (~1.7 s of walking)."""
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


async def _descend_to_broker(
    client: DHClient,
    space: str,
    airlock_x: float,
    strict_space: bool = True,
) -> None:
    """From standing on a ship's deck near its airlock column, walk down
    through the airlock and berth stub onto the concourse floor, then along
    the floor to broker_main. Mirrors sim_test.gleam's `walk_to_broker`
    legs: east to center on the airlock column (clearing the single-tile
    pinch), south to the floor, then east/west to the broker column."""
    await client.move(1, 0)
    await _wait_for_own_position(
        client, space, lambda me: me.x >= airlock_x - 0.1, strict_space=strict_space
    )
    await client.move(0, 1)
    await _wait_for_own_position(
        client, space, lambda me: me.y >= CONCOURSE_FLOOR_Y, strict_space=strict_space
    )
    if airlock_x < BROKER_CENTER[0]:
        await client.move(1, 0)
        await _wait_for_own_position(
            client, space, lambda me: me.x >= BROKER_CENTER[0] - 0.1,
            max_messages=200, strict_space=strict_space,
        )
    else:
        await client.move(-1, 0)
        await _wait_for_own_position(
            client, space, lambda me: me.x <= BROKER_CENTER[0] + 0.1,
            max_messages=200, strict_space=strict_space,
        )
    await client.move(0, 0)


async def _walk_to_broker(client: DHClient) -> None:
    """Stand up (login seats you at your own helm) and walk to broker_main
    entirely by move input. Derives the airlock column from our own helm
    position, so it works from any berth."""
    stand = await client.stand()
    assert stand["ok"], stand
    me = await _own_position(client, SPAWN_STATION_SPACE)
    airlock_x = _airlock_center_x(math.floor(me.x) - 1)  # helm col = graft_dx + 1
    await _descend_to_broker(client, SPAWN_STATION_SPACE, airlock_x)


async def _walk_broker_to_helm(client: DHClient) -> None:
    """Reverse of `_descend_to_broker` for a berth-0 character: from the
    concourse floor near the broker back up the airlock column (6) onto the
    deck and west to the helm at (2.5, 2.5)."""
    await client.move(-1, 0)
    await _wait_for_own_position(client, SPAWN_STATION_SPACE, lambda me: me.x <= 6.5)
    await client.move(0, -1)
    await _wait_for_own_position(client, SPAWN_STATION_SPACE, lambda me: me.y <= 2.6)
    await client.move(-1, 0)
    await _wait_for_own_position(client, SPAWN_STATION_SPACE, lambda me: me.x <= 2.6)
    await client.move(0, 0)


async def test_walk_ashore_and_back_is_just_walking(server):
    """M3.1: going ashore is plain walking. Login lands us seated at our own
    namespaced helm in the station composite; we walk to the broker and back
    up onto the ship, and every `walkers` frame the whole time stays the same
    station space -- there is no board/disembark round-trip any more."""
    async with DHClient(name="m31_walker") as client:
        welcome = await client.login("m31_walker", "pw")
        ship_id = welcome["ship_id"]

        space = await client.next_space()
        assert space["space"] == SPAWN_STATION_SPACE
        assert space["you"]["seat"] == f"s{ship_id}:helm_main"

        # Walk to the broker: _walk_to_broker asserts (strict_space) that
        # every walkers frame stayed the station composite.
        await _walk_to_broker(client)
        assert (await client.sit("broker_main"))["ok"]  # we reached the broker tile

        # Walk back up onto the ship and sit at our own helm again -- still
        # one uninterrupted station space, still plain movement.
        stand = await client.stand()
        assert stand["ok"], stand
        await _walk_broker_to_helm(client)
        seated = await client.sit(f"s{ship_id}:helm_main")
        assert seated["ok"], seated
        assert seated["seat"] == f"s{ship_id}:helm_main"


async def test_market_visible_while_docked_aboard(server):
    async with DHClient(name="m3_browser") as client:
        await client.login("m3_browser", "pw")
        market = await client.get_market()
        assert market["station_id"] == SPAWN_STATION
        machinery = client.store_in(market, "machinery")
        assert machinery is not None
        assert machinery["name"] == "Machinery"
        assert MACHINERY_MIN <= machinery["price"] <= MACHINERY_MAX
        assert machinery["quantity"] > 0
        assert len(market["stores"]) == 4


async def test_buy_delivers_over_time(server):
    async with DHClient(name="m3_buyer") as client:
        await client.login("m3_buyer", "pw")
        await _walk_to_broker(client)
        sit = await client.sit("broker_main")
        assert sit["ok"], sit

        trade = await client.buy("machinery", 3)
        assert trade["ok"], trade
        assert trade["quantity"] == 3
        price = trade["price"]
        assert MACHINERY_MIN <= price <= MACHINERY_MAX

        # Wallet debited up front; goods arrive over ~3 s (1 unit/s). Skip
        # any cargo buffered before the debit landed.
        cargo = await client.next_cargo()
        for _ in range(120):
            if cargo["wallet"] != STARTING_WALLET:
                break
            cargo = await client.next_cargo()
        assert cargo["wallet"] == STARTING_WALLET - 3 * price
        for _ in range(120):  # 120 messages at 15 Hz ~= 8 s budget
            if client.hold_quantity(cargo, "machinery") == 3 and not cargo["transfers"]:
                break
            cargo = await client.next_cargo()
        assert client.hold_quantity(cargo, "machinery") == 3
        assert cargo["transfers"] == []
        assert cargo["capacity"] == 40


async def test_sell_pays_on_delivery(server):
    async with DHClient(name="m3_seller") as client:
        await client.login("m3_seller", "pw")
        await _walk_to_broker(client)
        assert (await client.sit("broker_main"))["ok"]

        buy = await client.buy("machinery", 2)
        assert buy["ok"], buy
        cargo = await client.next_cargo()
        for _ in range(120):
            if client.hold_quantity(cargo, "machinery") == 2 and not cargo["transfers"]:
                break
            cargo = await client.next_cargo()

        sell = await client.sell("machinery", 2)
        assert sell["ok"], sell
        expected = STARTING_WALLET - 2 * buy["price"] + 2 * sell["price"]
        for _ in range(120):
            cargo = await client.next_cargo()
            if cargo["wallet"] == expected and not cargo["hold"]:
                break
        assert cargo["wallet"] == expected
        assert cargo["hold"] == []


async def test_trade_validation_reasons(server):
    async with DHClient(name="m3_rules") as client:
        await client.login("m3_rules", "pw")

        # Seated at the helm (not a broker): no.
        trade = await client.buy("machinery", 1)
        assert not trade["ok"] and trade["reason"] == "not_at_broker"

        await _walk_to_broker(client)
        # Standing on the concourse near the broker, but not seated: still no.
        trade = await client.buy("machinery", 1)
        assert not trade["ok"] and trade["reason"] == "not_at_broker"

        assert (await client.sit("broker_main"))["ok"]
        checks = [
            (await client.buy("unobtainium", 1), "not_sold_here"),
            (await client.buy("machinery", 100), "insufficient_stock"),
            (await client.buy("machinery", 0), "invalid_quantity"),
            # 45 fits stock (60) but not the 40-unit hold.
            (await client.buy("machinery", 45), "insufficient_hold"),
            (await client.sell("machinery", 5), "insufficient_cargo"),
        ]
        for result, reason in checks:
            assert not result["ok"] and result["reason"] == reason, (result, reason)

        # insufficient_funds, price-independent: luxuries (base 78,
        # elasticity 5 -> price >= 73) has only 20 units of stock, so
        # buying all of it costs at least 20*73 = 1460; a follow-up 19
        # units of machinery costs at least 19*51 = 969. The pair (39
        # units, well under the 40 capacity) always totals >= 2429, over
        # the starting wallet of 2000, so the second buy always fails on
        # funds regardless of where prices land within their ranges.
        first = await client.buy("luxuries", 20)
        assert first["ok"], first
        second = await client.buy("machinery", 19)
        assert not second["ok"] and second["reason"] == "insufficient_funds", second


async def test_pilot_holds_helm_while_quartermaster_trades(server):
    """M3.1 exit criterion: a quartermaster shanghais onto the pilot's ship,
    the pilot undocks and RE-DOCKS (the crew-join re-graft path, which has no
    server-side test of its own), then the qm trades ashore while the pilot
    holds the helm; undock is blocked until the robots finish."""
    pilot, pilot_welcome = await _login(server, "m31_pilot")
    qm, qm_welcome = await _login(server, "m31_qm")
    pilot_ship = pilot_welcome["ship_id"]
    qm_ship = qm_welcome["ship_id"]
    try:
        # Both spawn docked (pilot berth 0, qm berth 1). Their login `space`
        # messages carry the grafts we drive the walk legs from.
        pilot_space = await pilot.next_space()
        assert pilot_space["space"] == SPAWN_STATION_SPACE
        qm_space = await qm.next_space()
        assert qm_space["space"] == SPAWN_STATION_SPACE
        qm_own_airlock = _airlock_center_x(_graft_dx(qm_space, qm_ship))
        pilot_airlock = _airlock_center_x(_graft_dx(pilot_space, pilot_ship))

        # The qm stands and walks off her own deck, along the concourse, and
        # up onto the pilot's deck (down her airlock column, west along the
        # floor, north onto the pilot's ship tiles).
        stand = await qm.stand()
        assert stand["ok"], stand
        await qm.move(1, 0)
        await _wait_for_own_position(
            qm, SPAWN_STATION_SPACE, lambda me: me.x >= qm_own_airlock - 0.1
        )
        await qm.move(0, 1)
        await _wait_for_own_position(
            qm, SPAWN_STATION_SPACE, lambda me: me.y >= CONCOURSE_FLOOR_Y
        )
        await qm.move(-1, 0)
        await _wait_for_own_position(
            qm, SPAWN_STATION_SPACE, lambda me: me.x <= pilot_airlock, max_messages=200
        )
        await qm.move(0, -1)
        await _wait_for_own_position(
            qm, SPAWN_STATION_SPACE, lambda me: me.y <= 3.6
        )
        await qm.move(0, 0)

        # The pilot undocks: the qm stands on the pilot's tiles, so she is
        # carried off as the pilot's crew (shanghai); her old ship, now
        # crewless, despawns. Pilot + qm now share the pilot's ship space.
        undock = await pilot.undock()
        assert undock["ok"], undock

        # The pilot re-docks -- the crew-join re-graft path. dock()'s
        # dock_result drains the stale ship `space` buffered from the undock,
        # so the next `space` is the station composite the redock rebuilt.
        redock = await pilot.dock()
        assert redock["ok"], redock
        pilot_redock_space = await pilot.next_space()
        assert pilot_redock_space["space"] == SPAWN_STATION_SPACE
        # The pilot's helm seat is re-namespaced back to the ship on the join.
        assert pilot_redock_space["you"]["seat"] == f"s{pilot_ship}:helm_main"
        # Berth is the lowest free index -- derive the graft, never hardcode.
        redock_dx = _graft_dx(pilot_redock_space, pilot_ship)
        redock_airlock = _airlock_center_x(redock_dx)

        # Both bodies re-enter the station space's walkers on the redock.
        both = {pilot.character_id, qm.character_id}
        for _ in range(200):
            frame = await pilot.next_walkers()
            if frame.get("space") != SPAWN_STATION_SPACE:
                continue
            if both <= {c["id"] for c in frame["characters"]}:
                break
        else:
            raise AssertionError("both bodies never re-appeared in station walkers")

        # The qm (standing on the re-grafted deck) walks to the broker; stale
        # ship-space frames from the flight are drained (strict_space=False).
        await _descend_to_broker(
            qm, SPAWN_STATION_SPACE, redock_airlock, strict_space=False
        )
        assert (await qm.sit("broker_main"))["ok"]

        buy = await qm.buy("machinery", 8)
        assert buy["ok"], buy

        # The pilot (back at the helm) cannot leave mid-load.
        blocked = await pilot.undock()
        assert not blocked["ok"]
        assert blocked["reason"] == "transfer_in_progress"

        # The qm is crew, so cargo reaches her ashore.
        cargo = await qm.next_cargo()
        for _ in range(240):  # 8 s load + headroom at 15 Hz
            if qm.hold_quantity(cargo, "machinery") == 8 and not cargo["transfers"]:
                break
            cargo = await qm.next_cargo()
        assert qm.hold_quantity(cargo, "machinery") == 8

        released = await pilot.undock()
        assert released["ok"], released
    finally:
        await pilot.close()
        await qm.close()
