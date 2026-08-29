import dh_server/deckplan.{type DeckGrid, type DeckPlan}
import dh_server/glyphs
import dh_server/hull
import dh_server/loadout
import dh_server/module
import dh_server/part
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/order
import gleam/string

/// Two passenger decks plus the mezzanine that carries her dock ports: the
/// A380 reading of "two rows of windows on the sides".
pub fn she_is_a_double_decker_test() {
  let assert Ok(h) = hull.load("shipclasses/goldfinch.json")
  assert h.id == "goldfinch"
  assert list.length(h.decks) == 3
}

/// Twelve identical 1x2 cabins, and fifteen slots total — one below the
/// sixteen a single hex digit could once express, back when this hull was
/// drawn (the ceiling is twenty-six now that a marker is a letter).
pub fn she_carries_twelve_cabins_in_fifteen_slots_test() {
  let assert Ok(h) = hull.load("shipclasses/goldfinch.json")
  assert list.length(h.slots) == 15
  let cabins =
    list.filter(h.slots, fn(s) { string.starts_with(s.id, "cabin_") })
  assert list.length(cabins) == 12
}

/// The first hull to mix mount sizes: a medium on the stern, smalls on struts.
pub fn her_mounts_mix_sizes_test() {
  let assert Ok(h) = hull.load("shipclasses/goldfinch.json")
  let assert Ok(centre) = hull.mount_by_id(h, "engine_center")
  assert centre.size == "m"
  let assert Ok(port) = hull.mount_by_id(h, "engine_port")
  assert port.size == "s"
}

// ------------------------------------------------------------- stairs --
//
// She is the first hull drawn with THREE decks from scratch, and the first
// where a stair column could plausibly be stacked on all three. It cannot be:
// `deckplan.stairs_target` scans `deck+1` DOWNWARD first, so on a
// three-deck column the middle deck's step always goes down and nothing ever
// climbs back — the top deck is orphaned and the ship cannot be flown.
// `character.deck_after_step` is stateless, so no "came from above" memory
// rescues it. The Mockingbird's columns each carry an `x` on exactly two
// decks; that is the real invariant, and these two tests pin it.

/// The bare hull's authored decks as a `DeckPlan`, built the same way the
/// server builds one (`deckplan.from_rows`) so `consoles`/`spawn_deck`/
/// `spawn_tile` are DERIVED from the hull's own glyphs rather than
/// hand-pinned here — a hand-written boarding tile would silently stop
/// matching reality if the west-facing dock port ever moved, and these tests
/// would keep passing while walking from a tile nobody actually boards at.
/// Her default loadout does not resolve until her modules land, and stair
/// geometry is hull-owned anyway — a module may not overwrite a fixed-hull
/// tile.
fn bare_plan() -> DeckPlan {
  let assert Ok(h) = hull.load("shipclasses/goldfinch.json")
  let assert Ok(plan) = deckplan.from_rows(glyphs.default(), h.decks)
  plan
}

