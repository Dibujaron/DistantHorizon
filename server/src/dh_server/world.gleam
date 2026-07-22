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

import dh_server/angle
import dh_server/composite
import dh_server/deckplan
import dh_server/stationclass.{type StationClass}
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile

/// The default on-disk folder of station class documents, mirroring
/// `stationclasses/*.json` (overridable at startup via `DH_STATION_CLASSES`).
pub const default_station_classes_dir = "stationclasses"

const two_pi = 6.283185307179586

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
    /// Resolved from the referenced station class (issue #30).
    dock_radius: Float,
    /// Resolved from the station class: container-crane berths (the fast
    /// handling path; container hulls can only trade where this is True).
    crane: Bool,
    /// Resolved from the station class: walkable concourse interior; None means
    /// crews cannot go ashore. Its `Q` glyphs are the station's berths
    /// (`station_berths`, issue #31).
    concourse: Option(deckplan.DeckPlan),
    /// Per-instance trade terms (stays in the world doc, not the class).
    market: List(MarketEntry),
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

/// Read and decode a world document from a file, resolving each station's
/// `class` reference against the station classes in
/// `default_station_classes_dir`. `path` is resolved relative to the process's
/// working directory.
pub fn load(path: String) -> Result(World, String) {
  use classes <- result.try(stationclass.load_dir(default_station_classes_dir))
  load_with(classes, path)
}

/// `load`, but with an explicit station-class map — the runtime path loads the
/// classes with the active glyph registry and threads them here.
pub fn load_with(
  classes: Dict(String, StationClass),
  path: String,
) -> Result(World, String) {
  use text <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(err) {
      "failed to read world file " <> path <> ": " <> string.inspect(err)
    }),
  )
  decode_with(classes, text)
}

/// Decode a world document, resolving `class` references against
/// `default_station_classes_dir`.
pub fn decode(json_text: String) -> Result(World, String) {
  use classes <- result.try(stationclass.load_dir(default_station_classes_dir))
  decode_with(classes, json_text)
}

/// `decode`, but with an explicit station-class map, validating that every
/// `parent`/`spawn_station`/`class` reference resolves.
pub fn decode_with(
  classes: Dict(String, StationClass),
  json_text: String,
) -> Result(World, String) {
  case json.parse(json_text, world_decoder(classes)) {
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

/// A station's berths, derived from the `Q` docking-port glyphs in its
/// concourse (issue #31): one berth per port, its tile the glyph's position and
/// its `orientation` the world-degree direction of the edge whose door faces
/// void. Empty if the station has no concourse or no ports. This is the single
/// source of docking geometry — no separate authored list.
pub fn station_berths(station: Station) -> List(composite.Berth) {
  case station.concourse {
    None -> []
    Some(plan) ->
      case deckplan.docking_ports(plan) {
        // Ports are validated at load; if somehow malformed, treat as none.
        Error(_) -> []
        Ok(ports) ->
          list.map(ports, fn(p) {
            let #(_deck, x, y, dir) = p
            composite.Berth(x: x, y: y, orientation: orientation_of(dir))
          })
      }
  }
}

/// A station's berth by index, or `Error(Nil)` if the station or index is
/// unknown.
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
        True -> list.drop(station_berths(station), index) |> list.first
      }
  }
}

/// The world outward normal (DEGREES, y-up, 0 = +x/east) for a berth whose
/// outer door faces `dir` in the concourse grid (y-down). North (a berth mouth
/// open to the void above the concourse) yields 90° — the side-on look.
fn orientation_of(dir: deckplan.Dir) -> Float {
  case dir {
    deckplan.N -> 90.0
    deckplan.E -> 0.0
    deckplan.S -> -90.0
    deckplan.W -> 180.0
  }
}

/// The moored sim pose of a ship docked in `berth_index` at `station_id` at
/// sim time `t`: `#(x, y, vx, vy)`. Position is the station centre, plus the
/// berth tile's planar offset (the concourse is 1 m/tile, centred on the
/// station), plus `standoff` metres out along the berth's outward normal —
/// `standoff` being the docking ship's own `dock_standoff` (issue #31). This is
/// the pose a docked ship is pinned to each tick AND released at on undock, so
/// undocking never teleports the hull (issue #13). Velocity is the station's
/// rail velocity (a docked hull rides the rail). Falls back to the bare station
/// pose when the berth is unknown — e.g. a test station with no ports.
pub fn moored_position(
  world: World,
  station_id: String,
  berth_index: Int,
  standoff: Float,
  t: Float,
) -> #(Float, Float, Float, Float) {
  let #(cx, cy) = station_position(world, station_id, t)
  let #(vx, vy) = station_velocity(world, station_id, t)
  case
    get_station(world, station_id),
    station_berth(world, station_id, berth_index)
  {
    Ok(station), Ok(berth) -> {
      let #(w, h) = concourse_dims(station)
      let #(ox, oy) = berth_planar_offset(berth.x, berth.y, w, h)
      // Berth orientation is degrees; `cos`/`sin` need radians.
      let normal = angle.deg_to_rad(berth.orientation)
      let nx = cos(normal)
      let ny = sin(normal)
      #(cx +. ox +. nx *. standoff, cy +. oy +. ny *. standoff, vx, vy)
    }
    _, _ -> #(cx, cy, vx, vy)
  }
}

