"""M2/M3.1 walkable-space integration tests: characters, consoles, walking
between a docked ship and the concourse, and flying a ship with crew aboard.

Runs against a real server spawned by the `server` fixture in
`server_fixture.py` (session-scoped, shared with test_m1_flight.py when the
whole suite runs). Each test opens its own DHClient connection(s).

M3.1 stitched interiors: there is no `board`/`disembark` any more. Login
lands a character seated at their own namespaced helm ("s{ship}:helm") in
the *station composite* -- the concourse with every docked ship's deck
moored on at a berth. Crossing between a ship deck and the concourse is
plain `move` input in one shared space; the 15 Hz `walkers` feed (not the
old `interior`/`concourse` messages) carries everyone in it. Positions are
in the composite frame while docked, and in the ship-local frame once a ship
undocks and flies free.

Timing (same discipline as test_m1_flight.py): `walkers` arrive at 15 Hz,
carrying the same server `tick` as snapshots. Tests never sleep-and-hope;
they drain the walkers/snapshot streams until a condition holds, bounded in
server ticks or message counts, so a stalled server fails fast.

Collision/geometry checks never hardcode composite coordinates -- berth
assignment is seed-random among free berths (free_berth in sim.gleam), so a
ship's mooring offset is never assumed. Instead tests drive characters with
the BFS `walk_to_console` driver (walk.py) against the composite `plan` the
`space` message carries, and check collision with `circle_walkable`/
`tile_walkable` (deckplan.py) against that same plan. The stand/walk/collide
test walks onto the ship's cargo console, then keeps pushing south
(composite +y, the direction with the most open run from that tile) until
the character pins against a hull wall, sampling positions along the way.
Walk speed 3.0 tiles/s, character radius 0.3 (character.gleam).
"""

from __future__ import annotations

import asyncio
import contextlib

import pytest

from dh_client import CharacterView, DHClient
from deckplan import circle_walkable, tile_walkable  # v3 (decks/glyph rows)
from walk import console_tile, walk_to_console
from test_m1_flight import (  # shared station-frame helpers
    TICK_RATE,
    rail_relative_displacement,
    snapshot_after_ticks,
)

pytestmark = pytest.mark.asyncio

WALK_SPEED = 3.0  # tiles/s, matches character.gleam

SPAWN_STATION = "meridian_highport"
SPAWN_STATION_SPACE = f"station:{SPAWN_STATION}"


def _helm_center(space: dict, ship_id: int) -> tuple[float, float]:
    """Composite centre of ship_id's helm, from the plan the server sent --
    correct under the current CCW side-on mooring (no hardcoded rotation)."""
    tx, ty = console_tile(space["plan"], f"s{ship_id}:helm")
    return (tx + 0.5, ty + 0.5)


# --- Stream-draining helpers (walkers twin of snapshot_after_ticks) ---


async def walkers_after_ticks(
    client: DHClient, space: str, after_tick: int, ticks: int
) -> dict:
    """Drain walkers for `space` until one at least `ticks` server ticks past
    `after_tick`."""
    target = after_tick + ticks
    walkers = await client.next_walkers(space)
    while walkers["tick"] < target:
        walkers = await client.next_walkers(space)
    return walkers


async def walkers_until(
    client: DHClient, space: str, predicate, max_ticks: int, what: str
) -> dict:
    """Drain walkers for `space` until `predicate(walkers)` holds, failing the
    test if it doesn't within `max_ticks` server ticks of the first message."""
    first = await client.next_walkers(space)
    walkers = first
    while not predicate(walkers):
        if walkers["tick"] > first["tick"] + max_ticks:
            pytest.fail(
                f"no walkers satisfying '{what}' within {max_ticks} ticks "
                f"(last: {walkers})"
            )
        walkers = await client.next_walkers(space)
    return walkers


