"""M2 ship-interior integration tests: characters, consoles, boarding.

Runs against a real server spawned by the `server` fixture in
`server_fixture.py` (session-scoped, shared with test_m1_flight.py when
the whole suite runs). Each test opens its own DHClient connection(s).

Timing note (same discipline as test_m1_flight.py): `interior` messages
arrive at 15 Hz, exactly like snapshots, and carry the same server `tick`.
Tests never sleep-and-hope; they drain the interior/snapshot streams until
a condition holds, bounded in server ticks, so a stalled server fails fast
instead of hanging.

Geometry (sparrow deck plan, tile units, y-down; see the spec and
server/classes/sparrow.json): walk speed 3.0 tiles/s, character radius
0.3, sit range 1.2. helm_main at tile (1,2) -> center (1.5, 2.5);
cargo_main at (6,1) -> center (6.5, 1.5); spawn_tile [5,4] -> center
(5.5, 4.5). Row 2 is ".########." so a character walking east down that
row pins where its circle meets tile x=9: center x = 9 - 0.3 = 8.7, give
or take one 0.05-tile step (walk integrates in walk_speed*dt increments
and the touch test rides on accumulated float error).
"""

from __future__ import annotations

import math

import pytest

from dh_client import CharacterView, DHClient
from test_m1_flight import (  # shared station-frame helpers
    TICK_RATE,
    rail_relative_displacement,
    snapshot_after_ticks,
)

WALK_SPEED = 3.0  # tiles/s, matches character.gleam
CHAR_RADIUS = 0.3  # tiles, matches character.gleam

HELM_CENTER = (1.5, 2.5)  # helm_main tile (1,2) center
CARGO_CONSOLE_CENTER = (6.5, 1.5)  # cargo_main tile (6,1) center
SPAWN_CENTER = (5.5, 4.5)  # spawn_tile [5,4] center


# --- Deck-plan math mirrored from the server (shipclass/character.gleam) ---


def tile_walkable(ship_class: dict, tx: int, ty: int) -> bool:
    """Whether tile (tx, ty) is in bounds and walkable per the class doc."""
    grid = ship_class["grid"]
    if not (0 <= tx < grid["width"] and 0 <= ty < grid["height"]):
        return False
    return ship_class["walkable"][ty][tx] == "#"


def circle_walkable(ship_class: dict, cx: float, cy: float) -> bool:
    """Whether every tile overlapped by the character collision circle at
    (cx, cy) is walkable — the server's own invariant for any standing
    character position, recomputed client-side from the class doc."""
    tx0 = math.floor(cx - CHAR_RADIUS)
    tx1 = math.floor(cx + CHAR_RADIUS)
    ty0 = math.floor(cy - CHAR_RADIUS)
    ty1 = math.floor(cy + CHAR_RADIUS)
    for tx in range(tx0, tx1 + 1):
        for ty in range(ty0, ty1 + 1):
            closest_x = min(max(cx, float(tx)), float(tx) + 1.0)
            closest_y = min(max(cy, float(ty)), float(ty) + 1.0)
            dx = cx - closest_x
            dy = cy - closest_y
            overlaps = dx * dx + dy * dy <= CHAR_RADIUS * CHAR_RADIUS
            if overlaps and not tile_walkable(ship_class, tx, ty):
                return False
    return True


# --- Stream-draining helpers (interior twin of snapshot_after_ticks) ---


async def interior_after_ticks(client: DHClient, after_tick: int, ticks: int) -> dict:
    """Drain interiors until one at least `ticks` server ticks past `after_tick`."""
    target = after_tick + ticks
    interior = await client.next_interior()
    while interior["tick"] < target:
        interior = await client.next_interior()
    return interior


async def interior_until(
    client: DHClient,
    predicate,
    max_ticks: int,
    what: str,
) -> dict:
    """Drain interiors until `predicate(interior)` holds, failing the test
    if it doesn't within `max_ticks` server ticks of the first message."""
    first = await client.next_interior()
    interior = first
    while not predicate(interior):
        if interior["tick"] > first["tick"] + max_ticks:
            pytest.fail(
                f"no interior satisfying '{what}' within {max_ticks} ticks "
                f"(last: {interior})"
            )
        interior = await client.next_interior()
    return interior


async def snapshot_until(
    client: DHClient,
    predicate,
    max_ticks: int,
    what: str,
) -> dict:
    """Drain snapshots until `predicate(snapshot)` holds, failing the test
    if it doesn't within `max_ticks` server ticks of the first message."""
    first = await client.next_snapshot()
    snapshot = first
    while not predicate(snapshot):
        if snapshot["tick"] > first["tick"] + max_ticks:
            pytest.fail(
                f"no snapshot satisfying '{what}' within {max_ticks} ticks"
            )
        snapshot = await client.next_snapshot()
    return snapshot


