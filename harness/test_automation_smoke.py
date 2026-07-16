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
    """M3: stand from the helm (E) and step ashore (X); the state dump
    should pick up the concourse (station_id, wallet) via NetworkClient's
    concourse_received/cargo_received signals, mirroring how
    test_automation_smoke above proves undock+thrust via toggle_dock.

    E and X are event-driven actions (see main.gd's `_unhandled_input`,
    matched with `is_action_pressed`), so -- like SPACE/toggle_dock above --
    they need the `key` command (press+release pair), not `action`.
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

        # Login seats the character at the helm, same as test_automation_smoke;
        # wait for that seated character to show up in the dump before
        # trying to stand out of it.
        state = _wait_for_state(
            automation,
            lambda s: s.get("logged_in") is True and s.get("character") is not None,
            STATE_TIMEOUT_S,
            "client to log in and see own seated character",
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

        # Step ashore (X is bound to "disembark", physical keycode 88).
        # Disembarking triggers main.gd's interior/exterior transition
        # animation, so wait for that to settle (view_mode leaves
        # "transition") as well as for the station_id to land, or this can
        # observe a moment where we're ashore but still mid-transition.
        automation.key("X", True)
        automation.key("X", False)
        state = _wait_for_state(
            automation,
            lambda s: (
                s.get("station_id") == "meridian_highport"
                and s.get("view_mode") == "interior"
            ),
            STATE_TIMEOUT_S,
            "X to disembark onto the concourse and the transition to settle",
        )

        assert state["view_mode"] == "interior"
        # Starting wallet from server/worlds/m1_system.json (see test_m3_trade.py).
        assert state["wallet"] == 2000

        screenshot_path = tmp_path / "m3_concourse.png"
        automation.screenshot(str(screenshot_path).replace("\\", "/"))
        assert screenshot_path.exists() and screenshot_path.stat().st_size > 0
    finally:
        automation.close()
        terminate_client(proc)
