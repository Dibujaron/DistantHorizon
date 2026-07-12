"""M1 flight-core integration tests: the permanent protocol test harness.

Runs against a real server spawned by the `server` fixture in
`server_fixture.py` (session-scoped: one `gleam run` process for the whole
file). Each test opens its own DHClient connection(s) against it.

Timing note: snapshots arrive at 15 Hz (every 4th tick of a 60 Hz sim).
Tests that need "N seconds later" measure it in server ticks (the `tick`
field on every snapshot), draining the snapshot stream with
`snapshot_after_ticks` rather than sleeping and hoping — a client that
sleeps without reading leaves snapshots queued locally, so the next
`recv()` would return the oldest *queued* snapshot, not the newest
available one. Ticks are the source of truth for "how much sim time has
passed", matching how the server itself reasons about time.
"""

from __future__ import annotations

import asyncio
import math

import pytest

from dh_client import AuthError, DHClient
from server_fixture import server  # noqa: F401  (pytest fixture import)

TICK_RATE = 60  # sim Hz


async def snapshot_after_ticks(client: DHClient, after_tick: int, ticks: int) -> dict:
    """Drain snapshots until one at least `ticks` server ticks past `after_tick`."""
    target = after_tick + ticks
    snapshot = await client.next_snapshot()
    while snapshot["tick"] < target:
        snapshot = await client.next_snapshot()
    return snapshot


@pytest.mark.asyncio
async def test_login_welcome(server):
    async with DHClient(name="t1") as client:
        welcome = await client.login("alice_login", "secret123")

        assert isinstance(welcome["ship_id"], int)
        world = welcome["world"]
        assert len(world["stations"]) == 2
        assert welcome["dt"] == 0.016666666666666666

        snapshot = await client.next_snapshot()
        ship = client.ship_in(snapshot, welcome["ship_id"])
        assert ship is not None
        assert ship["docked"] == "meridian_highport"


@pytest.mark.asyncio
async def test_login_rejected_empty_password(server):
    async with DHClient(name="t2") as client:
        with pytest.raises(AuthError) as exc_info:
            await client.login("bob_login", "")
        assert exc_info.value.code == "auth_failed"


@pytest.mark.asyncio
async def test_undock_and_fly(server):
    async with DHClient(name="t3") as client:
        welcome = await client.login("carol_fly", "pw_carol")
        ship_id = welcome["ship_id"]

        undock_result = await client.undock()
        assert undock_result["ok"] is True

        await client.send_helm(0.0, 1.0)

        snap1 = await client.next_snapshot()
        ship1 = client.ship_in(snap1, ship_id)
        assert ship1 is not None
        assert ship1["docked"] is None

        snap2 = await snapshot_after_ticks(client, snap1["tick"], TICK_RATE)
        ship2 = client.ship_in(snap2, ship_id)
        assert ship2["docked"] is None

        moved = math.hypot(ship2["x"] - ship1["x"], ship2["y"] - ship1["y"])
        assert moved > 10.0

        speed_before_cut = math.hypot(ship2["vx"], ship2["vy"])
        await client.send_helm(0.0, 0.0)

        snap3 = await snapshot_after_ticks(client, snap2["tick"], TICK_RATE // 2)
        ship3 = client.ship_in(snap3, ship_id)
        speed_after_cut = math.hypot(ship3["vx"], ship3["vy"])
        # Thrust off: speed should stay roughly put (gravity is a gentle
        # perturbation, ~1.25 u/s^2 at worst, over half a second).
        assert speed_after_cut == pytest.approx(speed_before_cut, abs=3.0)


@pytest.mark.asyncio
async def test_two_clients_see_each_other_fly(server):
    async with DHClient(name="A") as client_a, DHClient(name="B") as client_b:
        welcome_a = await client_a.login("dana_a", "pw_dana")
        welcome_b = await client_b.login("erin_b", "pw_erin")
        ship_a = welcome_a["ship_id"]
        ship_b = welcome_b["ship_id"]

        snap_a0 = await client_a.next_snapshot()
        snap_b0 = await client_b.next_snapshot()
        assert len(snap_a0["ships"]) == 2
        assert len(snap_b0["ships"]) == 2

        undock_result = await client_a.undock()
        assert undock_result["ok"] is True
        await client_a.send_helm(0.0, 1.0)

        # Observe A from B's own snapshot stream.
        snap_b1 = await client_b.next_snapshot()
        a_in_b1 = client_b.ship_in(snap_b1, ship_a)
        b_in_b1 = client_b.ship_in(snap_b1, ship_b)
        assert a_in_b1 is not None
        assert b_in_b1 is not None

        snap_b2 = await snapshot_after_ticks(client_b, snap_b1["tick"], TICK_RATE)
        a_in_b2 = client_b.ship_in(snap_b2, ship_a)
        b_in_b2 = client_b.ship_in(snap_b2, ship_b)

        assert a_in_b2["docked"] is None
        moved_a = math.hypot(a_in_b2["x"] - a_in_b1["x"], a_in_b2["y"] - a_in_b1["y"])
        assert moved_a > 10.0

        # B never moved its own controls; it should still be docked, its
        # position pinned to (and only drifting with) the station's rail.
        assert b_in_b2["docked"] == "meridian_highport"
        moved_b = math.hypot(b_in_b2["x"] - b_in_b1["x"], b_in_b2["y"] - b_in_b1["y"])
        assert moved_b < moved_a


@pytest.mark.asyncio
async def test_dock_cycle(server):
    async with DHClient(name="t5") as client:
        welcome = await client.login("finn_dock", "pw_finn")
        ship_id = welcome["ship_id"]

        undock_result = await client.undock()
        assert undock_result["ok"] is True

        # Still inside dock_radius, still at station velocity: dock at once.
        dock_result = await client.dock()
        assert dock_result["ok"] is True
        assert dock_result["reason"] is None

        snapshot = await client.next_snapshot()
        ship = client.ship_in(snapshot, ship_id)
        assert ship["docked"] == "meridian_highport"

        second_dock = await client.dock()
        assert second_dock["ok"] is False
        assert second_dock["reason"] == "already_docked"

        undock_result2 = await client.undock()
        assert undock_result2["ok"] is True

        start_snap = await client.next_snapshot()
        await client.send_helm(0.0, 1.0)
        far_snap = await snapshot_after_ticks(client, start_snap["tick"], 3 * TICK_RATE)
        far_ship = client.ship_in(far_snap, ship_id)
        assert far_ship["docked"] is None

        out_of_range = await client.dock()
        assert out_of_range["ok"] is False
        assert out_of_range["reason"] == "out_of_range"


@pytest.mark.asyncio
async def test_prelogin_ignored(server):
    async with DHClient(name="t6") as client:
        # Neither of these should do anything: no login yet.
        await client.send_helm(0.0, 1.0)
        await client.send({"type": "dock"})

        with pytest.raises((asyncio.TimeoutError, TimeoutError)):
            await asyncio.wait_for(client.recv(), timeout=1.0)

        stats = await client.get_stats()
        assert stats["type"] == "stats"
