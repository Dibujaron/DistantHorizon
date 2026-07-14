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
from server_fixture import server  # noqa: F401  (pytest fixture import)

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
