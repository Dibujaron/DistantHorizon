import dh_server/deckplan.{type DeckPlan}
import dh_server/glyphs
import dh_server/hull
import dh_server/loadout
import dh_server/module
import dh_server/part
import gleam/dict
import gleam/int
import gleam/list
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
/// sixteen a single hex slot digit can express.
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
  // Two columns of two decks each: (2,9) Mezzanine<->Lower, (2,11)
  // Upper<->Mezzanine. Never one column of three.
  assert stairs == [#(0, 2, 11), #(1, 2, 9), #(1, 2, 11), #(2, 2, 9)]
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
/// engines of two different sizes.
pub fn her_default_loadout_resolves_test() {
  let assert Ok(h) = hull.load("shipclasses/goldfinch.json")
  let assert Ok(modules) = module.load_all("modules")
  let assert Ok(parts) = part.load_all("parts")
  let assert Ok(_) =
    loadout.resolve(glyphs.default(), h, modules, parts, loadout.default_for(h))
}
