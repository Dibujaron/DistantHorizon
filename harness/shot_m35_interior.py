"""One-shot M3.5 on-foot-layer screenshot driver (not a pytest test).

Same boot recipe as shot_m35_space.py; captures the interior frames:

  1. seated.png    - login seat at the helm: deck + concourse, THE WINDOW
  2. concourse.png - ashore on the concourse floor (digits, hazards, crew)
  3. viewcone.png  - same spot with the V view-cone layer on
  4. flying.png    - standing in the hold mid-flight: stars streaming past

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

        # Stand and walk ashore (same route as the M3.1 smoke test).
        helm_x = state["character"]["x"]
        airlock_x = helm_x + 4.0
        automation.key("E", True)
        automation.key("E", False)
        _wait_for(automation,
                  lambda s: (s.get("character") or {}).get("seat") is None,
                  "E to stand")
        _walk_until(automation, "move_right",
                    lambda c: c.get("x", 0.0) >= helm_x + 3.0,
                    "east along the ship deck")
        _settle_x(automation, airlock_x)
        _walk_until(automation, "move_down",
                    lambda c: c.get("y", 0.0) >= 6.5,
                    "south onto the concourse")
        time.sleep(0.5)
        _shot(automation, "m35_int_concourse.png")

        # View-cone prototype on, shot, off again.
        automation.key("V", True)
        automation.key("V", False)
        time.sleep(0.3)
        _shot(automation, "m35_int_viewcone.png")
        automation.key("V", True)
        automation.key("V", False)

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