/// The concourse's tile dimensions (deck 0), or `#(0, 0)` if none.
fn concourse_dims(station: Station) -> #(Int, Int) {
  case station.concourse {
    None -> #(0, 0)
    Some(plan) ->
      case deckplan.deck_at(plan, 0) {
        Ok(g) -> #(g.width, g.height)
        Error(Nil) -> #(0, 0)
      }
  }
}

/// The berth tile's world-space offset from the station centre, in metres
/// (1 m/tile), with the concourse centred on the station. Tile x runs east
/// (world +x); tile y runs south (world -y), so a berth near the concourse top
/// sits north (+y) of centre.
fn berth_planar_offset(bx: Int, by: Int, w: Int, h: Int) -> #(Float, Float) {
  let ox = int.to_float(bx) +. 0.5 -. int.to_float(w) /. 2.0
  let oy = int.to_float(h) /. 2.0 -. { int.to_float(by) +. 0.5 }
  #(ox, oy)
}

/// The world heading (DEGREES) a ship holds while moored in `berth_index` at
/// `station_id`: derived so the ship's docking port faces back into the
/// station. From the berth's outward normal and the docking ship's own
/// `ship_port` normal (its class `dock_port_orientation`, ship-local degrees):
/// `heading = berth.orientation + 180 - ship_port`. The side-on case (berth
/// north 90°, port flank ship_port 90°) yields 180° — nose west, M3.5's look.
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
    Error(Nil) -> composite.default_orientation_deg
  }
  orientation +. 180.0 -. ship_port
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
        True -> validate_trade(world)
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
        |> result.try(deckplan.validate_docking_ports)
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

/// Decode one world station instance: per-instance placement/economy plus a
/// `class` reference resolved against `classes` (issue #30). The resolved
/// station carries the class's `dock_radius`/`crane`/`concourse`; berths are
/// derived from the concourse's `Q` glyphs at use (`station_berths`). An
/// unknown class id fails the decode.
fn station_decoder(
  classes: Dict(String, StationClass),
) -> decode.Decoder(Station) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use parent <- decode.field("parent", decode.string)
  use orbit <- decode.field("orbit", orbit_decoder())
  use class_id <- decode.field("class", decode.string)
  use market <- decode.optional_field(
    "market",
    [],
    decode.list(market_entry_decoder()),
  )
  case dict.get(classes, class_id) {
    Ok(sc) ->
      decode.success(Station(
        id: id,
        name: name,
        parent: parent,
        orbit: orbit,
        dock_radius: sc.dock_radius,
        crane: sc.crane,
        concourse: Some(sc.concourse),
        market: market,
      ))
    Error(Nil) ->
      decode.failure(
        Station(id, name, parent, orbit, 0.0, False, None, market),
        "known station class id (got \"" <> class_id <> "\")",
      )
  }
}

fn world_decoder(classes: Dict(String, StationClass)) -> decode.Decoder(World) {
  use schema <- decode.field("schema", decode.int)
  use name <- decode.field("name", decode.string)
  use seed <- decode.field("seed", decode.int)
  use commodities <- decode.optional_field(
    "commodities",
    [],
    decode.list(commodity_decoder()),
  )
  use bodies <- decode.field("bodies", decode.list(body_decoder()))
  use stations <- decode.field(
    "stations",
    decode.list(station_decoder(classes)),
  )
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

/// Encode a station for the `welcome` wire: the fully RESOLVED station (its
/// class's concourse/dock_radius/crane inlined) plus its derived berths — NOT
/// the on-disk `class` reference. The client gets everything it needs to render
/// without resolving station classes; the class indirection is an on-disk
/// authoring concern only. (So `encode` and `decode` are intentionally
/// asymmetric: decode reads a `class` ref, encode emits the resolved station.)
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
    #("berths", json.array(station_berths(station), encode_berth)),
  ])
}

/// A derived berth on the wire: its tile and outward orientation (degrees). The moored
/// pose is computed client-side (sprite anchors) and server-side
/// (`moored_position`); there is no anchor to send.
fn encode_berth(berth: composite.Berth) -> Json {
  json.object([
    #("tile", json.preprocessed_array([json.int(berth.x), json.int(berth.y)])),
    #("orientation", json.float(berth.orientation)),
  ])
}