async def walk_until_own(
    client: DHClient, space: str, predicate, max_messages: int = 200
) -> CharacterView:
    """Drain walkers for `space` until our own character's position satisfies
    `predicate`, returning that CharacterView."""
    me = None
    for _ in range(max_messages):
        walkers = await client.next_walkers(space)
        me = client.character_in(walkers, client.character_id)
        if me is not None and predicate(me):
            return me
    raise AssertionError(f"character never reached expected position; last: {me}")


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


async def matched_walkers(
    client_a: DHClient,
    client_b: DHClient,
    space: str,
    max_reads: int = 200,
) -> tuple[dict, dict]:
    """Collect walkers for `space` from both clients until a pair with the
    same server tick is found (the server serializes one walkers message per
    space per broadcast and fans the same message to every occupant, so
    same-tick frames must be identical)."""
    seen_a: dict[int, dict] = {}
    seen_b: dict[int, dict] = {}
    for _ in range(max_reads):
        wa = await client_a.next_walkers(space)
        wb = await client_b.next_walkers(space)
        seen_a[wa["tick"]] = wa
        seen_b[wb["tick"]] = wb
        common = set(seen_a) & set(seen_b)
        if common:
            tick = max(common)
            return seen_a[tick], seen_b[tick]
    pytest.fail(f"no common-tick walkers for {space} within {max_reads} reads")


@contextlib.asynccontextmanager
async def _kept_drained(client: DHClient):
    """Keep `client`'s incoming queue emptied out for the duration of the
    `with` body, discarding whatever arrives -- walkers/snapshots stream to
    every connected client regardless of who's doing something slow, and a
    long cross-composite BFS walk on another client (`walk_to_console` can
    take many seconds on a large station) would otherwise let this client's
    unread queue grow past `recv_type`'s 1000-frame skip cap before the next
    explicit read. Only wrap spans where nothing on `client` is being read
    for real."""
    stop = asyncio.Event()

    async def _drain() -> None:
        while not stop.is_set():
            try:
                await asyncio.wait_for(client.recv(), timeout=0.05)
            except asyncio.TimeoutError:
                continue
            except Exception:
                return

    task = asyncio.create_task(_drain())
    try:
        yield
    finally:
        stop.set()
        task.cancel()
        with contextlib.suppress(asyncio.CancelledError, Exception):
            await task


# --- Tests ---


async def test_spawn_state(server):
    """Login spawns a character seated at their own namespaced helm in the
    station composite; welcome still carries the full sparrow class doc."""
    async with DHClient(name="m2t1") as client:
        welcome = await client.login("gale_spawn", "pw_gale")
        ship_id = welcome["ship_id"]

        assert isinstance(welcome["character_id"], int)
        assert client.character_id == welcome["character_id"]

        ship_class = welcome["ship_class"]
        assert client.ship_class == ship_class
        assert ship_class["schema"] == 3
        assert ship_class["id"] == "sparrow"

        # v3: one flat deck of 3x3-glyph rows; consoles carry a deck index;
        # spawn is {deck, tile}. helm (1,2) and cargo (6,1) are the fixture's.
        assert len(ship_class["decks"]) == 1
        consoles = {c["id"]: c for c in ship_class["consoles"]}
        assert consoles["helm"]["kind"] == "helm"
        assert (consoles["helm"]["x"], consoles["helm"]["y"]) == (1, 2)
        assert consoles["cargo"]["kind"] == "cargo"
        assert (consoles["cargo"]["x"], consoles["cargo"]["y"]) == (6, 1)
        for c in ship_class["consoles"]:
            assert tile_walkable(ship_class, c["x"], c["y"], c.get("deck", 0))
        sd, (stx, sty) = ship_class["spawn"]["deck"], ship_class["spawn"]["tile"]
        assert tile_walkable(ship_class, stx, sty, sd)

        # The space message names the spawn station's composite and seats us
        # at our own namespaced helm, offset by whichever berth free_berth
        # assigned (seed-random among free berths -- never assumed).
        space = await client.next_space()
        assert space["space"] == SPAWN_STATION_SPACE
        assert space["you"]["seat"] == f"s{ship_id}:helm"
        helm_x, helm_y = _helm_center(space, ship_id)

        walkers = await client.next_walkers(SPAWN_STATION_SPACE)
        me = client.character_in(walkers, client.character_id)
        assert me is not None
        assert me.name == "gale_spawn"
        assert me.seat == f"s{ship_id}:helm"
        assert me.x == pytest.approx(helm_x)
        assert me.y == pytest.approx(helm_y)


