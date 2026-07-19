//// The world document: one star system (star, planets, stations) loaded
//// from a hand-authored JSON file at startup. Planets and stations sit on
//// analytic circular-orbit "rails" — their position/velocity at any sim
//// time `t` is computed from the orbit parameters, never simulated tick by
//// tick, and they are never sent in snapshots. Clients receive the world
//// document once (in `welcome`) and recompute rail positions locally.
////
//// Orbit semantics (parents chain: station -> planet -> star):
////   angle(t) = phase * 2*pi + 2*pi * t / period_s
////   position(t) = parent_position(t) + radius * (cos(angle), sin(angle))
////   velocity(t) = parent_velocity(t)
////     + (2*pi*radius/period_s) * (-sin(angle), cos(angle))
//// The star has no orbit: position (0,0), velocity (0,0).
////
//// Gravity: every body (never stations) with mu > 0 pulls ships toward it
//// along the true unit vector, with magnitude `mu / max(r, body_radius)^2`
//// — the denominator is clamped at the body's radius so the pull holds
//// flat (never blows up) inside the body. At the exact centre (r = 0) the
//// direction is undefined and the body contributes nothing.

import dh_server/composite
import dh_server/deckplan
import dh_server/glyphs.{type Registry}
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile

const two_pi = 6.283185307179586

const pi = 3.141592653589793

pub type Orbit {
  Orbit(radius: Float, period_s: Float, phase: Float)
}

pub type Body {
  Body(
    id: String,
    name: String,
    kind: String,
    parent: Option(String),
    orbit: Option(Orbit),
    radius: Float,
    mu: Float,
  )
}

pub type Commodity {
  Commodity(id: String, name: String)
}

/// A station's dealing terms for one commodity: starting stock, base
/// price, and how far the noise walk may swing the price (Classic's
/// initial/price/elasticity triple from Stn_*.properties).
pub type MarketEntry {
  MarketEntry(commodity: String, initial: Int, price: Int, elasticity: Int)
}

pub type Station {
  Station(
    id: String,
    name: String,
    parent: String,
    orbit: Orbit,
    dock_radius: Float,
    /// Container-crane berths (the fast handling path; container hulls can
    /// only trade where this is True).
    crane: Bool,
    /// Walkable concourse interior; None means crews cannot go ashore.
    concourse: Option(deckplan.DeckPlan),
    market: List(MarketEntry),
    /// Authored mooring anchors on the concourse's top edge; empty = ships
    /// cannot dock here (M3.1).
    berths: List(composite.Berth),
  )
}

pub type World {
  World(
    schema: Int,
    name: String,
    seed: Int,
    commodities: List(Commodity),
    bodies: List(Body),
    stations: List(Station),
    spawn_station: String,
  )
}

@external(erlang, "math", "cos")
fn cos(x: Float) -> Float

@external(erlang, "math", "sin")
fn sin(x: Float) -> Float

/// Read and decode a world document from a file, using the built-in glyph
/// legend. `path` is resolved relative to the process's working directory.
pub fn load(path: String) -> Result(World, String) {
  load_with(glyphs.default(), path)
}

/// `load`, but interpreting station concourse grids with an explicit glyph
/// registry — the runtime path threads the loaded `glyphs.json` here.
pub fn load_with(reg: Registry, path: String) -> Result(World, String) {
  use text <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(err) {
      "failed to read world file " <> path <> ": " <> string.inspect(err)
    }),
  )
  decode_with(reg, text)
}

/// Decode a world document (built-in glyph legend), validating that every
/// `parent` and `spawn_station` reference an id that actually exists.
pub fn decode(json_text: String) -> Result(World, String) {
  decode_with(glyphs.default(), json_text)
}

/// `decode`, but interpreting station concourse grids with an explicit glyph
/// registry.
pub fn decode_with(reg: Registry, json_text: String) -> Result(World, String) {
  case json.parse(json_text, world_decoder(reg)) {
    Ok(world) -> validate(world)
    Error(err) -> Error("invalid world document: " <> string.inspect(err))
  }
}

/// Encode a world document, e.g. for the `welcome` message.
pub fn encode(world: World) -> Json {
  json.object([
    #("schema", json.int(world.schema)),
    #("name", json.string(world.name)),
    #("seed", json.int(world.seed)),
    #("commodities", json.array(world.commodities, encode_commodity)),
    #("bodies", json.array(world.bodies, encode_body)),
    #("stations", json.array(world.stations, encode_station)),
    #("spawn_station", json.string(world.spawn_station)),
  ])
}

