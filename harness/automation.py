"""Sync client for the Godot client's debug automation hook.

The hook (`client/scripts/automation_server.gd`) only exists in debug
builds launched with `--automation` on the command line (see DESIGN.md
"Letting Claude see and drive the UI"). It speaks newline-delimited JSON
request/response over a local TCP socket on 127.0.0.1:8486.

This is a *separate* channel from the game's own WebSocket protocol
(`dh_client.py` talks to the DH server on 8484): `GodotAutomation` talks to
a running client *process* itself -- inject input, dump scene/game state,
grab screenshots -- rather than to the server.

Sync (blocking sockets), not asyncio: the tests that use this also manage a
real OS process (the Godot client) and make only a handful of calls each,
so there's no value threading it through the existing asyncio-based
DHClient/pytest-asyncio harness.
"""

from __future__ import annotations

import json
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Optional

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8486

# Per-request timeout once connected.
DEFAULT_TIMEOUT = 10.0
# The client process needs to boot Godot, connect to the game server, log
# in, and reach _ready() on the automation autoload before the control
# socket even exists -- a cold boot (plus, on this dev machine, a stale
# global_script_class_cache.cfg rescan) can take a while.
DEFAULT_CONNECT_TIMEOUT = 45.0

REPO_ROOT = Path(__file__).resolve().parent.parent
CLIENT_DIR = REPO_ROOT / "client"


class AutomationError(Exception):
    """The automation hook returned {"ok": false, ...} or spoke bad protocol."""


class GodotAutomation:
    """Blocking NDJSON client for a running client's automation_server.gd."""

    def __init__(self, host: str = DEFAULT_HOST, port: int = DEFAULT_PORT):
        self.host = host
        self.port = port
        self._sock: Optional[socket.socket] = None
        self._buffer = b""

    def connect(self, timeout: float = DEFAULT_CONNECT_TIMEOUT) -> None:
        """Connect, retrying until the hook's TCP server is listening.

        Raw `connect()` attempts fail with `ConnectionRefusedError` until
        the client process reaches `_ready()` on the automation autoload,
        so this retries on a short interval rather than failing fast.
        """
        deadline = time.monotonic() + timeout
        last_error: Optional[Exception] = None
        while time.monotonic() < deadline:
            try:
                sock = socket.create_connection((self.host, self.port), timeout=2.0)
                sock.settimeout(DEFAULT_TIMEOUT)
                self._sock = sock
                self._buffer = b""
                return
            except OSError as e:
                last_error = e
                time.sleep(0.25)
        raise ConnectionError(
            f"could not connect to automation hook at {self.host}:{self.port} "
            f"within {timeout}s: {last_error}"
        )

    def close(self) -> None:
        if self._sock is not None:
            try:
                self._sock.close()
            finally:
                self._sock = None

    def __enter__(self) -> "GodotAutomation":
        self.connect()
        return self

    def __exit__(self, *exc_info: Any) -> None:
        self.close()

    def _request(self, payload: dict, timeout: Optional[float]) -> dict:
        assert self._sock is not None, "not connected"
        self._sock.settimeout(timeout)
        self._sock.sendall((json.dumps(payload) + "\n").encode("utf-8"))
        return self._read_line()

    def _read_line(self) -> dict:
        assert self._sock is not None, "not connected"
        while b"\n" not in self._buffer:
            chunk = self._sock.recv(65536)
            if not chunk:
                raise ConnectionError("automation hook closed the connection")
            self._buffer += chunk
        line, self._buffer = self._buffer.split(b"\n", 1)
        message = json.loads(line.decode("utf-8"))
        if not isinstance(message, dict):
            raise AutomationError(f"expected a JSON object, got {message!r}")
        return message

    # --- typed wrappers, one per automation_server.gd command ---

    def ping(self, timeout: Optional[float] = DEFAULT_TIMEOUT) -> dict:
        return self._request({"cmd": "ping"}, timeout)

    def screenshot(self, path: str, timeout: Optional[float] = DEFAULT_TIMEOUT) -> dict:
        response = self._request({"cmd": "screenshot", "path": path}, timeout)
        if not response.get("ok"):
            raise AutomationError(f"screenshot failed: {response}")
        return response

    def dump(self, timeout: Optional[float] = DEFAULT_TIMEOUT) -> dict:
        response = self._request({"cmd": "dump"}, timeout)
        if not response.get("ok"):
            raise AutomationError(f"dump failed: {response}")
        return response["state"]

    def action(self, name: str, pressed: bool, timeout: Optional[float] = DEFAULT_TIMEOUT) -> dict:
        response = self._request({"cmd": "action", "action": name, "pressed": pressed}, timeout)
        if not response.get("ok"):
            raise AutomationError(f"action {name!r} failed: {response}")
        return response

    def key(self, keycode: str, pressed: bool, timeout: Optional[float] = DEFAULT_TIMEOUT) -> dict:
        response = self._request({"cmd": "key", "keycode": keycode, "pressed": pressed}, timeout)
        if not response.get("ok"):
            raise AutomationError(f"key {keycode!r} failed: {response}")
        return response


def launch_client(extra_args: Optional[list[str]] = None, automation: bool = True) -> subprocess.Popen:
    """Launch a real Godot client, by default with the automation hook armed.

    Runs `godot --path client -- --automation <extra_args...>`. The
    `--automation` user arg is what makes automation_server.gd start
    listening (it also requires a debug/non-exported build, which running
    via `godot --path ...` always is -- see client/scripts/automation_server.gd).

    Pass `automation=False` to launch a plain client (e.g. to verify the
    control socket does *not* start without the flag).
    """
    godot = shutil.which("godot")
    if godot is None:
        raise RuntimeError(
            "'godot' is not on PATH. On this dev machine, prefix the scoop "
            "shims before running pytest, e.g. (PowerShell):\n"
            '  $env:Path = "$env:USERPROFILE\\scoop\\shims;$env:Path"'
        )
    args = [godot, "--path", str(CLIENT_DIR), "--"]
    if automation:
        args.append("--automation")
    args.extend(extra_args or [])
    return subprocess.Popen(args, cwd=str(CLIENT_DIR))


def terminate_client(proc: subprocess.Popen, timeout: float = 10.0) -> None:
    """Terminate a client process launched by `launch_client`, killing its
    whole process tree (mirrors server_fixture.py's `_kill_process_tree`)."""
    if proc.poll() is not None:
        return
    if sys.platform == "win32":
        subprocess.run(["taskkill", "/F", "/T", "/PID", str(proc.pid)], capture_output=True)
    else:
        proc.terminate()
    try:
        proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=timeout)
