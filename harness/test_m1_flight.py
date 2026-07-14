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

TWO_PI = 6.283185307179586  # matches world.gleam's two_pi constant exactly


async def snapshot_after_ticks(client: DHClient, after_tick: int, ticks: int) -> dict:
    """Drain snapshots until one at least `ticks` server ticks past `after_tick`."""
    target = after_tick + ticks
    snapshot = await client.next_snapshot()
    while snapshot["tick"] < target:
        snapshot = await client.next_snapshot()
    return snapshot


def _orbit_position(px: float, py: float, orbit: dict, t: float) -> tuple[float, float]:
    """One rail hop: `orbit` around a parent at (px, py), world.gleam semantics."""
    angle = orbit["phase"] * TWO_PI + TWO_PI * t / orbit["period_s"]
    return (
        px + orbit["radius"] * math.cos(angle),
        py + orbit["radius"] * math.sin(angle),
    )


def station_rail_position(world: dict, station_id: str, t: float) -> tuple[float, float]:
    """A station's analytic rail position at sim time `t`, computed from the
    world document exactly as the server (and a real client) computes it:
    parents chain station -> planet -> star, the star fixed at the origin."""
    bodies = {body["id"]: body for body in world["bodies"]}

    def body_position(body_id: str) -> tuple[float, float]:
        body = bodies[body_id]
        if body["orbit"] is None:
            return (0.0, 0.0)
        if body["parent"] is not None:
            px, py = body_position(body["parent"])
        else:
            px, py = (0.0, 0.0)
        return _orbit_position(px, py, body["orbit"], t)

    station = next(s for s in world["stations"] if s["id"] == station_id)
    px, py = body_position(station["parent"])
    return _orbit_position(px, py, station["orbit"], t)


def rail_relative_displacement(
    world: dict,
    station_id: str,
    dt: float,
    ship1: dict,
    tick1: int,
    ship2: dict,
    tick2: int,
) -> float:
    """A ship's displacement between two snapshots, measured in the moving
    station's frame of reference.

    World-frame displacement is the wrong measure for "did the ship fly?"
    assertions: everything near a station drifts with its rail at
    13.96-41.89 u/s (phase-dependent), which can constructively add to or
    destructively cancel a ~20 u thrust delta depending on uncontrolled
    wall-clock phase at test time. Subtracting the station's analytic
    position at each snapshot's tick removes the drift entirely, leaving
    only the ship's own thrust-driven motion (plus negligible differential
    gravity)."""
    s1x, s1y = station_rail_position(world, station_id, tick1 * dt)
    s2x, s2y = station_rail_position(world, station_id, tick2 * dt)
    return math.hypot(
        (ship2["x"] - s2x) - (ship1["x"] - s1x),
        (ship2["y"] - s2y) - (ship1["y"] - s1y),
    )


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

        # Snapshots generated before the undock took effect may still be
        # queued locally; drain until the ship shows as flying.
        snap1 = await client.next_snapshot()
        while client.ship_in(snap1, ship_id)["docked"] is not None:
            snap1 = await client.next_snapshot()
        ship1 = client.ship_in(snap1, ship_id)
        assert ship1["docked"] is None

        snap2 = await snapshot_after_ticks(client, snap1["tick"], TICK_RATE)
        ship2 = client.ship_in(snap2, ship_id)
        assert ship2["docked"] is None

        # Displacement in the station's frame (drift removed): ~20 u for
        # ~1 s of full thrust, regardless of the station's orbital phase.
        moved = rail_relative_displacement(
            welcome["world"], "meridian_highport", welcome["dt"],
            ship1, snap1["tick"], ship2, snap2["tick"],
        )
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

        # Observe A from B's own snapshot stream. Snapshots generated before
        # the undock took effect may still be queued locally, so drain until
        # A shows as flying (the undock reply already confirmed it happened
        # server-side, so this converges within a couple of frames).
        snap_b1 = await client_b.next_snapshot()
        while client_b.ship_in(snap_b1, ship_a)["docked"] is not None:
            snap_b1 = await client_b.next_snapshot()
        a_in_b1 = client_b.ship_in(snap_b1, ship_a)
        b_in_b1 = client_b.ship_in(snap_b1, ship_b)
        assert a_in_b1["docked"] is None
        assert b_in_b1 is not None

        snap_b2 = await snapshot_after_ticks(client_b, snap_b1["tick"], TICK_RATE)
        a_in_b2 = client_b.ship_in(snap_b2, ship_a)
        b_in_b2 = client_b.ship_in(snap_b2, ship_b)
        assert a_in_b2["docked"] is None

        world = welcome_b["world"]
        dt = welcome_b["dt"]

        # A flew: displacement in the station's frame (drift removed) is
        # ~20 u for ~1 s of full thrust, deterministic regardless of where
        # the station happens to be on its orbit right now.
        moved_a = rail_relative_displacement(
            world, "meridian_highport", dt,
            a_in_b1, snap_b1["tick"], a_in_b2, snap_b2["tick"],
        )
        assert moved_a > 10.0

        # B never touched its controls: it must stay docked, its position
        # pinned exactly to the station's analytic rail position at each
        # snapshot's tick (not merely "moving less than A", which would race
        # A's thrust against phase-dependent station drift).
        for b_ship, snap in ((b_in_b1, snap_b1), (b_in_b2, snap_b2)):
            assert b_ship["docked"] == "meridian_highport"
            sx, sy = station_rail_position(
                world, "meridian_highport", snap["tick"] * dt
            )
            assert b_ship["x"] == pytest.approx(sx, abs=1e-3)
            assert b_ship["y"] == pytest.approx(sy, abs=1e-3)


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