/// Position of a body (star or planet) at sim time `t`, chaining through
/// its parent. Panics if `body_id` does not exist in `world`.
pub fn body_position(
  world: World,
  body_id: String,
  t: Float,
) -> #(Float, Float) {
  let assert Ok(body) = find_body(world, body_id)
  case body.orbit {
    None -> #(0.0, 0.0)
    Some(orbit) -> {
      let #(px, py) = case body.parent {
        Some(parent_id) -> body_position(world, parent_id, t)
        None -> #(0.0, 0.0)
      }
      let angle = orbit_angle(orbit, t)
      #(px +. orbit.radius *. cos(angle), py +. orbit.radius *. sin(angle))
    }
  }
}

/// Position of a station at sim time `t`, chaining through its parent
/// body. Panics if `station_id` does not exist in `world`.
pub fn station_position(
  world: World,
  station_id: String,
  t: Float,
) -> #(Float, Float) {
  let assert Ok(station) = get_station(world, station_id)
  let #(px, py) = body_position(world, station.parent, t)
  let angle = orbit_angle(station.orbit, t)
  #(
    px +. station.orbit.radius *. cos(angle),
    py +. station.orbit.radius *. sin(angle),
  )
}

/// Velocity of a station at sim time `t`, the analytic derivative of
/// `station_position`. Panics if `station_id` does not exist in `world`.
pub fn station_velocity(
  world: World,
  station_id: String,
  t: Float,
) -> #(Float, Float) {
  let assert Ok(station) = get_station(world, station_id)
  let #(pvx, pvy) = body_velocity(world, station.parent, t)
  let angle = orbit_angle(station.orbit, t)
  let omega_r = two_pi *. station.orbit.radius /. station.orbit.period_s
  #(pvx -. omega_r *. sin(angle), pvy +. omega_r *. cos(angle))
}

/// Look up a station by id.
pub fn get_station(world: World, station_id: String) -> Result(Station, Nil) {
  list.find(world.stations, fn(s) { s.id == station_id })
}

/// A station's berth by index (its docking-port record), or `Error(Nil)` if
/// the station or index is unknown.
pub fn station_berth(
  world: World,
  station_id: String,
  index: Int,
) -> Result(composite.Berth, Nil) {
  case get_station(world, station_id) {
    Error(Nil) -> Error(Nil)
    Ok(station) ->
      case index >= 0 {
        False -> Error(Nil)
        True -> list.drop(station.berths, index) |> list.first
      }
  }
}

/// The exterior mooring pose of a ship docked in `berth_index` at
/// `station_id` at sim time `t`: `#(x, y, vx, vy)` where position is the
/// station centre plus the berth's authored world anchor, and velocity is the
/// station's rail velocity (a docked hull rides the rail). This is the pose a
/// docked ship is pinned to each tick AND released at on undock, so undocking
/// never teleports the hull toward the station centre (issue #13). Falls back
/// to the bare station pose (centre + rail velocity) when the berth is unknown
/// — e.g. a test station with no authored berths — so a hull still moors
/// rather than the lookup crashing.
pub fn moored_position(
  world: World,
  station_id: String,
  berth_index: Int,
  t: Float,
) -> #(Float, Float, Float, Float) {
  let #(cx, cy) = station_position(world, station_id, t)
  let #(vx, vy) = station_velocity(world, station_id, t)
  case station_berth(world, station_id, berth_index) {
    Error(Nil) -> #(cx, cy, vx, vy)
    Ok(berth) -> #(cx +. berth.anchor_x, cy +. berth.anchor_y, vx, vy)
  }
}

/// The world heading a ship holds while moored in `berth_index` at
/// `station_id`: derived so the ship's docking port faces back into the
/// station. From the berth's outward normal and the docking ship's own
/// `ship_port` normal (its class `dock_port_orientation`, ship-local radians):
/// `heading = berth.orientation + pi - ship_port`. The side-on case (berth
/// north, port flank ship_port = pi/2) yields pi — nose west, M3.5's look.
/// Unknown berths fall back to the default berth orientation. Replacing the
/// client's and exterior's hardcoded side-on rotation, this is what generalises
/// mooring to nose-in / arbitrary approaches (issue #14) and to ships whose
/// own dock port differs from the Mockingbird's.
pub fn moored_heading(
  world: World,
  station_id: String,
  berth_index: Int,
  ship_port: Float,
) -> Float {
  let orientation = case station_berth(world, station_id, berth_index) {
    Ok(berth) -> berth.orientation
    Error(Nil) -> composite.default_orientation
  }
  orientation +. pi -. ship_port
}

