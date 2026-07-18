"""One-shot M3.5 space-layer screenshot driver (not a pytest test).

Boots the real DH server (accept-all auth via the unreachable DATABASE_URL
trick, same as server_fixture.py), launches a real on-screen client with the
automation hook, and captures the frames the vibe pass needs eyeballing:

  1. docked.png   - docked at spawn: station exterior + parked ships
  2. undocked.png - free flight near the station
  3. burn.png     - mid-thrust: the plume is the speedometer
  4. coast.png    - a beat after cutting thrust: plume died, stars drifted

Run (scoop shims on PATH so `gleam` and `godot` resolve):
  $env:Path = "$env:USERPROFILE\\scoop\\shims;$env:Path"
  python harness/shot_m35_space.py
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

from automation import GodotAutomation, launch_client, terminate_client
from server_fixture import (
    HOST, PORT, SERVER_DIR, STARTUP_TIMEOUT_S, UNREACHABLE_DATABASE_URL,
    _kill_process_tree, _port_accepting,
)

OUT_DIR = Path(__file__).resolve().parent / "out"
CONNECT_TIMEOUT_S = 60.0
STATE_TIMEOUT_S = 20.0
POLL_INTERVAL_S = 0.25


def _spawn_server() -> subprocess.Popen:
    if _port_accepting(HOST, PORT):
        raise RuntimeError(f"something is already listening on {HOST}:{PORT}")
    gleam = shutil.which("gleam")
    if gleam is None:
        raise RuntimeError("'gleam' is not on PATH (scoop shims)")
    env = dict(os.environ, DATABASE_URL=UNREACHABLE_DATABASE_URL)
    proc = subprocess.Popen([gleam, "run"], cwd=str(SERVER_DIR), env=env)
    deadline = time.monotonic() + STARTUP_TIMEOUT_S
    while time.monotonic() < deadline:
        if _port_accepting(HOST, PORT):
            return proc
        if proc.poll() is not None:
            raise RuntimeError("server exited during startup")
        time.sleep(0.25)
    _kill_process_tree(proc)
    raise RuntimeError("server did not start accepting connections in time")


def _wait_for(automation: GodotAutomation, predicate, description: str) -> dict:
    deadline = time.monotonic() + STATE_TIMEOUT_S
    last: dict = {}
    while time.monotonic() < deadline:
        last = automation.dump()
        if predicate(last):
            return last
        time.sleep(POLL_INTERVAL_S)
    raise AssertionError(f"timed out waiting for {description}; last: {last}")


def _shot(automation: GodotAutomation, name: str) -> None:
    path = OUT_DIR / name
    automation.screenshot(str(path).replace("\\", "/"))
    print("shot:", path)


def main() -> int:
    OUT_DIR.mkdir(exist_ok=True)
    server = _spawn_server()
    client = None
    automation = GodotAutomation()
    try:
        client = launch_client(["--username=vibe_shots", "--password=pw_vibe"])
        automation.connect(timeout=CONNECT_TIMEOUT_S)
        _wait_for(
            automation,
            lambda s: (s.get("connection_state") == "CONNECTED"
                       and s.get("logged_in") is True
                       and s.get("ship_docked") is not None),
            "login + docked snapshot",
        )
        time.sleep(2.0)  # let sim-time smoothing and sprites settle
        _shot(automation, "m35_space_docked.png")

        automation.key("SPACE", True)
        automation.key("SPACE", False)
        _wait_for(automation, lambda s: s.get("ship_docked") is None, "undock")
        time.sleep(1.0)
        _shot(automation, "m35_space_undocked.png")

        automation.action("thrust", True)
        time.sleep(4.0)  # clear the station so the plume reads on dark space
        _shot(automation, "m35_space_burn.png")
        automation.action("thrust", False)
        time.sleep(1.5)
        _shot(automation, "m35_space_coast.png")
        return 0
    finally:
        automation.close()
        if client is not None:
            terminate_client(client)
        _kill_process_tree(server)


if __name__ == "__main__":
    sys.exit(main())
