"""M4 module engine: refit a docked ship and watch the resolved plan change.

The engine's whole promise is that a loadout swap is a real change to the
deck the server serves, not a cosmetic label -- so these assertions read the
deck plan on the wire before and after, not a module list.

The fixture hull (harness/fixtures/test_fixture.json) carries one slot,
"bay" (SW-corner digit 1), on an otherwise-plain floor tile at Main deck
(x=4, y=2). `server/modules/test_fixture/bunkroom.json` overlays that single
tile with a bed ("d") when fitted; the hull's own default loadout leaves the
bay empty, so a fresh login shows a bare floor tile there.

Refit replaces the WHOLE loadout, so every request below re-states the
fixture's one engine part (`rijay.engine.consol_patch` on `engine_center`)
even when the point of the request is the module slot -- omitting it would
fail on `tag_deficit:engine` before the module handling is even exercised.
"""

from __future__ import annotations

import pytest

from dh_client import DHClient, ProtocolError

pytestmark = pytest.mark.asyncio

SPAWN_STATION = "meridian_highport"
SPAWN_STATION_SPACE = f"station:{SPAWN_STATION}"

BAY_SLOT = "bay"
BUNKROOM_MODULE = "test_fixture.bay.bunkroom"
ENGINE_MOUNT = "engine_center"
ENGINE_PART = "rijay.engine.consol_patch"
DEFAULT_PARTS = [{"mount": ENGINE_MOUNT, "part": ENGINE_PART}]
BUNKROOM_MODULES = [{"slot": BAY_SLOT, "module": BUNKROOM_MODULE}]

# The bay's single tile, in (x, y) tile units on Main deck (deck 0).
PATCHED_TILE = (4, 2)


async def _refit(client: DHClient, modules: list[dict], parts: list[dict]) -> dict:
    """Send a `refit` and wait for its `refit_result` -- no wrapper exists on
    DHClient for this verb yet, so this mirrors what every other convenience
    method there does internally (send, then recv_type the matching reply)."""
    await client.send({"type": "refit", "modules": modules, "parts": parts})
    return await client.recv_type("refit_result")


async def _refused_no_ship_fit(client: DHClient) -> None:
    """A refused refit must never be followed by a `ship_fit` -- that message
    is the only channel a changed plan travels over, so its absence is the
    proof nothing was committed. A short timeout is enough: on a flying or
    idle-docked ship, snapshots keep streaming regardless, so this isn't
    racing an otherwise-silent connection."""
    with pytest.raises(ProtocolError):
        await client.recv_type("ship_fit", timeout=1.5)


def _center_char(ship_class: dict, deck: int, x: int, y: int) -> str:
    """The centre glyph of tile (x, y) on `deck`'s grid, v3 3x3-per-tile
    format (server/src/dh_server/deckplan.gleam)."""
    grid = ship_class["decks"][deck]["grid"]
    return grid[3 * y + 1][3 * x + 1]


async def test_welcome_carries_flight_stats(server):
    """The fixture hull is pinned to resolve at exactly 40.0 accel / 180.0
    turn_rate with its default loadout (mass 120, the one engine's 4800
    thrust / 21600 torque) -- the same numbers a Gleam-level test pins
    server-side. Proving welcome carries them over the wire is the
    prerequisite for every later assertion in this file: if flight stats
    didn't parse off the socket, a refit's resolved-class push wouldn't
    either."""
    async with DHClient(name="m4_flight") as client:
        welcome = await client.login("m4_flight_stats", "pw")
        flight = welcome["ship_class"]["flight"]
        assert flight["accel"] == pytest.approx(40.0)
        assert flight["turn_rate"] == pytest.approx(180.0)


async def test_refit_installs_a_module(server):
    """Fit the bunkroom into the bay: `refit_result.ok` alone never proves
    the bake ran -- the resolved `ship_class` in the following `ship_fit`
    has to actually carry the module's patch. This reads the patched tile's
    centre glyph before and after (floor -> bed), and additionally checks no
    OTHER tile's grid text moved, so the assertion can't pass on some
    unrelated deck-wide change."""
    async with DHClient(name="m4_install") as client:
        welcome = await client.login("m4_install_bay", "pw")
        ship_id = welcome["ship_id"]
        original_class = welcome["ship_class"]

        # Sanity on the fixture itself: bare bay is empty floor pre-refit.
        assert _center_char(original_class, 0, *PATCHED_TILE) == " "

        result = await _refit(client, BUNKROOM_MODULES, DEFAULT_PARTS)
        assert result["ok"] is True, result
        assert result["reason"] is None

        fit = await client.recv_type("ship_fit")
        assert fit["ship_id"] == ship_id
        new_class = fit["ship_class"]

        # The bunkroom's patch is `[" d ", ...]` centred on the bay tile --
        # its bed glyph ("d") must now sit where plain floor (" ") did.
        assert _center_char(new_class, 0, *PATCHED_TILE) == "d"

        # And nothing outside that one tile's 3x3 block (minus its SW
        # corner, which loadout.gleam's stamp never overwrites -- it's the
        # hull's own slot digit) changed at all.
        old_rows = original_class["decks"][0]["grid"]
        new_rows = new_class["decks"][0]["grid"]
        diffs = {
            (r, c)
            for r, (old_row, new_row) in enumerate(zip(old_rows, new_rows))
            for c, (old_ch, new_ch) in enumerate(zip(old_row, new_row))
            if old_ch != new_ch
        }
        tx, ty = PATCHED_TILE
        allowed = {
            (3 * ty + dr, 3 * tx + dc)
            for dr in range(3)
            for dc in range(3)
            if (dr, dc) != (2, 0)  # SW corner: hull-owned slot digit
        }
        assert diffs, "refit changed nothing at all"
        assert diffs <= allowed, diffs - allowed

        # The composite rebuild that stamps the new plan in also fans a
        # fresh `space` to everyone in it.
        space = await client.next_space()
        assert space["space"] == SPAWN_STATION_SPACE


async def test_refit_while_flying_is_refused(server):
    """Refit is docked-only. Undocking first, the same fit that would
    succeed at the berth must come back `not_docked`, and -- because a
    refused refit never commits -- no `ship_fit` may follow it."""
    async with DHClient(name="m4_flying") as client:
        await client.login("m4_no_dock_refit", "pw")
        undocked = await client.undock()
        assert undocked["ok"] is True, undocked

        result = await _refit(client, BUNKROOM_MODULES, DEFAULT_PARTS)
        assert result["ok"] is False
        assert result["reason"] == "not_docked"

        await _refused_no_ship_fit(client)


async def test_refit_with_unknown_module_is_refused(server):
    """An unrecognised module id is refused with `unknown_module:<id>`, not
    committed, and doesn't even partially land: a follow-up refit that just
    reasserts the hull's own default loadout (empty bay, the stock engine)
    resolves to EXACTLY the welcome-time plan, proving the bad attempt left
    the fit untouched rather than corrupting it."""
    async with DHClient(name="m4_unknown") as client:
        welcome = await client.login("m4_bad_module", "pw")
        original_class = welcome["ship_class"]

        result = await _refit(
            client, [{"slot": BAY_SLOT, "module": "nope"}], DEFAULT_PARTS
        )
        assert result["ok"] is False
        assert result["reason"] == "unknown_module:nope"

        await _refused_no_ship_fit(client)

        confirm = await _refit(client, [], DEFAULT_PARTS)
        assert confirm["ok"] is True, confirm
        fit = await client.recv_type("ship_fit")
        assert fit["ship_class"]["decks"] == original_class["decks"]
