"""Smoke test for the Godot client's debug automation hook.

This is deliberately a *different kind* of test from test_m1_flight.py: it
drives a real, on-screen Godot client process end to end through
automation_server.gd (see client/scripts/automation_server.gd and
harness/automation.py) instead of talking to the server's WebSocket
protocol directly. It exists to prove the hook itself works -- ping,
dump, key/action injection, screenshot -- not to re-litigate flight
physics, which test_m1_flight.py already covers rigorously and headlessly
at the protocol level.

Needs a real display (it screenshots the viewport) and is slow (real Godot
cold boot), so it's excluded from the default test run -- see pytest.ini's
`-m "not automation"` addopts. Run it explicitly:

    python -m pytest test_automation_smoke.py -v -m automation
"""

from __future__ import annotations

import math
import time

import pytest

from automation import GodotAutomation, launch_client, terminate_client

# Godot cold boot (plus, on this dev machine, a possible
# global_script_class_cache.cfg rescan) can be slow.
CONNECT_TIMEOUT_S = 60.0
STATE_TIMEOUT_S = 20.0
POLL_INTERVAL_S = 0.25
THRUST_DURATION_S = 1.0
# Comfortably large rather than tight: ships spawn docked and undock at the
# station's own rail velocity (13.96-41.89 u/s, phase-dependent -- see
# test_m1_flight.py), so *some* motion is guaranteed within a second even
# before thrust is considered. This only needs to catch "nothing moved at
# all" (e.g. the key/action injection silently doing nothing).
DISPLACEMENT_THRESHOLD_U = 5.0


def _wait_for_state(automation: GodotAutomation, predicate, timeout: float, description: str) -> dict:
    deadline = time.monotonic() + timeout
    last_state: dict = {}
    while time.monotonic() < deadline:
        last_state = automation.dump()
        if predicate(last_state):
            return last_state
        time.sleep(POLL_INTERVAL_S)
    raise AssertionError(f"timed out waiting for {description}; last state: {last_state}")


def _walk_until(automation: GodotAutomation, action: str, predicate, description: str) -> None:
    """Hold a move action until the dumped character position satisfies
    `predicate`, then release it. Polls fast (well under a tile of travel
    at 3 tiles/s) so the stop lands close to the threshold."""
    automation.action(action, True)
    try:
        deadline = time.monotonic() + STATE_TIMEOUT_S
        last: dict = {}
        while time.monotonic() < deadline:
            last = automation.dump().get("character") or {}
            if last and predicate(last):
                return
            time.sleep(0.05)
        raise AssertionError(f"timed out walking ({description}); last character: {last}")
    finally:
        automation.action(action, False)


def _settle_x(automation: GodotAutomation, target_x: float, tol: float = 0.14, tries: int = 60) -> float:
    """Nudge left/right in short fixed taps until the dumped character x is
    within `tol` of `target_x`. A *continuous* move-hold overshoots by ~0.4
    tiles (release latency), which is fatal at the single-tile berth pinch;
    short taps keep per-tap travel bounded so this converges precisely.
    Meant to be run on the wide ship-deck row, before descending the pinch."""
    last = 0.0
    for _ in range(tries):
        char = automation.dump().get("character") or {}
        last = char.get("x", 0.0)
        if abs(last - target_x) <= tol:
            return last
        action = "move_right" if last < target_x else "move_left"
        automation.action(action, True)
        time.sleep(0.03)
        automation.action(action, False)
        time.sleep(0.10)  # let the queued server ticks land in the next dump
    raise AssertionError(f"could not settle x near {target_x}; last x={last}")


@pytest.mark.automation
def test_automation_smoke(server, tmp_path):
    proc = launch_client(["--username=automation_smoke", "--password=pw_automation"])
    automation = GodotAutomation()
    try:
        automation.connect(timeout=CONNECT_TIMEOUT_S)

        assert automation.ping() == {"ok": True, "pong": True}

        state = _wait_for_state(
            automation,
            lambda s: (
                s.get("connection_state") == "CONNECTED"
                and s.get("logged_in") is True
                and isinstance(s.get("ship_id"), int)
                and s.get("ship_id") >= 0
                # ship_id arrives in the welcome; the own ship's row only
                # exists once a snapshot has landed, so wait for that too.
                and s.get("ship_docked") is not None
            ),
            STATE_TIMEOUT_S,
            "client to connect, log in, and see own docked ship in a snapshot",
        )
        assert state["ship_docked"] is not None, "ships spawn docked"
        assert state["status_label"], "status label text should be non-empty once connected"

        # Undock the same way a real player would: SPACE is bound to
        # toggle_dock (physical keycode 32, see project.godot).
        automation.key("SPACE", True)
        automation.key("SPACE", False)

        state = _wait_for_state(
            automation,
            lambda s: s.get("ship_docked") is None,
            STATE_TIMEOUT_S,
            "SPACE to undock the ship",
        )
        assert state["status_label"], "status label text should be non-empty once undocked"
        pos_before = (state["ship_x"], state["ship_y"])

        automation.action("thrust", True)
        time.sleep(THRUST_DURATION_S)
        automation.action("thrust", False)

        state = automation.dump()
        pos_after = (state["ship_x"], state["ship_y"])
        moved = math.hypot(pos_after[0] - pos_before[0], pos_after[1] - pos_before[1])
        assert moved > DISPLACEMENT_THRESHOLD_U, (
            f"expected the ship to have moved after {THRUST_DURATION_S}s of thrust, "
            f"got {moved:.3f}u ({pos_before} -> {pos_after})"
        )

        screenshot_path = tmp_path / "automation_smoke.png"
        automation.screenshot(str(screenshot_path).replace("\\", "/"))
        assert screenshot_path.exists() and screenshot_path.stat().st_size > 0
    finally:
        automation.close()
        terminate_client(proc)


