"""Shared pytest fixtures for the harness.

The session-scoped `server` fixture is registered here (and only here).
Importing a fixture into each test module — the pre-M2 arrangement —
registers one FixtureDef per module, and pytest caches session-scoped
fixtures per FixtureDef: with two test modules that means two server
processes, the second of which finds the test port (see
server_fixture.TEST_PORT, 8585 by default) already taken by the first and
fails the run. Registering the fixture once in conftest.py gives the
whole session exactly one server, whichever modules run.
"""

from server_fixture import server  # noqa: F401  (pytest fixture registration)
