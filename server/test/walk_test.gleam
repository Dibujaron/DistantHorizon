//// Unit tests for the BFS walk pathfinder (issue #33) against the real
//// Meridian Highport + Mockingbird composite, so the driver is exercised on
//// the actual multi-deck layout the sim tests navigate — not a toy grid.

import dh_server/composite
import dh_server/deckplan
import dh_server/shipclass
import dh_server/world
import gleam/int
import gleam/list
import gleam/option.{Some}
import walk

/// Build the composite the sim login produces: Meridian Highport's concourse
/// with one Mockingbird moored at `berth`.
fn build_composite(berth: Int) -> #(deckplan.DeckPlan, Int) {
  let assert Ok(w) = world.load("worlds/m1_system.json")
  let assert Ok(class) = shipclass.load("shipclasses/mockingbird.json")
  let assert Ok(station) = world.get_station(w, "meridian_highport")
  let assert Some(concourse) = station.concourse
  let assert Ok(built) =
    composite.build(concourse, world.station_berths(station), [
      composite.DockedShip(ship_id: 1, berth: berth, plan: class.plan),
    ])
  #(built.plan, 1)
}

/// Whether every hop in a path is a legal one-tile move on the plan: cardinal
/// step to a walkable neighbour whose shared edge is open, with the deck only
/// changing where a stairs tile is stepped onto.
fn path_is_legal(
  plan: deckplan.DeckPlan,
  from: walk.Node,
  path: List(walk.Node),
) -> Bool {
  case path {
    [] -> True
    [next, ..rest] ->
      case hop_is_legal(plan, from, next) {
        False -> False
        True -> path_is_legal(plan, next, rest)
      }
  }
}

fn hop_is_legal(plan: deckplan.DeckPlan, a: walk.Node, b: walk.Node) -> Bool {
  let dx = b.x - a.x
  let dy = b.y - a.y
  let cardinal = int.absolute_value(dx) + int.absolute_value(dy) == 1
  let dir = case dx, dy {
    1, _ -> deckplan.E
    -1, _ -> deckplan.W
    _, 1 -> deckplan.S
    _, _ -> deckplan.N
  }
  case deckplan.deck_at(plan, a.deck) {
    Error(Nil) -> False
    Ok(grid) ->
      cardinal
      && deckplan.is_walkable(grid, b.x, b.y)
      && !deckplan.edge_blocks(grid, a.x, a.y, dir)
      && b.deck == expected_land_deck(plan, grid, a, b)
  }
}

fn expected_land_deck(
  plan: deckplan.DeckPlan,
  grid: deckplan.DeckGrid,
  a: walk.Node,
  b: walk.Node,
) -> Int {
  case
    deckplan.tile_at(grid, a.x, a.y) != deckplan.Stairs
    && deckplan.tile_at(grid, b.x, b.y) == deckplan.Stairs
  {
    False -> a.deck
    True ->
      case deckplan.stairs_target(plan, a.deck, b.x, b.y) {
        Ok(t) -> t
        Error(Nil) -> a.deck
      }
  }
}

pub fn path_from_spawn_to_broker_is_a_legal_multideck_walk_test() {
  let #(plan, _ship) = build_composite(0)
  let #(sx, sy) = plan.spawn_tile
  let start = walk.Node(deck: plan.spawn_deck, x: sx, y: sy)
  let assert Ok(goal) = walk.console_node(plan, "broker0")
  let assert Ok(path) = walk.find_path(plan, start, goal)
  let assert Ok(last) = list.last(path)
  assert last == goal
  assert path_is_legal(plan, start, path)
}

pub fn path_from_helm_to_broker_crosses_decks_test() {
  let #(plan, ship) = build_composite(0)
  let assert Ok(helm) =
    walk.console_node(plan, composite.namespace_id(ship, "helm"))
  let assert Ok(goal) = walk.console_node(plan, "broker0")
  let assert Ok(path) = walk.find_path(plan, helm, goal)
  // The helm sits on the ship's upper deck; the broker on the concourse plane
  // — so any real path must change deck at least once.
  assert list.any(path, fn(n) { n.deck != helm.deck })
  assert path_is_legal(plan, helm, path)
}