@pytest.mark.automation
def test_walk_ashore_and_screenshot(server, tmp_path):
    """M3.1 stitched interiors: going ashore is now plain walking. Login
    lands the character seated at their own helm in the station composite
    (space "station:meridian_highport"); standing (E) and walking down
    through the airlock onto the concourse floor is ordinary move input --
    there is no `disembark` verb/X action any more. The dump exposes the
    composite `space`/`space_epoch` and the crew `wallet`.

    E is an event-driven action (main.gd's `_unhandled_input`, matched with
    `is_action_pressed`), so -- like SPACE/toggle_dock -- it needs the `key`
    command (press+release). move_* are polled actions like thrust, so
    `action` press/release injection works.
    """
    # A beat before opening a second Godot window in the same session: back
    # to back with test_automation_smoke's client (just force-killed via
    # taskkill), launching immediately can race the GPU/driver context
    # release and the new process dies before even logging its OpenGL init
    # line -- observed locally as automation.connect() succeeding against a
    # stale socket and then an immediate ConnectionResetError on first dump.
    time.sleep(2.0)
    proc = launch_client(["--username=automation_ashore", "--password=pw_automation_ashore"])
    automation = GodotAutomation()
    try:
        automation.connect(timeout=CONNECT_TIMEOUT_S)

        # Login seats the character at their own namespaced helm in the
        # station composite; wait for that seated character (and the space)
        # to show up in the dump before trying to stand out of it.
        state = _wait_for_state(
            automation,
            lambda s: (
                s.get("logged_in") is True
                and s.get("character") is not None
                and s.get("space") == "station:meridian_highport"
            ),
            STATE_TIMEOUT_S,
            "client to log in and land in the station composite, seated",
        )
        assert state["character"]["seat"] is not None, "login seats you at the helm"

        # Stand (E is bound to "interact", physical keycode 69, see
        # project.godot -- toggles stand/sit at whatever console you're at).
        automation.key("E", True)
        automation.key("E", False)
        state = _wait_for_state(
            automation,
            lambda s: s.get("character") is not None and s["character"]["seat"] is None,
            STATE_TIMEOUT_S,
            "E to stand up from the helm",
        )

        # Walk down onto the concourse. The moored ship lies SIDE-ON (nose
        # west, port flank to the station): from the cockpit, the upper
        # corridor runs EAST along the ship to the vertical docking
        # corridor at the waist (18 tiles east of the helm — the berth
        # column), then SOUTH through the port dormer, the 4-tile docking
        # tube and the berth stub onto the concourse floor (composite rows
        # 14..16 regardless of berth; only the column shifts). Plain
        # movement, no disembark verb.
        helm_x = state["character"]["x"]
        _walk_until(
            automation,
            "move_right",
            lambda c: c.get("x", 0.0) >= helm_x + 17.9,
            "east along the upper corridor to the docking corridor",
        )
        _walk_until(
            automation,
            "move_down",
            lambda c: c.get("y", 0.0) >= 15.2,
            "down the docking tube onto the concourse floor",
        )

        # We are ashore on the concourse floor, still in the one station
        # space, and the crew wallet is visible from the cargo feed.
        state = _wait_for_state(
            automation,
            lambda s: (
                s.get("space") == "station:meridian_highport"
                and (s.get("character") or {}).get("y", 0.0) >= 14.5
                and s.get("wallet") == 2000  # starting wallet, m1_system.json
            ),
            STATE_TIMEOUT_S,
            "character to reach the concourse floor with the wallet loaded",
        )
        assert (state["character"] or {})["seat"] is None, "still standing, ashore"

        screenshot_path = tmp_path / "m3_concourse.png"
        automation.screenshot(str(screenshot_path).replace("\\", "/"))
        assert screenshot_path.exists() and screenshot_path.stat().st_size > 0
    finally:
        automation.close()
        terminate_client(proc)
