"""One-shot M3.5 on-foot-layer screenshot driver (not a pytest test).

Same boot recipe as shot_m35_space.py; captures the interior frames:

  1. seated.png    - login seat at the helm: deck + concourse, THE WINDOW
  2. upper.png     - standing in the mess (upper deck), hull backdrop
  3. lower.png     - the hold (lower deck) via the port half-flight
  4. concourse.png - ashore on the concourse floor (digits, hazards, crew)
  5. flying.png    - standing aboard mid-flight: stars streaming past

Run (scoop shims on PATH):
  python harness/shot_m35_interior.py
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

from automation import GodotAutomation, launch_client, terminate_client
from shot_m35_space import _shot, _spawn_server, _wait_for
from server_fixture import _kill_process_tree
from test_automation_smoke import _settle_x, _walk_until

OUT_DIR = Path(__file__).resolve().parent / "out"
CONNECT_TIMEOUT_S = 60.0


def main() -> int:
    OUT_DIR.mkdir(exist_ok=True)
    server = _spawn_server()
    client = None
    automation = GodotAutomation()
    try:
        client = launch_client(["--username=vibe_foot", "--password=pw_foot"])
        automation.connect(timeout=CONNECT_TIMEOUT_S)
        state = _wait_for(
            automation,
            lambda s: (s.get("logged_in") is True
                       and s.get("character") is not None
                       and s.get("space") == "station:meridian_highport"),
            "login, seated at the helm in the station composite",
        )
        time.sleep(2.0)
        _shot(automation, "m35_int_seated.png")

        # Stand and walk ashore (same route as the smoke test). The moored
        # ship lies SIDE-ON: east along the upper corridor, then south down
        # the docking tube. Grab a mid-ship frame on the way, and detour
        # into the hold via the port half-flight beside the corridor
        # (split-level: the deck flips).
        helm_x = state["character"]["x"]
        automation.key("E", True)
        automation.key("E", False)
        _wait_for(automation,
                  lambda s: (s.get("character") or {}).get("seat") is None,
                  "E to stand")
        _walk_until(automation, "move_right",
                    lambda c: c.get("x", 0.0) >= helm_x + 8.0,
                    "east along the upper corridor (mess overhead run)")
        time.sleep(0.3)
        _shot(automation, "m35_int_upper.png")
        _walk_until(automation, "move_right",
                    lambda c: c.get("x", 0.0) >= helm_x + 18.9,
                    "east to the docking corridor at the waist")
        _walk_until(automation, "move_down",
                    lambda c: c.get("y", 0.0) >= 8.2,
                    "south to the port dormer")
        # West off the corridor onto the 'L' half-flight: deck flips LOWER.
        _walk_until(automation, "move_left",
                    lambda c: c.get("x", 0.0) <= helm_x + 10.1,
                    "west into the hold (lower deck)")
        time.sleep(0.3)
        _shot(automation, "m35_int_lower.png")
        _walk_until(automation, "move_right",
                    lambda c: c.get("x", 0.0) >= helm_x + 18.9,
                    "back east to the docking corridor")
        _walk_until(automation, "move_down",
                    lambda c: c.get("y", 0.0) >= 14.2,
                    "down the docking tube onto the concourse")
        time.sleep(0.5)
        _shot(automation, "m35_int_concourse.png")

        # The flying hold: a fresh login seats us straight at the helm
        # (walking back through the berth pinch is fiddly; a relogin isn't).
        automation.close()
        terminate_client(client)
        client = None
        time.sleep(2.0)  # GPU context release beat (see smoke test note)
        client = launch_client(["--username=vibe_fly", "--password=pw_fly"])
        automation = GodotAutomation()
        automation.connect(timeout=CONNECT_TIMEOUT_S)
        _wait_for(automation,
                  lambda s: (s.get("logged_in") is True
                             and (s.get("character") or {}).get("seat") is not None
                             and s.get("ship_docked") is not None),
                  "second login, seated at the helm, docked")
        automation.key("SPACE", True)
        automation.key("SPACE", False)
        _wait_for(automation, lambda s: s.get("ship_docked") is None, "undock")
        automation.action("thrust", True)
        time.sleep(2.0)
        automation.action("thrust", False)
        automation.key("E", True)
        automation.key("E", False)
        _wait_for(automation,
                  lambda s: (s.get("character") or {}).get("seat") is None,
                  "E to stand mid-flight")
        time.sleep(0.5)
        _shot(automation, "m35_int_flying.png")
        return 0
    finally:
        automation.close()
        if client is not None:
            terminate_client(client)
        _kill_process_tree(server)


if __name__ == "__main__":
    sys.exit(main())