/// Summed gravitational acceleration from every body with `mu > 0` at
/// point `(x, y)` and sim time `t`.
pub fn gravity_at(
  world: World,
  x: Float,
  y: Float,
  t: Float,
) -> #(Float, Float) {
  list.fold(world.bodies, #(0.0, 0.0), fn(acc, body) {
    case body.mu >. 0.0 {
      False -> acc
      True -> {
        let #(ax, ay) = acc
        let #(bx, by) = body_position(world, body.id, t)
        let dx = bx -. x
        let dy = by -. y
        let assert Ok(r) = float.square_root(dx *. dx +. dy *. dy)
        case r == 0.0 {
          // At the exact centre the direction is undefined; no pull.
          True -> acc
          False -> {
            let r_clamped = float.max(r, body.radius)
            let a_mag = body.mu /. { r_clamped *. r_clamped }
            #(ax +. a_mag *. dx /. r, ay +. a_mag *. dy /. r)
          }
        }
      }
    }
  })
}

fn orbit_angle(orbit: Orbit, t: Float) -> Float {
  orbit.phase *. two_pi +. two_pi *. t /. orbit.period_s
}

/// Velocity of a body (star or planet) at sim time `t`, chaining through
/// its parent. Panics if `body_id` does not exist in `world`.
fn body_velocity(world: World, body_id: String, t: Float) -> #(Float, Float) {
  let assert Ok(body) = find_body(world, body_id)
  case body.orbit {
    None -> #(0.0, 0.0)
    Some(orbit) -> {
      let #(pvx, pvy) = case body.parent {
        Some(parent_id) -> body_velocity(world, parent_id, t)
        None -> #(0.0, 0.0)
      }
      let angle = orbit_angle(orbit, t)
      let omega_r = two_pi *. orbit.radius /. orbit.period_s
      #(pvx -. omega_r *. sin(angle), pvy +. omega_r *. cos(angle))
    }
  }
}

fn find_body(world: World, body_id: String) -> Result(Body, Nil) {
  list.find(world.bodies, fn(b) { b.id == body_id })
}

/// Every `parent` (on bodies and stations) and `spawn_station` must
/// reference an id that exists in the document.
fn validate(world: World) -> Result(World, String) {
  let body_ids = list.map(world.bodies, fn(b) { b.id })
  let station_ids = list.map(world.stations, fn(s) { s.id })

  let bad_body_parent =
    list.find(world.bodies, fn(b) {
      case b.parent {
        Some(parent_id) -> !list.contains(body_ids, parent_id)
        None -> False
      }
    })
  let bad_station_parent =
    list.find(world.stations, fn(s) { !list.contains(body_ids, s.parent) })

  case bad_body_parent, bad_station_parent {
    Ok(body), _ -> {
      let assert Some(parent_id) = body.parent
      Error("unknown parent body id: " <> parent_id)
    }
    _, Ok(station) -> Error("unknown parent body id: " <> station.parent)
    Error(Nil), Error(Nil) ->
      case list.contains(station_ids, world.spawn_station) {
        True -> validate_trade(world) |> result.try(validate_berths)
        False -> Error("unknown spawn_station id: " <> world.spawn_station)
      }
  }
}

/// Trade-layer validation: markets reference declared commodities; every
/// concourse is geometrically valid; a station that trades has somewhere
/// to trade (a concourse with a broker-kind console).
fn validate_trade(world: World) -> Result(World, String) {
  let commodity_ids = list.map(world.commodities, fn(c) { c.id })
  list.fold(world.stations, Ok(world), fn(acc, station) {
    use _ <- result.try(acc)
    use _ <- result.try(case station.concourse {
      None -> Ok(world)
      Some(plan) ->
        deckplan.validate(plan)
        |> result.map_error(fn(e) {
          "station " <> station.id <> " concourse: " <> e
        })
        |> result.map(fn(_) { world })
    })
    use _ <- result.try(
      case
        list.find(station.market, fn(entry) {
          !list.contains(commodity_ids, entry.commodity)
        })
      {
        Ok(entry) ->
          Error(
            "station "
            <> station.id
            <> " trades unknown commodity: "
            <> entry.commodity,
          )
        Error(Nil) -> Ok(world)
      },
    )
    case station.market, station.concourse {
      [], _ -> Ok(world)
      [_, ..], None ->
        Error("station " <> station.id <> " has a market but no concourse")
      [_, ..], Some(plan) ->
        case deckplan.find_console_of_kind(plan, "broker") {
          Ok(_) -> Ok(world)
          Error(Nil) ->
            Error(
              "station " <> station.id <> " has a market but no broker console",
            )
        }
    }
  })
}

