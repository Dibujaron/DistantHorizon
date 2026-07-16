"""M3 integration tests: trade on foot.

Exercises the full loop over the wire: walk off the docked ship onto the
station concourse, sit at a broker, buy with a timed robot transfer, watch
the hold fill through `cargo` messages, sell it back, and prove undock is
blocked mid-transfer. World numbers come from server/worlds/m1_system.json:
spawn station meridian_highport, concourse spawn [4,4] exactly 1.0 tiles
from broker_main, machinery base 55 +/- 4, starting wallet 2000, hold
capacity 40, robot rate 1.0 unit/s.
"""

import asyncio

import pytest

from dh_client import DHClient

pytestmark = pytest.mark.asyncio

SPAWN_STATION = "meridian_highport"
MACHINERY_MIN, MACHINERY_MAX = 51, 59  # base 55, elasticity 4
STARTING_WALLET = 2000


async def _login(server, name: str) -> tuple[DHClient, dict]:
    client = DHClient(name=name)
    await client.connect()
    welcome = await client.login(name, "pw")
    return client, welcome


async def _go_ashore(client: DHClient) -> dict:
    """Stand up (login seats you at the helm) and walk off the ship."""
    stand = await client.stand()
    assert stand["ok"], stand
    result = await client.disembark()
    assert result["ok"], result
    assert result["station_id"] == SPAWN_STATION
    return result


async def test_disembark_walk_and_return(server):
    async with DHClient(name="m3_walker") as client:
        welcome = await client.login("m3_walker", "pw")
        ship_id = welcome["ship_id"]
        await _go_ashore(client)

        # We appear in the concourse feed, standing at the spawn tile.
        concourse = await client.next_concourse()
        assert concourse["station_id"] == SPAWN_STATION
        me = client.character_in(concourse, client.character_id)
        assert me is not None
        assert me["seat"] is None
        assert (me["x"], me["y"]) == (4.5, 4.5)

        # Walk one tile up (into the concourse proper) and stop.
        await client.move(0, -1)
        await asyncio.sleep(0.5)
        await client.move(0, 0)
        moved = await client.next_concourse()
        me = client.character_in(moved, client.character_id)
        assert me["y"] < 4.5

        # Board our own ship back; we land at the ship spawn tile.
        board = await client.board(ship_id)
        assert board["ok"], board
        assert board["ship_id"] == ship_id
        interior = await client.next_interior()
        me = client.character_in(interior, client.character_id)
        assert me is not None
        assert (me["x"], me["y"]) == (5.5, 4.5)


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
        await _go_ashore(client)
        sit = await client.sit("broker_main")
        assert sit["ok"], sit

        trade = await client.buy("machinery", 3)
        assert trade["ok"], trade
        assert trade["quantity"] == 3
        price = trade["price"]
        assert MACHINERY_MIN <= price <= MACHINERY_MAX

        # Wallet debited up front; goods arrive over ~3 s (1 unit/s).
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
        await _go_ashore(client)
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

        # Aboard: not at a broker.
        trade = await client.buy("machinery", 1)
        assert not trade["ok"] and trade["reason"] == "not_at_broker"

        await _go_ashore(client)
        # Standing on the concourse: still not seated at a broker.
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
    """M3 exit criterion: one crew member buys on the concourse while the
    pilot sits at the helm; undock is blocked until the robots finish."""
    pilot, pilot_welcome = await _login(server, "m3_pilot")
    qm, _qm_welcome = await _login(server, "m3_qm")
    try:
        # The quartermaster crews the pilot's ship (both spawn docked at
        # Meridian Highport), then goes ashore to the broker.
        board = await qm.board(pilot_welcome["ship_id"])
        assert board["ok"], board
        ashore = await qm.disembark()
        assert ashore["ok"], ashore
        assert (await qm.sit("broker_main"))["ok"]

        buy = await qm.buy("machinery", 8)
        assert buy["ok"], buy

        # The pilot (seated at the helm since login) cannot leave mid-load.
        blocked = await pilot.undock()
        assert not blocked["ok"]
        assert blocked["reason"] == "transfer_in_progress"

        # The quartermaster is crew, so cargo reaches them ashore.
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
