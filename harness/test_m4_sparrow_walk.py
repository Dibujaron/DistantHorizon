"""Walk the real Sparrow hull (Task 9, iteration 2b) bow to stern.

Every other harness test walks the synthetic single-slot fixture hull
(harness/fixtures/test_fixture.json). This is the one exception: it points
`DH_SHIP_CLASS` straight at `server/shipclasses/sparrow.json`, over its own
`sparrow_server` fixture (server_fixture.py, a second `gleam run` process on
a second port -- DH_SHIP_CLASS is fixed for a server's whole lifetime, and
every other harness test needs the fixture hull's known shape), and drives a
character the length of her: cockpit, the unmarked corridor between cockpit
and bay, both pallet rows of the bay, to a dock port on her sternmost row,
hard against her stern cap.

Issue #33's walk driver (walk.py + deckplan.py) was written and proven only
against the Mockingbird's three decks. The Sparrow is the first *shipped*
single-deck hull it has ever walked -- every deck-linking rule the driver
(and the server behind it) carries was written looking at a three-deck ship,
so this is the harness half of the same anti-overfit check iteration 2b ran
in Gleam.

The walk is driven as ONE continuous `walk_to_console` call, helm straight to
a dock port, not staged through the cargo console as an intermediate stop --
that matters, not just style. `walk.py`'s BFS models tile-CENTRE voidness
only, with no edge/wall model (its own documented limitation), so it is only
safe to trust down the middle column of the pod (ship-local tx=2): the
cargo/dock tiles themselves sit one column further out (tx=1), and the real
hull has a wall between the bay's aft pallet row and the dock-port row on
that outer column (`rijay.bay.packet`'s patch, the ` #  =  # ` row --  a wall
under the pallet columns, a door only under the middle one). A two-leg walk
that stops to stand on the cargo tile and then BFSes onward from there falls
for exactly that: the naive centre-only model sees the outer column's tiles
as walkable and reports a straight shortcut down it, which real server-side
collision then refuses, stalling the walker (verified: an earlier version of
this test staged through cargo and stalled exactly there). One BFS run from
the helm (already on the safe middle column) does not have that problem --
traced by hand and confirmed against `walk.find_path` directly, it returns
`(2,1) -> (2,2) -> (2,3) -> (2,4) -> (2,5) -> (1,5)`, the middle column the
whole way with a single sidestep onto the dock tile at the very end, which is
real and open on all three columns (the hull's own dock-port row, not a
module patch). So this exercises real server-side collision end to end,
across the cockpit's exit door, the unmarked corridor, both of the bay's own
doors and the dock row's open floor, rather than routing the naive BFS
through an edge it can't see.
"""

from __future__ import annotations

import pytest

from dh_client import DHClient
from deckplan import tile_walkable
from server_fixture import SPARROW_PORT, TEST_PORT
from walk import console_tile, walk_to_console

pytestmark = pytest.mark.asyncio

SPAWN_STATION = "meridian_highport"
SPAWN_STATION_SPACE = f"station:{SPAWN_STATION}"

# The sparrow_server fixture spawns its own dh_server independent of the
# shared `server` fixture, so this client is pointed at it explicitly rather
# than via DH_PORT (which the rest of the session has already stamped for
# the *other* server). Built from SPARROW_PORT (DH_SPARROW_PORT-overridable)
# rather than hardcoded, so an override actually takes effect here too.
assert SPARROW_PORT != TEST_PORT, (
    "DH_SPARROW_PORT collides with DH_PORT/TEST_PORT -- sparrow_server and "
    "server would both try to bind the same port. Point one of the two env "
    "vars elsewhere."
)
SPARROW_URL = f"ws://127.0.0.1:{SPARROW_PORT}/ws"


async def test_walk_sparrow_bow_to_stern(sparrow_server):
    """Stand from the helm (the bow) and walk to a dock port (the stern
    itself -- her dock row is now her sternmost interior row) via the BFS
    driver against the real composite plan. The route is only
    findable, and only walkable to completion, if the cockpit's exit door,
    the unmarked corridor tiles, the bay's own fore and aft doors, and the
    dock row's open floor all resolved onto the hull the way the shipped
    documents intend -- a wall added anywhere along that line (the kind of
    authoring mistake docs/modules.md's "what did not survive" now records)
    would either leave `find_path` with no route (an immediate assertion
    failure) or stall the walker mid-crossing (walk.py's `_follow` stall
    guard), not silently pass."""
    async with DHClient(url=SPARROW_URL, name="sparrow1") as client:
        welcome = await client.login("sparrow_walker", "pw_sparrow")
        ship_id = welcome["ship_id"]
        ship_class = welcome["ship_class"]
        assert ship_class["id"] == "sparrow"
        assert len(ship_class["decks"]) == 1  # the single-deck hull itself

        space = await client.next_space()
        assert space["space"] == SPAWN_STATION_SPACE
        assert space["you"]["seat"] == f"s{ship_id}:helm"
        plan = space["plan"]

        # Lightweight, non-walked confirmation that the cargo console (the
        # bay's forward pallet tile) resolved onto the hull at all -- proof
        # the bay module's patch landed, without routing the BFS through its
        # off-centre tile (see the module docstring for why that's unsafe).
        cargo_x, cargo_y = console_tile(plan, f"s{ship_id}:cargo")
        assert tile_walkable(plan, cargo_x, cargo_y)

        stood = await client.stand()
        assert stood["ok"] is True
        assert stood["reason"] is None

        # The one real walk: bow (helm) to stern (a dock port), the full
        # length of the pod in a single BFS + drive.
        await walk_to_console(client, SPAWN_STATION_SPACE, plan, f"s{ship_id}:dock0")
        walkers = await client.next_walkers(SPAWN_STATION_SPACE)
        me = client.character_in(walkers, client.character_id)
        assert me is not None
        dock_x, dock_y = console_tile(plan, f"s{ship_id}:dock0")
        assert me.x == pytest.approx(dock_x + 0.5, abs=0.25)
        assert me.y == pytest.approx(dock_y + 0.5, abs=0.25)
