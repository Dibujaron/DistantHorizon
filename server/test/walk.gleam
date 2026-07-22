//// Layout-robust multi-deck walk driver for the sim tests (issue #33). A
//// small breadth-first search over a composite `DeckPlan` — honouring the
//// same `is_walkable`, `edge_blocks` and stairs deck-change rules the sim's
//// `character.step` obeys — yields a tile-by-tile path a character can follow
//// with nothing but move input. The tests navigate whatever layout the sim
//// hands them (decoded from the `space` message) instead of a hardcoded flat
//// route, so a ship growing a deck or a berth moving no longer breaks them.
////
//// Pure geometry only: no sim/process dependency, so it unit-tests directly
//// against a built composite. The follower that actually feeds move input to
//// the running sim lives with the tests in `sim_test.gleam`.

import dh_server/deckplan.{type DeckPlan, type Dir, E, N, S, Stairs, W}
import gleam/dict.{type Dict}
import gleam/list
import gleam/result

/// A single tile on a specific deck (grid index) of the plan.
pub type Node {
  Node(deck: Int, x: Int, y: Int)
}

/// The tile a console sits on, as a path node.
pub fn console_node(plan: DeckPlan, console_id: String) -> Result(Node, Nil) {
  deckplan.find_console(plan, console_id)
  |> result.map(fn(c) { Node(deck: c.deck, x: c.x, y: c.y) })
}

/// Breadth-first path from `start` to `goal` over the plan's walkable tiles,
/// as the list of tiles to move ONTO in order (excluding `start`, ending at
/// `goal`). `Error(Nil)` if no walkable route connects them.
///
/// Edges mirror `character.step`: a cardinal move to a walkable neighbour
/// whose shared edge does not block, and — walking onto a `Stairs` tile from a
/// non-stairs tile — a deck change to `stairs_target`. So a followed path
/// climbs and descends decks exactly where the sim would.
pub fn find_path(
  plan: DeckPlan,
  start: Node,
  goal: Node,
) -> Result(List(Node), Nil) {
  case start == goal {
    True -> Ok([])
    False ->
      // Seed the came-from map with `start` mapped to itself: reconstruction
      // stops there and `start` is left out of the returned path.
      bfs(plan, [start], dict.from_list([#(key(start), start)]), goal)
  }
}

fn key(node: Node) -> #(Int, Int, Int) {
  #(node.deck, node.x, node.y)
}

/// Expand the current frontier one level at a time, recording each freshly
/// discovered tile's predecessor, until `goal` is reached or the reachable
/// set is exhausted.
fn bfs(
  plan: DeckPlan,
  frontier: List(Node),
  came_from: Dict(#(Int, Int, Int), Node),
  goal: Node,
) -> Result(List(Node), Nil) {
  case frontier {
    [] -> Error(Nil)
    _ -> {
      let #(next, came2, found) =
        list.fold(frontier, #([], came_from, False), fn(acc, node) {
          list.fold(neighbors(plan, node), acc, fn(inner, nb) {
            let #(nf, cf, done) = inner
            case done || dict.has_key(cf, key(nb)) {
              True -> inner
              False -> {
                let cf2 = dict.insert(cf, key(nb), node)
                case nb == goal {
                  True -> #(nf, cf2, True)
                  False -> #([nb, ..nf], cf2, done)
                }
              }
            }
          })
        })
      case found {
        True -> Ok(reconstruct(came2, goal, []))
        // `next` was built by prepending, so reverse it back to FIFO order
        // to keep the search breadth-first (shortest tile count).
        False -> bfs(plan, list.reverse(next), came2, goal)
      }
    }
  }
}

/// Walk the came-from map back from `goal` to `start` (which maps to itself),
/// prepending each tile so the result runs start-side first, `start` excluded.
fn reconstruct(
  came_from: Dict(#(Int, Int, Int), Node),
  node: Node,
  acc: List(Node),
) -> List(Node) {
  case dict.get(came_from, key(node)) {
    Error(Nil) -> acc
    Ok(pred) ->
      case pred == node {
        True -> acc
        False -> reconstruct(came_from, pred, [node, ..acc])
      }
  }
}

/// The tiles reachable from `node` in one step: each open cardinal neighbour,
/// with the deck it lands the walker on (the current deck, or the stair's
/// target deck when stepping onto stairs from a non-stairs tile).
fn neighbors(plan: DeckPlan, node: Node) -> List(Node) {
  case deckplan.deck_at(plan, node.deck) {
    Error(Nil) -> []
    Ok(grid) ->
      list.filter_map([N, E, S, W], fn(dir) {
        let #(nx, ny) = step_xy(node.x, node.y, dir)
        case
          deckplan.is_walkable(grid, nx, ny)
          && !deckplan.edge_blocks(grid, node.x, node.y, dir)
        {
          False -> Error(Nil)
          True ->
            Ok(Node(deck: land_deck(plan, grid, node, nx, ny), x: nx, y: ny))
        }
      })
  }
}

/// The deck a walker lands on after stepping to `(nx, ny)`: the stair's
/// target deck when moving onto a stairs tile from a non-stairs tile,
/// otherwise the deck it was already on.
fn land_deck(
  plan: DeckPlan,
  grid: deckplan.DeckGrid,
  node: Node,
  nx: Int,
  ny: Int,
) -> Int {
  case
    deckplan.tile_at(grid, node.x, node.y) != Stairs
    && deckplan.tile_at(grid, nx, ny) == Stairs
  {
    False -> node.deck
    True ->
      deckplan.stairs_target(plan, node.deck, nx, ny)
      |> result.unwrap(node.deck)
  }
}

fn step_xy(x: Int, y: Int, dir: Dir) -> #(Int, Int) {
  case dir {
    N -> #(x, y - 1)
    E -> #(x + 1, y)
    S -> #(x, y + 1)
    W -> #(x - 1, y)
  }
}