async def matched_interiors(
    client_a: DHClient,
    client_b: DHClient,
    ship_id: int,
    max_reads: int = 150,
) -> tuple[dict, dict]:
    """Collect interiors for `ship_id` from both clients until a pair with
    the same server tick is found (the server serializes one interior per
    crewed ship per broadcast and fans the same message to every client
    aboard, so same-tick interiors must be identical). Interiors for other
    ships (e.g. B's pre-boarding ship, still queued) are skipped."""
    seen_a: dict[int, dict] = {}
    seen_b: dict[int, dict] = {}
    for _ in range(max_reads):
        ia = await client_a.next_interior()
        ib = await client_b.next_interior()
        if ia["ship_id"] == ship_id:
            seen_a[ia["tick"]] = ia
        if ib["ship_id"] == ship_id:
            seen_b[ib["tick"]] = ib
        common = set(seen_a) & set(seen_b)
        if common:
            tick = max(common)
            return seen_a[tick], seen_b[tick]
    pytest.fail(
        f"no common-tick interior for ship {ship_id} within {max_reads} reads"
    )


# --- Tests ---


@pytest.mark.asyncio
async def test_spawn_state(server):
    """Login spawns a character seated at helm_main; welcome carries
    character_id and the full sparrow class doc."""
    async with DHClient(name="m2t1") as client:
        welcome = await client.login("gale_spawn", "pw_gale")

        assert isinstance(welcome["character_id"], int)
        assert client.character_id == welcome["character_id"]

        ship_class = welcome["ship_class"]
        assert client.ship_class == ship_class
        assert ship_class["schema"] == 2
        assert ship_class["id"] == "sparrow"
        assert ship_class["grid"] == {"width": 10, "height": 6}
        rows = ship_class["walkable"]
        assert len(rows) == ship_class["grid"]["height"]
        assert all(len(row) == ship_class["grid"]["width"] for row in rows)
        assert ship_class["spawn_tile"] == [5, 4]

        consoles = {c["id"]: c for c in ship_class["consoles"]}
        assert consoles["helm_main"]["kind"] == "helm"
        assert (consoles["helm_main"]["x"], consoles["helm_main"]["y"]) == (1, 2)
        assert consoles["cargo_main"]["kind"] == "cargo"
        assert (consoles["cargo_main"]["x"], consoles["cargo_main"]["y"]) == (6, 1)
        # Class-doc invariants the client relies on for rendering/sitting.
        for console in ship_class["consoles"]:
            assert tile_walkable(ship_class, console["x"], console["y"])
        assert tile_walkable(ship_class, *ship_class["spawn_tile"])

        interior = await client.next_interior()
        assert interior["ship_id"] == welcome["ship_id"]
        assert len(interior["characters"]) == 1
        me = client.character_in(interior, client.character_id)
        assert me is not None
        assert me.name == "gale_spawn"
        assert me.seat == "helm_main"
        assert me.x == pytest.approx(HELM_CENTER[0])
        assert me.y == pytest.approx(HELM_CENTER[1])