async def test_stand_walk_collide(server):
    """Stand from the helm, walk to the cargo console via the BFS driver,
    then keep pushing in the same direction until pinned against a hull
    wall: position advances, the collision circle never overlaps a
    non-walkable tile, and pushing into the wall leaves the character
    exactly put. Collision is checked against the composite plan the space
    message carries -- no hardcoded composite row/column math, since the
    ship is moored side-on and rotated relative to its own local grid."""
    async with DHClient(name="m2t2") as client:
        welcome = await client.login("hana_walk", "pw_hana")
        char_id = client.character_id
        space = await client.next_space()
        plan = space["plan"]
        stood = await client.stand()
        assert stood["ok"] is True
        assert stood["reason"] is None
        assert stood["seat"] is None

        # Drive onto the cargo tile via the plan the server sent, then keep
        # pushing south (composite +y): from the cargo tile the plan shows
        # an open run of 5 tiles south before a wall, versus 3 east, 2
        # north, and a wall immediately west -- south gives the most room to
        # observe an actual walk-then-pin rather than an instant one.
        await walk_to_console(client, SPAWN_STATION_SPACE, plan, f"s{welcome['ship_id']}:cargo")

        # Push toward increasing y until pinned; sample positions to assert
        # the collision circle stays walkable and y is monotonic then
        # frozen.
        await client.move(0.0, 1.0)
        samples: list[CharacterView] = []
        # Seed the sampling tick from a raw walkers read (walk_until_own only
        # returns a CharacterView, not the frame's tick).
        walkers = await client.next_walkers(SPAWN_STATION_SPACE)
        me = client.character_in(walkers, char_id)
        assert me is not None
        tick = walkers["tick"]
        samples.append(me)
        prev = me
        for _ in range(40):
            later = await walkers_after_ticks(client, SPAWN_STATION_SPACE, tick, TICK_RATE // 2)
            tick = later["tick"]
            m = client.character_in(later, char_id)
            samples.append(m)
            if m.y == prev.y:
                break
            prev = m
        else:
            pytest.fail(f"character never pinned against the wall: {samples[-3:]}")
        await client.move(0.0, 0.0)

        assert len(samples) >= 2
        for s in samples:
            assert circle_walkable(plan, s.x, s.y), s
            assert s.seat is None
        ys = [s.y for s in samples]
        assert ys == sorted(ys)   # y only advanced (pushed +y)
        assert samples[-1].y == samples[-2].y  # pinned: last two samples frozen


async def test_seat_rules(server):
    """Sit/stand rejection reasons and helm gating in the station composite,
    where ship consoles are namespaced "s{ship}:{id}"."""
    async with DHClient(name="m2t3") as client:
        welcome = await client.login("ivan_seats", "pw_ivan")
        ship_id = welcome["ship_id"]
        helm = f"s{ship_id}:helm"
        cargo = f"s{ship_id}:cargo"

        # Seated at the helm from login: any sit is rejected outright.
        result = await client.sit(cargo)
        assert result["ok"] is False
        assert result["reason"] == "already_seated"
        assert result["seat"] == helm

        stood = await client.stand()
        assert stood["ok"] is True
        assert stood["seat"] is None

        # Standing already: a second stand has nothing to leave.
        stood_again = await client.stand()
        assert stood_again["ok"] is False
        assert stood_again["reason"] == "not_seated"
        assert stood_again["seat"] is None

        # cargo sits ~5.1 tiles from the helm in ship-local terms (mooring
        # offset cancels out between two consoles on the same ship), far
        # beyond the 1.2 range.
        too_far = await client.sit(cargo)
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

        # Sit back down (still standing on the helm tile, well in range) and
        # the helm binding returns.
        seated = await client.sit(helm)
        assert seated["ok"] is True
        assert seated["reason"] is None
        assert seated["seat"] == helm

        undocked = await client.undock()
        assert undocked["ok"] is True


async def test_one_flies_one_walks(server):
    """M2 exit criterion, restitched for M3.1: B shanghais onto A's ship
    (walks aboard, A undocks carrying B off as crew), then A flies it from
    the helm while B walks the cargo hold. The ship moves in snapshots, B's
    coordinates change while it flies, B's helm input is ignored, and both
    clients receive the same ship-space walkers crew list."""
    async with DHClient(name="m2P") as client_a, DHClient(name="m2W") as client_b:
        welcome_a = await client_a.login("lena_pilot", "pw_lena")
        welcome_b = await client_b.login("milo_walker", "pw_milo")
        ship_a = welcome_a["ship_id"]
        ship_b = welcome_b["ship_id"]
        char_a = client_a.character_id
        char_b = client_b.character_id
        world = welcome_a["world"]
        dt = welcome_a["dt"]

        space_a = await client_a.next_space()
        space_b = await client_b.next_space()

        # B stands and walks from her own deck onto A's, driven by the BFS
        # walk driver against the composite plan the server sent -- no
        # hardcoded airlock columns or composite rows, since berth
        # assignment is seed-random among free berths.
        assert (await client_b.stand())["ok"] is True
        async with _kept_drained(client_a):
            await walk_to_console(client_b, SPAWN_STATION_SPACE, space_b["plan"], f"s{ship_a}:helm")

        # A undocks: B stands on A's tiles, so she leaves as A's crew; her old
        # ship, now crewless, despawns. Both now share A's flying ship space.
        undocked = await client_a.undock()
        assert undocked["ok"] is True
        ship_space = f"ship:{ship_a}"

        # A flies: full thrust, no rotation, so heading is constant unless
        # someone else's helm input leaks in.
        await client_a.send_helm(0.0, 1.0)
        # B is standing, so B's helm input must be silently ignored: were it
        # applied, rotate=1 would swing the heading and thrust=0 kill the burn.
        await client_b.send_helm(1.0, 0.0)

        # B's initial standing position in the (now ship-local) space.
        b0 = await walk_until_own(client_b, ship_space, lambda me: True)
        await client_b.move(0.0, -1.0)  # walk north up the cargo hold

        # The ship shows flying (snapshots queued from before the undock drain
        # off first).
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
        moving = await walkers_until(
            client_b,
            ship_space,
            lambda w: (
                (mb := client_b.character_in(w, char_b)) is not None
                and mb.y < b0.y - 0.3
            ),
            max_ticks=10 * TICK_RATE,
            what="B's character walking",
        )
        b1 = client_b.character_in(moving, char_b)

        later = await walkers_after_ticks(client_b, ship_space, moving["tick"], TICK_RATE // 2)
        b2 = client_b.character_in(later, char_b)
        assert b2.y < b1.y - 0.4  # ~0.5 s at 3 tiles/s, minus margin
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

        # A's old ship (ship_b) despawned when B left it crewless.
        assert client_a.ship_in(snap2, ship_b) is None

        # Both clients receive the same ship-space walkers: same-tick frames
        # are one serialization fanned to the whole crew, so they must agree
        # exactly -- same crew list, both aboard A.
        walkers_a, walkers_b = await matched_walkers(client_a, client_b, ship_space)
        assert walkers_a["characters"] == walkers_b["characters"]
        crew_ids = {c["id"] for c in walkers_a["characters"]}
        assert crew_ids == {char_a, char_b}
        pilot = client_a.character_in(walkers_a, char_a)
        walker = client_a.character_in(walkers_a, char_b)
        assert pilot.seat == "helm"  # stripped back to ship-local on undock
        assert walker.seat is None
