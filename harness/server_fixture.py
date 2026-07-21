"""Session-scoped pytest fixture that builds and runs the real DH server.

Spawns `gleam run` from `server/` as a subprocess for the whole test
session, waits for it to accept connections on 127.0.0.1:<TEST_PORT>
(8585 by default -- see TEST_PORT below), yields, and tears it down
afterwards (killing the whole process tree, since `gleam run` on
Erlang/BEAM spawns a child runtime process).

The server is started with DH_PORT=<TEST_PORT> so it never collides with
a dev/"production" server left running on the default port 8484.

Auth: DATABASE_URL is deliberately pointed at an address nothing is
listening on, rather than left unset. The server's own default
(postgres://postgres@127.0.0.1:5432/dh_dev, see
server/src/dh_server.gleam) is a real, reachable Postgres instance on this
dev machine (scoop-installed, trust auth) with a real `dh_dev` database —
so simply omitting DATABASE_URL would make the server use the real
Postgres-backed login-or-register auth path, not the accept-all fallback.
That would both depend on machine-local Postgres state (breaking on a
clean CI box with no Postgres) and pollute the real dev database with
test accounts on every run. Pointing DATABASE_URL at an address that
refuses connections forces the accept-all fallback deterministically,
everywhere.
"""

from __future__ import annotations

import os
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
SERVER_DIR = REPO_ROOT / "server"
SERVER_LOG_PATH = SERVER_DIR / ".test_server.log"

HOST = "127.0.0.1"
# Dedicated test port so a stray dev/"production" server on the default
# 8484 never collides with (or invalidates) the harness. Overridable via
# DH_PORT for callers that want a different dedicated port.
TEST_PORT = int(os.environ.get("DH_PORT", "8585"))
# Stamp DH_PORT into this process's own environment (a no-op if the caller
# already set it) so anything that reads os.environ["DH_PORT"] at import
# time -- dh_client.py's DEFAULT_URL, in particular -- agrees with the port
# the server fixture actually starts the server on, even when nothing set
# DH_PORT explicitly before pytest ran. conftest.py imports this module
# before collecting test files, so this runs before dh_client is imported.
os.environ["DH_PORT"] = str(TEST_PORT)

# `gleam run` builds the project on first use, which can take a while.
STARTUP_TIMEOUT_S = 60.0

# Refuses all connections immediately (port 1 is a reserved, unassigned
# port on loopback) -- forces dh_server's Postgres pool to fail fast and
# fall back to accept-all auth. See module docstring.
UNREACHABLE_DATABASE_URL = "postgres://nobody:nobody@127.0.0.1:1/nonexistent"


def _port_accepting(host: str, port: int, timeout: float = 0.25) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def _kill_process_tree(proc: subprocess.Popen) -> None:
    if proc.poll() is not None:
        return
    if sys.platform == "win32":
        subprocess.run(
            ["taskkill", "/F", "/T", "/PID", str(proc.pid)],
            capture_output=True,
        )
    else:
        proc.terminate()
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=10)


@pytest.fixture(scope="session")
def server():
    """Spawn a real dh_server for the whole test session.

    Refuses to run if 127.0.0.1:<TEST_PORT> is already accepting
    connections: a stale or shared server would invalidate every test
    result (same principle as benchmark.py's freshness guard).
    """
    if _port_accepting(HOST, TEST_PORT):
        pytest.fail(
            f"{HOST}:{TEST_PORT} is already accepting connections -- a stale "
            "or shared server would invalidate these tests. Find and stop it "
            "first, e.g. on Windows:\n"
            f"  netstat -ano | findstr {TEST_PORT}\n"
            "  taskkill /F /T /PID <pid>"
        )

    gleam = shutil.which("gleam")
    if gleam is None:
        pytest.fail(
            "'gleam' is not on PATH. On this dev machine, prefix the scoop "
            "shims before running pytest, e.g. (PowerShell):\n"
            '  $env:Path = "$env:USERPROFILE\\scoop\\shims;$env:Path"'
        )

    env = dict(os.environ)
    env.pop("DH_WORLD", None)  # use the server's own default world doc
    env["DATABASE_URL"] = UNREACHABLE_DATABASE_URL  # force accept-all; see module docstring
    env["DH_PORT"] = str(TEST_PORT)  # dedicated test port; see module docstring

    log_file = open(SERVER_LOG_PATH, "w", encoding="utf-8")
    proc = subprocess.Popen(
        [gleam, "run"],
        cwd=str(SERVER_DIR),
        env=env,
        stdout=log_file,
        stderr=subprocess.STDOUT,
    )

    deadline = time.monotonic() + STARTUP_TIMEOUT_S
    started = False
    exited_early = False
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            exited_early = True
            break
        if _port_accepting(HOST, TEST_PORT):
            started = True
            break
        time.sleep(0.25)

    if not started:
        _kill_process_tree(proc)
        log_file.close()
        log_tail = SERVER_LOG_PATH.read_text(encoding="utf-8", errors="replace")[-4000:]
        reason = "server process exited early" if exited_early else "timed out waiting for the port"
        pytest.fail(f"failed to start dh_server ({reason}); last log output:\n{log_tail}")

    yield

    _kill_process_tree(proc)
    log_file.close()