/// Berth validation: a station that declares berths must have a
/// concourse; every berth tile must be walkable, and the tile directly
/// north of it must NOT be walkable (that's where the moored airlock
/// lands, and it must not overlap the concourse floor).
fn validate_berths(world: World) -> Result(World, String) {
  list.fold(world.stations, Ok(world), fn(acc, station) {
    use _ <- result.try(acc)
    case station.berths, station.concourse {
      [], _ -> Ok(world)
      [_, ..], None ->
        Error("station " <> station.id <> " has berths but no concourse")
      berths, Some(plan) ->
        list.fold(berths, Ok(world), fn(acc2, berth) {
          use _ <- result.try(acc2)
          let label =
            "station "
            <> station.id
            <> " berth ("
            <> int.to_string(berth.x)
            <> ","
            <> int.to_string(berth.y)
            <> ")"
          // Concourses are single-deck (index 0); berths land on that plane.
          case deckplan.deck_at(plan, 0) {
            Error(Nil) -> Error(label <> ": concourse has no decks")
            Ok(g) ->
              case deckplan.is_walkable(g, berth.x, berth.y) {
                False -> Error(label <> " is not walkable")
                True ->
                  case deckplan.is_walkable(g, berth.x, berth.y - 1) {
                    True -> Error(label <> " has a walkable north neighbor")
                    False -> Ok(world)
                  }
              }
          }
        })
    }
  })
}

fn orbit_decoder() -> decode.Decoder(Orbit) {
  use radius <- decode.field("radius", decode.float)
  use period_s <- decode.field("period_s", decode.float)
  use phase <- decode.field("phase", decode.float)
  decode.success(Orbit(radius: radius, period_s: period_s, phase: phase))
}

fn body_decoder() -> decode.Decoder(Body) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use kind <- decode.field("kind", decode.string)
  use parent <- decode.field("parent", decode.optional(decode.string))
  use orbit <- decode.field("orbit", decode.optional(orbit_decoder()))
  use radius <- decode.field("radius", decode.float)
  use mu <- decode.field("mu", decode.float)
  decode.success(Body(
    id: id,
    name: name,
    kind: kind,
    parent: parent,
    orbit: orbit,
    radius: radius,
    mu: mu,
  ))
}

fn commodity_decoder() -> decode.Decoder(Commodity) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  decode.success(Commodity(id: id, name: name))
}

fn market_entry_decoder() -> decode.Decoder(MarketEntry) {
  use commodity <- decode.field("commodity", decode.string)
  use initial <- decode.field("initial", decode.int)
  use price <- decode.field("price", decode.int)
  use elasticity <- decode.field("elasticity", decode.int)
  decode.success(MarketEntry(
    commodity: commodity,
    initial: initial,
    price: price,
    elasticity: elasticity,
  ))
}

fn station_decoder(reg: Registry) -> decode.Decoder(Station) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use parent <- decode.field("parent", decode.string)
  use orbit <- decode.field("orbit", orbit_decoder())
  use dock_radius <- decode.field("dock_radius", decode.float)
  use crane <- decode.optional_field("crane", False, decode.bool)
  use concourse <- decode.optional_field(
    "concourse",
    None,
    decode.optional(deckplan.decoder(reg)),
  )
  use market <- decode.optional_field(
    "market",
    [],
    decode.list(market_entry_decoder()),
  )
  use berths <- decode.optional_field(
    "berths",
    [],
    decode.list(berth_decoder()),
  )
  decode.success(Station(
    id: id,
    name: name,
    parent: parent,
    orbit: orbit,
    dock_radius: dock_radius,
    crane: crane,
    concourse: concourse,
    market: market,
    berths: berths,
  ))
}

/// Decode one authored docking port. Object form:
/// `{"tile":[x,y], "orientation":F?, "anchor":[ax,ay]?}` — `tile` required,
/// `orientation`/`anchor` optional (default: side-on north, zero anchor, i.e.
/// M3.5's centre-pinned side-on mooring). A bare legacy `[x, y]` array is
/// still accepted and takes those same defaults, so pre-#14 world docs load
/// unchanged.
fn berth_decoder() -> decode.Decoder(composite.Berth) {
  decode.one_of(berth_object_decoder(), or: [berth_tuple_decoder()])
}