/// Every stairs tile on every deck, as `#(deck, x, y)`, in deck/row/column
/// order.
fn stair_tiles(plan: DeckPlan) -> List(#(Int, Int, Int)) {
  list.index_map(plan.decks, fn(g, deck) {
    list.index_map(g.cells, fn(row, y) {
      list.index_map(row, fn(cell, x) { #(cell.tile, deck, x, y) })
    })
    |> list.flatten
  })
  |> list.flatten
  |> list.filter_map(fn(c) {
    case c.0 {
      deckplan.Stairs -> Ok(#(c.1, c.2, c.3))
      _ -> Error(Nil)
    }
  })
}

/// Every stair step is reversible: if `(deck, x, y)` lands you on `target`,
/// the stairs tile you land on must send you straight back. A column with an
/// `x` on all three decks breaks this on the top deck, which is exactly the
/// defect this test exists to catch.
pub fn her_stairs_are_reversible_test() {
  let plan = bare_plan()
  let stairs = stair_tiles(plan)
  // Two columns of two decks each: (1,10) Mezzanine<->Lower down the port
  // flank, (3,11) Upper<->Mezzanine down the starboard one. Never one column
  // of three, and never the same column twice.
  assert stairs == [#(0, 3, 11), #(1, 1, 10), #(1, 3, 11), #(2, 1, 10)]
  let round_trips =
    list.map(stairs, fn(s) {
      let #(deck, x, y) = s
      let assert Ok(target) = deckplan.stairs_target(plan, deck, x, y)
      deckplan.stairs_target(plan, target, x, y)
    })
  assert round_trips == [Ok(0), Ok(1), Ok(1), Ok(2)]
}

/// Reversibility alone is not enough: two stairs tiles that are orthogonal
/// NEIGHBOURS are reversible and still unreachable, because
/// `character.deck_after_step` only switches deck when stepping onto stairs
/// FROM a non-stairs tile — so a walker who lands on one can shuffle onto the
/// other without ever triggering the switch, and can never step off and back
/// on. This walks her the way the engine does, from the tile crew actually
/// board at, and asserts all three decks come out reachable.
pub fn every_deck_is_reachable_from_the_boarding_port_test() {
  let plan = bare_plan()
  let #(bx, by) = plan.spawn_tile
  let reached = walk_from(plan, [#(plan.spawn_deck, bx, by)], [])
  let decks =
    list.unique(list.map(reached, fn(s) { s.0 })) |> list.sort(int_cmp)
  assert decks == [0, 1, 2]
}

fn int_cmp(a: Int, b: Int) -> order.Order {
  int.compare(a, b)
}

/// Flood fill over `#(deck, x, y)` states, mirroring `character.move`: a step
/// is legal if the destination is walkable and neither facing edge blocks,
/// and it changes deck only when the destination is stairs and the origin is
/// not.
fn walk_from(
  plan: DeckPlan,
  queue: List(#(Int, Int, Int)),
  seen: List(#(Int, Int, Int)),
) -> List(#(Int, Int, Int)) {
  case queue {
    [] -> seen
    [state, ..rest] ->
      case list.contains(seen, state) {
        True -> walk_from(plan, rest, seen)
        False -> {
          let #(deck, x, y) = state
          let assert Ok(g) = deckplan.deck_at(plan, deck)
          let here_stairs = deckplan.tile_at(g, x, y) == deckplan.Stairs
          let next =
            [
              #(deckplan.N, 0, -1),
              #(deckplan.S, 0, 1),
              #(deckplan.E, 1, 0),
              #(deckplan.W, -1, 0),
            ]
            |> list.filter_map(fn(step) {
              let #(dir, dx, dy) = step
              let #(nx, ny) = #(x + dx, y + dy)
              case
                deckplan.is_walkable(g, nx, ny)
                && !deckplan.edge_blocks(g, x, y, dir)
              {
                False -> Error(Nil)
                True ->
                  case deckplan.tile_at(g, nx, ny), here_stairs {
                    deckplan.Stairs, False ->
                      case deckplan.stairs_target(plan, deck, nx, ny) {
                        Ok(t) -> Ok(#(t, nx, ny))
                        Error(Nil) -> Ok(#(deck, nx, ny))
                      }
                    _, _ -> Ok(#(deck, nx, ny))
                  }
              }
            })
          walk_from(plan, list.append(rest, next), [state, ..seen])
        }
      }
  }
}

// ------------------------------------------- same-deck traversability --
//
// Reachability across the whole ship is a weaker property than it looks, and
// the Goldfinch shipped a level-design defect that hid behind it. Her Lower
// corridor used to END on the Mezzanine stair tile at (2,9), because the
// flanking floors either side of it are walled in by the aft cabins and only
// a diagonal step away from the corridor. Walking aft from the cabins to the
// hold therefore read: south onto the stairs, and you are now a deck up.
// Nothing was orphaned, so `every_deck_is_reachable_from_the_boarding_port`
// stayed green — the player just pressed south, south, north, south and
// arrived somewhere else. The rule this pins: **stepping onto a stairs tile
// changes your deck, so a stairs tile dropped mid-corridor severs that
// corridor** (`docs/deckplan-format.md`, "Decks"). Offset the stair from the
// corridor, or let the corridor terminate there by design.

/// Her stock fit as a walkable plan. Same-deck traversability is a property
/// of the FITTED ship, not the bare hull: the hold's walls and its one door
/// come from `rijay.hold.breakbulk_3x2` and the cabins seal themselves off
/// the corridor, so a bare-hull walk would stroll through partitions that do
/// not exist on the ship anybody actually flies.
fn stock_plan() -> DeckPlan {
  let assert Ok(h) = hull.load("shipclasses/goldfinch.json")
  let assert Ok(modules) = module.load_all("modules")
  let assert Ok(parts) = part.load_all("parts")
  let assert Ok(fit) =
    loadout.resolve(glyphs.default(), h, modules, parts, loadout.default_for(h))
  fit.class.plan
}

/// A walker gets from the Lower corridor to every tile of the hold without
/// ever changing deck. The hold's extent is read off the slot markers rather
/// than hardcoded, so this keeps meaning what it says if the hold is ever
/// re-drawn. Slot markers are read off the AUTHORED hull's own bare deck, not
/// the fitted `stock_plan` — the hold module's patch owns the tile centre
/// same as any other module, so it overwrites the marker there once
/// installed (M4). The walk itself still runs on `stock_plan`, because
/// same-deck traversability is a property of the ship as fitted.
pub fn her_lower_corridor_reaches_the_hold_on_one_deck_test() {
  let assert Ok(h) = hull.load("shipclasses/goldfinch.json")
  let assert Ok(hold) = hull.slot_by_id(h, "hold")
  let assert Ok(bare_lower) = deckplan.deck_at(bare_plan(), 2)
  let hold_tiles = tiles_of_slot(bare_lower, hold.marker)
  assert hold_tiles != []
  let assert Ok(lower) = deckplan.deck_at(stock_plan(), 2)
  // (2,3) is the forward corridor abeam the first pair of cabins: fixed
  // hull, no slot marker, and as far forward of the hold as the deck goes.
  let reached = walk_one_deck(lower, [#(2, 3)], [])
  let unreachable =
    list.filter(hold_tiles, fn(t) { !list.contains(reached, t) })
  assert unreachable == []
}

/// The stronger property the corridor check above only partly proves: a
/// stairs tile dropped forward of the corridor start, rather than behind it,
/// would sever the deck just as badly and go uncaught there. So instead of
/// walking from one fixed tile, treat every stairs tile as unenterable and
/// check the WHOLE deck: its non-stairs walkable tiles must form a single
/// connected component, none of them cut off by a misplaced stair.
pub fn her_lower_deck_walkable_tiles_form_one_component_test() {
  let assert Ok(lower) = deckplan.deck_at(stock_plan(), 2)
  assert one_component(lower) == Ok(35)
}

/// The same property on her other cabin deck. It is asserted for BOTH now
/// rather than only the one that had a bug — a deck severed by its own stair
/// is not a Lower-deck-shaped mistake, it is a mistake any deck can make.
///
/// Honest caveat, so nobody reads more into this test than it proves: it was
/// green on the Upper deck *before* her aft stair moved off the centreline
/// too, because that stair stood in a three-wide hall and a walker could
/// squeeze past it on either flank. One component is the weaker half of the
/// rule; `no_stair_of_hers_sits_on_the_corridor_centreline_test` below is the half
/// that actually caught the centreline stair.
pub fn her_upper_deck_walkable_tiles_form_one_component_test() {
  let assert Ok(upper) = deckplan.deck_at(stock_plan(), 0)
  assert one_component(upper) == Ok(33)
}

/// A bypass is a mitigation; an offset is the design. A stair with room to
/// squeeze past it still puts a deck change on the tile a player walks into
/// when they hold "aft", and it only reads as survivable because the hall
/// happens to be wide. So pin the design rule directly: **no stairs tile of
/// hers sits on the corridor column.** Her cross-section is x1 port cabins,
/// x2 corridor, x3 starboard cabins, so the corridor never meets a stair at
/// all — you go to the stair, you never arrive at one.
pub fn no_stair_of_hers_sits_on_the_corridor_centreline_test() {
  let plan = stock_plan()
  let assert Ok(upper) = deckplan.deck_at(plan, 0)
  let centreline = upper.width / 2
  assert centreline == 2
  let on_the_corridor =
    list.filter(stair_tiles(plan), fn(s) { s.1 == centreline })
  assert on_the_corridor == []
}

/// The other half of "a stair is never a tile you walk *through*", one column
/// further out than the corridor rule above. Offsetting a stair off `x2` stops
/// the MAIN thoroughfare running onto it, but a stair left standing open on two
/// FACING sides still sits mid-run on whatever flank it is on: hold "aft" down
/// that flank and the tile you meant to walk past drops you a deck, which is the
/// same lie the centreline stair told. So pin the shape instead of the column:
/// **no stairs tile of hers is open on both N and S, or on both E and W.** Her
/// aft stairwell used to be exactly that — Upper (3,11) stood open north, south
/// and west, with only the hull skin on its east — and every other check stayed
/// green, because a bypass existed and the corridor was clear. Both of her
/// starboard stairs are now one-mouth alcoves opening west onto the corridor,
/// the port pair opens east, the lower half turning a corner; none of the four
/// is a corridor.
///
/// The through-axis clause needs a floor under it, though: walling a stair on
/// ALL four sides satisfies it trivially, and a sealed stair is not a corridor,
/// it is a stranded deck. Nothing else on this hull catches that — the
/// whole-ship walk asserts only the deck SET, and you do land on the sealed
/// tile, so its deck still counts as reached; the one-component check refuses
/// to enter stairs tiles at all, so it never notices. So this test pins both
/// ends of the range at once: **at least one mouth** (invariant (b), the stair
/// can be entered) and **never two facing ones** (it can't be walked through).
pub fn no_stair_of_hers_can_be_walked_through_test() {
  let plan = stock_plan()
  let stairs = stair_tiles(plan)
  let mouths =
    list.map(stairs, fn(s) {
      let #(deck, x, y) = s
      let assert Ok(g) = deckplan.deck_at(plan, deck)
      #(s, open_mouths(g, x, y))
    })
  let sealed = list.filter(mouths, fn(m) { m.1 == [] })
  assert sealed == []
  let through =
    list.filter(mouths, fn(m) {
      let open = m.1
      { list.contains(open, deckplan.N) && list.contains(open, deckplan.S) }
      || { list.contains(open, deckplan.E) && list.contains(open, deckplan.W) }
    })
  assert through == []
  // And the aft stairwell specifically is a one-mouth alcove on both of the
  // decks it joins — the Upper half mirroring the Mezzanine half below it.
  let assert Ok(upper) = deckplan.deck_at(plan, 0)
  assert open_mouths(upper, 3, 11) == [deckplan.W]
  let assert Ok(mezzanine) = deckplan.deck_at(plan, 1)
  assert open_mouths(mezzanine, 3, 11) == [deckplan.W]
}

/// The directions a walker can actually LEAVE `(x, y)` by — its mouths: the
/// neighbour is walkable and neither facing edge blocks. This reads the
/// boundary, not the tile's own edge, so a wall drawn on the neighbour's side
/// closes the mouth just as surely (the double-wall OR rule).
fn open_mouths(grid: DeckGrid, x: Int, y: Int) -> List(deckplan.Dir) {
  [
    #(deckplan.N, 0, -1),
    #(deckplan.E, 1, 0),
    #(deckplan.S, 0, 1),
    #(deckplan.W, -1, 0),
  ]
  |> list.filter_map(fn(step) {
    let #(dir, dx, dy) = step
    case
      deckplan.is_walkable(grid, x + dx, y + dy)
      && !deckplan.edge_blocks(grid, x, y, dir)
    {
      True -> Ok(dir)
      False -> Error(Nil)
    }
  })
}

/// The size of `grid`'s one connected component of non-stairs walkable tiles,
/// or `Error(the tiles it could not reach)` when they form more than one — so
/// a failure names the orphans instead of just saying `False`.
fn one_component(grid: DeckGrid) -> Result(Int, List(#(Int, Int))) {
  let all_tiles = non_stairs_walkable_tiles(grid)
  let assert [start, ..] = all_tiles
  let reached = walk_one_deck(grid, [start], [])
  case list.filter(all_tiles, fn(t) { !list.contains(reached, t) }) {
    [] -> Ok(list.length(all_tiles))
    unreached -> Error(unreached)
  }
}

/// Every tile of `grid` that is walkable and not a stairs tile, in row/column
/// order.
fn non_stairs_walkable_tiles(grid: DeckGrid) -> List(#(Int, Int)) {
  list.index_map(grid.cells, fn(row, y) {
    list.index_map(row, fn(_cell, x) { #(x, y) })
  })
  |> list.flatten
  |> list.filter(fn(t) {
    let #(x, y) = t
    deckplan.is_walkable(grid, x, y)
    && deckplan.tile_at(grid, x, y) != deckplan.Stairs
  })
}

/// Every tile of `grid` carrying slot `marker`, in row/column order.
fn tiles_of_slot(grid: DeckGrid, marker: String) -> List(#(Int, Int)) {
  list.index_map(grid.cells, fn(row, y) {
    list.index_map(row, fn(cell, x) { #(cell.slot, x, y) })
  })
  |> list.flatten
  |> list.filter_map(fn(c) {
    case c.0 == Some(marker) {
      True -> Ok(#(c.1, c.2))
      False -> Error(Nil)
    }
  })
}

/// Flood fill across ONE deck that refuses to ENTER a stairs tile — the
/// deck-preserving half of `walk_from`. A tile reachable only through a
/// stairs tile is not reachable *on this deck*, which is exactly the
/// distinction the whole-ship walk above cannot draw.
fn walk_one_deck(
  grid: DeckGrid,
  queue: List(#(Int, Int)),
  seen: List(#(Int, Int)),
) -> List(#(Int, Int)) {
  case queue {
    [] -> seen
    [tile, ..rest] ->
      case list.contains(seen, tile) {
        True -> walk_one_deck(grid, rest, seen)
        False -> {
          let #(x, y) = tile
          let next =
            [
              #(deckplan.N, 0, -1),
              #(deckplan.S, 0, 1),
              #(deckplan.E, 1, 0),
              #(deckplan.W, -1, 0),
            ]
            |> list.filter_map(fn(step) {
              let #(dir, dx, dy) = step
              let #(nx, ny) = #(x + dx, y + dy)
              case
                deckplan.is_walkable(grid, nx, ny)
                && deckplan.tile_at(grid, nx, ny) != deckplan.Stairs
                && !deckplan.edge_blocks(grid, x, y, dir)
              {
                True -> Ok(#(nx, ny))
                False -> Error(Nil)
              }
            })
          walk_one_deck(grid, list.append(rest, next), [tile, ..seen])
        }
      }
  }
}

// ---------------------------------------------------- shared cabin doc --

/// The claim iteration 2a shipped and this iteration tests: one document,
/// many hulls. If the Goldfinch ever needs a cabin file of her own, this
/// fails and the rule was wrong.
pub fn one_cabin_document_serves_both_hulls_test() {
  let assert Ok(mods) = module.load_all("modules")
  let assert Ok(cabin) = dict.get(mods, "rijay.cabin.standard")
  let hulls = list.unique(list.map(cabin.targets, fn(t) { t.hull }))
  assert list.sort(hulls, string.compare) == ["goldfinch", "mockingbird"]
  let goldfinch_targets =
    list.filter(cabin.targets, fn(t) { t.hull == "goldfinch" })
  assert list.length(goldfinch_targets) == 12
  // And no second cabin document exists anywhere.
  let cabin_docs =
    dict.keys(mods) |> list.filter(fn(id) { string.contains(id, "cabin") })
  assert cabin_docs == ["rijay.cabin.standard"]
}

/// Her whole stock fit resolves: twelve cabins, a galley, a hold, three
/// engines of two different sizes. Her hold capacity comes out at four, one
/// per pallet `rijay.hold.breakbulk_3x2` draws in her 3x2 hold; pinning it
/// here is what stops the hold quietly changing size again. The plan's own
/// pallet count is asserted separately, because `cargo_capacity` alone falls
/// back to the hull's authored number when a plan draws zero pallets — a
/// derived four is indistinguishable from a fallen-back four unless the
/// pallet count is checked directly. (Her authored `cargo.capacity` fallback
/// is two, precisely so it can never be confused with a derived four.)
pub fn her_default_loadout_resolves_test() {
  let assert Ok(h) = hull.load("shipclasses/goldfinch.json")
  let assert Ok(modules) = module.load_all("modules")
  let assert Ok(parts) = part.load_all("parts")
  let assert Ok(fit) =
    loadout.resolve(glyphs.default(), h, modules, parts, loadout.default_for(h))
  assert deckplan.pallet_count(fit.class.plan, glyphs.default()) == 4
  assert fit.class.cargo_capacity == 4
}