@pytest.mark.asyncio
async def test_stand_walk_collide(server):
    """Stand from the helm, walk east across the corridor into the cargo
    hold, and pin against the far wall: position advances, the collision
    circle never overlaps a non-walkable tile, and pushing into the wall
    leaves the character exactly put."""
    async with DHClient(name="m2t2") as client:
        await client.login("hana_walk", "pw_hana")
        char_id = client.character_id
        ship_class = client.ship_class

        stood = await client.stand()
        assert stood["ok"] is True
        assert stood["reason"] is None
        assert stood["seat"] is None

        # Walk due east along row 2 (".########."): from the helm center
        # x=1.5 through the corridor (tile 3) into the cargo hold (tiles
        # 4-6) and on until pinned against the engine-room east wall. The
        # y axis has zero input, so y must hold exactly at 2.5 throughout.
        await client.move(1.0, 0.0)

        # 7.2 tiles at 3 tiles/s is ~144 ticks; 600 is a generous bound.
        samples: list[CharacterView] = []

        def record(interior: dict) -> CharacterView:
            me = client.character_in(interior, char_id)
            assert me is not None
            samples.append(me)
            return me

        await interior_until(
            client,
            lambda i: record(i).x >= 5.5,
            max_ticks=600,
            what="walked east into the cargo hold (x >= 5.5)",
        )
        near_wall = await interior_until(
            client,
            lambda i: record(i).x >= 8.6,
            max_ticks=600,
            what="pinned against the east wall (x >= 8.6)",
        )

        # Still pushing east: wait until the position is identical across
        # two samples half a second apart (the wall pin exactly rejects
        # every candidate step, so "stopped" means bit-for-bit equal, not
        # merely slow). The pin lands within one 0.05-tile step of the
        # ideal 9.0 - radius contact point.
        me1 = client.character_in(near_wall, char_id)
        tick = near_wall["tick"]
        for _ in range(10):
            later = await interior_after_ticks(client, tick, TICK_RATE // 2)
            me2 = client.character_in(later, char_id)
            samples.append(me2)
            if me2.x == me1.x:
                break
            me1, tick = me2, later["tick"]
        else:
            pytest.fail(f"character never pinned against the wall: {samples[-3:]}")
        assert me2.x == pytest.approx(9.0 - CHAR_RADIUS, abs=WALK_SPEED / TICK_RATE)
        assert me2.x <= 9.0 - CHAR_RADIUS + 1e-9

        await client.move(0.0, 0.0)

        # Every sampled position kept the collision circle on walkable
        # tiles, x only ever advanced, and y never drifted off the row.
        assert len(samples) >= 3
        for me in samples:
            assert circle_walkable(ship_class, me.x, me.y), me
            assert me.seat is None
            assert me.y == pytest.approx(2.5)
        xs = [me.x for me in samples]
        assert xs == sorted(xs)
        assert xs[-1] > xs[0]


@pytest.mark.asyncio
async def test_seat_rules(server):
    """Sit/stand rejection reasons and helm gating, exactly as specced."""
    async with DHClient(name="m2t3") as client:
        await client.login("ivan_seats", "pw_ivan")

        # Seated at the helm from login: any sit is rejected outright.
        result = await client.sit("cargo_main")
        assert result["ok"] is False
        assert result["reason"] == "already_seated"
        assert result["seat"] == "helm_main"

        stood = await client.stand()
        assert stood["ok"] is True
        assert stood["seat"] is None

        # Standing already: a second stand has nothing to leave.
        stood_again = await client.stand()
        assert stood_again["ok"] is False
        assert stood_again["reason"] == "not_seated"
        assert stood_again["seat"] is None

        # cargo_main is at (6.5, 1.5), the character at the helm center
        # (1.5, 2.5): distance ~5.1 tiles, far beyond the 1.2 sit range.
        too_far = await client.sit("cargo_main")
        assert too_far["ok"] is False
        assert too_far["reason"] == "too_far"
        assert too_far["seat"] is None

        unknown = await client.sit("warp_altar")
        assert unknown["ok"] is False
        assert unknown["reason"] == "unknown_console"
        assert unknown["seat"] is None

        # Helm gating: dock/undock require being seated at a helm console.
        gated = await client.undock()
        assert gated["ok"] is False
        assert gated["reason"] == "not_at_helm"

        gated_dock = await client.dock()
        assert gated_dock["ok"] is False
        assert gated_dock["reason"] == "not_at_helm"

        # Sit back down (still standing on the helm tile, well in range)
        # and the helm binding returns.
        seated = await client.sit("helm_main")
        assert seated["ok"] is True
        assert seated["reason"] is None
        assert seated["seat"] == "helm_main"

        undocked = await client.undock()
        assert undocked["ok"] is True


@pytest.mark.asyncio
async def test_boarding(server):
    """Two ships docked at spawn: B boards A's ship, B's old ship despawns
    from snapshots, and both characters appear in A's interior."""
    async with DHClient(name="m2A") as client_a, DHClient(name="m2B") as client_b:
        welcome_a = await client_a.login("juno_pilot", "pw_juno")
        welcome_b = await client_b.login("kira_boarder", "pw_kira")
        ship_a = welcome_a["ship_id"]
        ship_b = welcome_b["ship_id"]
        char_a = client_a.character_id
        char_b = client_b.character_id

        # Boarding a ship id that doesn't exist.
        unknown = await client_b.board(999_999)
        assert unknown["ok"] is False
        assert unknown["reason"] == "unknown_ship"
        assert unknown["ship_id"] == ship_b

        # Boarding your own ship.
        same = await client_b.board(ship_b)
        assert same["ok"] is False
        assert same["reason"] == "same_ship"
        assert same["ship_id"] == ship_b

        # Both ships spawn docked at meridian_highport: boarding succeeds.
        boarded = await client_b.board(ship_a)
        assert boarded["ok"] is True
        assert boarded["reason"] is None
        assert boarded["ship_id"] == ship_a

        # B's old ship had no one left aboard: it despawns from snapshots.
        snap = await snapshot_until(
            client_b,
            lambda s: client_b.ship_in(s, ship_b) is None,
            max_ticks=10 * TICK_RATE,
            what="B's abandoned ship gone from snapshots",
        )
        assert client_b.ship_in(snap, ship_a) is not None

        # Both characters ride A's ship now, and both clients see it. B
        # stands at the spawn tile (airlock end); A is still at the helm.
        def full_crew(interior: dict) -> bool:
            return (
                interior["ship_id"] == ship_a
                and client_a.character_in(interior, char_a) is not None
                and client_a.character_in(interior, char_b) is not None
            )

        for client in (client_a, client_b):
            interior = await interior_until(
                client,
                full_crew,
                max_ticks=10 * TICK_RATE,
                what="both characters aboard ship A",
            )
            assert len(interior["characters"]) == 2
            crew_a = client.character_in(interior, char_a)
            crew_b = client.character_in(interior, char_b)
            assert crew_a.seat == "helm_main"
            assert crew_b.seat is None
            assert crew_b.name == "kira_boarder"
            assert crew_b.x == pytest.approx(SPAWN_CENTER[0])
            assert crew_b.y == pytest.approx(SPAWN_CENTER[1])


@pytest.mark.asyncio
async def test_one_flies_one_walks(server):
    """M2 exit criterion: two clients aboard one ship — A seated at the
    helm flying it, B walking the cargo hold. The ship moves in snapshots,
    B's coordinates change while it flies, B's helm input is ignored, and
    both clients receive the same interior crew list."""
    async with DHClient(name="m2P") as client_a, DHClient(name="m2W") as client_b:
        welcome_a = await client_a.login("lena_pilot", "pw_lena")
        welcome_b = await client_b.login("milo_walker", "pw_milo")
        ship_a = welcome_a["ship_id"]
        char_a = client_a.character_id
        char_b = client_b.character_id
        world = welcome_a["world"]
        dt = welcome_a["dt"]

        boarded = await client_b.board(ship_a)
        assert boarded["ok"] is True

        undocked = await client_a.undock()
        assert undocked["ok"] is True

        # A flies: full thrust, no rotation, so the ship's heading is
        # constant unless someone else's helm input leaks in.
        await client_a.send_helm(0.0, 1.0)

        # B is standing (boarding leaves you at the spawn tile), so B's
        # helm input must be silently ignored: were it applied, rotate=1
        # would swing the heading and thrust=0 would kill the burn.
        await client_b.send_helm(1.0, 0.0)

        # B walks north up the cargo hold (column 5: from the spawn tile
        # center y=4.5 toward the cargo console wall, ~3.2 tiles of room).
        await client_b.move(0.0, -1.0)

        # The ship shows as flying (snapshots queued from before the
        # undock drain off first).
        snap1 = await snapshot_until(
            client_a,
            lambda s: client_a.ship_in(s, ship_a)["docked"] is None,
            max_ticks=10 * TICK_RATE,
            what="ship A flying",
        )
        ship1 = client_a.ship_in(snap1, ship_a)
        heading1 = ship1["heading"]

        # B's character is in motion while the ship flies: catch the walk
        # started, then confirm sustained movement half a second on.
        moving = await interior_until(
            client_b,
            lambda i: (
                i["ship_id"] == ship_a
                and abs(client_b.character_in(i, char_b).y - SPAWN_CENTER[1])
                > 0.05
            ),
            max_ticks=10 * TICK_RATE,
            what="B's character walking",
        )
        b1 = client_b.character_in(moving, char_b)

        later = await interior_after_ticks(client_b, moving["tick"], TICK_RATE // 2)
        b2 = client_b.character_in(later, char_b)
        assert b2.y < b1.y - 0.5  # 0.5 s at 3 tiles/s, minus margin
        assert b2.seat is None
        ship_class = client_b.ship_class
        for sample in (b1, b2):
            assert circle_walkable(ship_class, sample.x, sample.y), sample

        # One second of full thrust: the ship moved in the station frame
        # (rail drift removed, as in the M1 tests), still at full burn,
        # heading untouched by B's rotate input.
        snap2 = await snapshot_after_ticks(client_a, snap1["tick"], TICK_RATE)
        ship2 = client_a.ship_in(snap2, ship_a)
        assert ship2["docked"] is None
        moved = rail_relative_displacement(
            world, "meridian_highport", dt,
            ship1, snap1["tick"], ship2, snap2["tick"],
        )
        assert moved > 10.0
        assert ship2["thrust"] == pytest.approx(1.0)
        assert ship2["heading"] == pytest.approx(heading1, abs=1e-6)

        # Both clients receive the same interior: interiors with the same
        # tick are one serialization fanned to the whole crew, so a
        # same-tick pair must agree exactly — same ship, same crew list.
        interior_a, interior_b = await matched_interiors(client_a, client_b, ship_a)
        assert interior_a["characters"] == interior_b["characters"]
        crew_ids = {c["id"] for c in interior_a["characters"]}
        assert crew_ids == {char_a, char_b}
        pilot = client_a.character_in(interior_a, char_a)
        walker = client_a.character_in(interior_a, char_b)
        assert pilot.seat == "helm_main"
        assert walker.seat is None