fn berth_object_decoder() -> decode.Decoder(composite.Berth) {
  use tile <- decode.field("tile", decode.list(decode.int))
  use orientation <- decode.optional_field(
    "orientation",
    composite.default_orientation,
    decode.float,
  )
  use anchor <- decode.optional_field(
    "anchor",
    [0.0, 0.0],
    decode.list(decode.float),
  )
  let #(ax, ay) = case anchor {
    [x, y] -> #(x, y)
    _ -> #(0.0, 0.0)
  }
  case tile {
    [x, y] ->
      decode.success(composite.Berth(
        x: x,
        y: y,
        orientation: orientation,
        anchor_x: ax,
        anchor_y: ay,
      ))
    _ ->
      decode.failure(
        composite.Berth(0, 0, composite.default_orientation, 0.0, 0.0),
        "berth object with a two-element tile [x, y]",
      )
  }
}

fn berth_tuple_decoder() -> decode.Decoder(composite.Berth) {
  use coords <- decode.then(decode.list(decode.int))
  case coords {
    [x, y] ->
      decode.success(composite.Berth(
        x: x,
        y: y,
        orientation: composite.default_orientation,
        anchor_x: 0.0,
        anchor_y: 0.0,
      ))
    _ ->
      decode.failure(
        composite.Berth(0, 0, composite.default_orientation, 0.0, 0.0),
        "two-element [x, y] array",
      )
  }
}

fn world_decoder(reg: Registry) -> decode.Decoder(World) {
  use schema <- decode.field("schema", decode.int)
  use name <- decode.field("name", decode.string)
  use seed <- decode.field("seed", decode.int)
  use commodities <- decode.optional_field(
    "commodities",
    [],
    decode.list(commodity_decoder()),
  )
  use bodies <- decode.field("bodies", decode.list(body_decoder()))
  use stations <- decode.field("stations", decode.list(station_decoder(reg)))
  use spawn_station <- decode.field("spawn_station", decode.string)
  decode.success(World(
    schema: schema,
    name: name,
    seed: seed,
    commodities: commodities,
    bodies: bodies,
    stations: stations,
    spawn_station: spawn_station,
  ))
}

fn encode_orbit(orbit: Orbit) -> Json {
  json.object([
    #("radius", json.float(orbit.radius)),
    #("period_s", json.float(orbit.period_s)),
    #("phase", json.float(orbit.phase)),
  ])
}

fn encode_body(body: Body) -> Json {
  json.object([
    #("id", json.string(body.id)),
    #("name", json.string(body.name)),
    #("kind", json.string(body.kind)),
    #("parent", json.nullable(body.parent, json.string)),
    #("orbit", json.nullable(body.orbit, encode_orbit)),
    #("radius", json.float(body.radius)),
    #("mu", json.float(body.mu)),
  ])
}

fn encode_commodity(commodity: Commodity) -> Json {
  json.object([
    #("id", json.string(commodity.id)),
    #("name", json.string(commodity.name)),
  ])
}

fn encode_market_entry(entry: MarketEntry) -> Json {
  json.object([
    #("commodity", json.string(entry.commodity)),
    #("initial", json.int(entry.initial)),
    #("price", json.int(entry.price)),
    #("elasticity", json.int(entry.elasticity)),
  ])
}

fn encode_station(station: Station) -> Json {
  json.object([
    #("id", json.string(station.id)),
    #("name", json.string(station.name)),
    #("parent", json.string(station.parent)),
    #("orbit", encode_orbit(station.orbit)),
    #("dock_radius", json.float(station.dock_radius)),
    #("crane", json.bool(station.crane)),
    #("concourse", json.nullable(station.concourse, deckplan.encode)),
    #("market", json.array(station.market, encode_market_entry)),
    #("berths", json.array(station.berths, encode_berth)),
  ])
}

fn encode_berth(berth: composite.Berth) -> Json {
  json.object([
    #("tile", json.preprocessed_array([json.int(berth.x), json.int(berth.y)])),
    #("orientation", json.float(berth.orientation)),
    #(
      "anchor",
      json.preprocessed_array([
        json.float(berth.anchor_x),
        json.float(berth.anchor_y),
      ]),
    ),
  ])
}
