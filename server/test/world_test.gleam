import dh_server/composite
import dh_server/stationclass.{type StationClass}
import dh_server/world.{type World, Body, Orbit, Station, World}
import gleam/dict.{type Dict}
import gleam/float
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/string

const two_pi = 6.283185307179586

const epsilon = 0.000001

@external(erlang, "math", "cos")
fn cos(x: Float) -> Float

@external(erlang, "math", "sin")
fn sin(x: Float) -> Float

fn close(a: Float, b: Float) -> Bool {
  float.absolute_value(a -. b) <. epsilon
}

/// A single stationary star, no stations. Isolates gravity math from the
/// rest of the pinned system.
fn star_only_world() -> World {
  World(
    schema: 1,
    name: "star only",
    seed: 1,
    commodities: [],
    bodies: [
      Body(
        id: "star",
        name: "Star",
        kind: "star",
        parent: None,
        orbit: None,
        radius: 500.0,
        mu: 20_000_000.0,
      ),
    ],
    stations: [],
    spawn_station: "n/a",
  )
}

/// A single station orbiting a stationary body directly. Isolates the
/// station's own analytic velocity term from any parent-body motion.
fn station_only_world() -> World {
  World(
    schema: 1,
    name: "station only",
    seed: 1,
    commodities: [],
    bodies: [
      Body(
        id: "anchor",
        name: "Anchor",
        kind: "star",
        parent: None,
        orbit: None,
        radius: 100.0,
        mu: 0.0,
      ),
    ],
    stations: [
      Station(
        id: "s1",
        name: "S1",
        parent: "anchor",
        orbit: Orbit(radius: 400.0, period_s: 180.0, phase: 0.0),
        dock_radius: 100.0,
        crane: False,
        concourse: None,
        market: [],
      ),
    ],
    spawn_station: "s1",
  )
}

pub fn load_bundled_world_test() {
  let assert Ok(w) = world.load("worlds/m1_system.json")
  assert w.schema == 2
  assert list.length(w.bodies) == 3
  assert list.length(w.stations) == 2
  assert w.spawn_station == "meridian_highport"
}

pub fn encode_emits_resolved_stations_for_the_wire_test() {
  // encode is intentionally asymmetric with decode: the on-disk world
  // references station classes, but the welcome wire carries fully RESOLVED
  // stations (concourse + derived berths inlined) so the client needs no
  // class resolution. The `class` indirection never reaches the wire.
  let assert Ok(w) = world.load("worlds/m1_system.json")
  let text = world.encode(w) |> json.to_string
  assert string.contains(text, "\"concourse\"")
  assert string.contains(text, "\"berths\"")
  assert !string.contains(text, "\"class\"")
}

pub fn decode_rejects_unknown_spawn_station_test() {
  let bad = one_station_world("bare", "[]", "nonexistent")
  assert world.decode_with(station_classes(), bad) |> is_error
}

pub fn decode_rejects_unknown_class_id_test() {
  let bad = one_station_world("no_such_class", "[]", "stn")
  assert world.decode_with(station_classes(), bad) |> is_error
}

fn is_error(result: Result(a, b)) -> Bool {
  case result {
    Error(_) -> True
    Ok(_) -> False
  }
}

// -------------------------------------------------- station-class fixtures --

/// A 3x2 concourse deck grid with a broker wall-console: the `b` fixture sits on
/// the north edge (row 0, column 4) of tile (1, 0), which is the floor tile it is
/// operated from. Consoles are wall (edge) fixtures now, not centre glyphs.
const broker_concourse_grid = "[\"    b    \",\"         \",\"         \",\"         \",\"         \",\"         \"]"

/// The same, with no broker console at all.
const bare_concourse_grid = "[\"         \",\"         \",\"         \",\"         \",\"         \",\"         \"]"

/// Test station classes: "trader" has a broker console, "bare" has none.
fn station_classes() -> Dict(String, StationClass) {
  dict.from_list([
    #("trader", class_with_grid("trader", broker_concourse_grid)),
    #("bare", class_with_grid("bare", bare_concourse_grid)),
  ])
}

fn class_with_grid(id: String, grid: String) -> StationClass {
  let doc =
    "{\"schema\":1,\"id\":\""
    <> id
    <> "\",\"name\":\"C\",\"dock_radius\":10.0,"
    <> "\"decks\":[{\"name\":\"c\",\"grid\":"
    <> grid
    <> "}]}"
  let assert Ok(sc) = stationclass.decode(doc)
  sc
}

/// A one-station world referencing class `class_id`, with `market_json` and
/// `spawn` (the spawn_station id).
fn one_station_world(
  class_id: String,
  market_json: String,
  spawn: String,
) -> String {
  "{\"schema\":2,\"name\":\"T\",\"seed\":1,"
  <> "\"commodities\":[{\"id\":\"water\",\"name\":\"Water\"}],"
  <> "\"bodies\":[{\"id\":\"star\",\"name\":\"S\",\"kind\":\"star\","
  <> "\"parent\":null,\"orbit\":null,\"radius\":10.0,\"mu\":0.0}],"
  <> "\"stations\":[{\"id\":\"stn\",\"name\":\"Stn\",\"class\":\""
  <> class_id
  <> "\",\"parent\":\"star\","
  <> "\"orbit\":{\"radius\":50.0,\"period_s\":60.0,\"phase\":0.0},"
  <> "\"market\":"
  <> market_json
  <> "}],\"spawn_station\":\""
  <> spawn
  <> "\"}"
}

pub fn star_position_is_origin_at_any_t_test() {
  let assert Ok(w) = world.load("worlds/m1_system.json")
  let #(x0, y0) = world.body_position(w, "krasny", 0.0)
  let #(x1, y1) = world.body_position(w, "krasny", 12_345.6)
  assert close(x0, 0.0) && close(y0, 0.0)
  assert close(x1, 0.0) && close(y1, 0.0)
}

pub fn planet_position_at_phase_angle_test() {
  let assert Ok(w) = world.load("worlds/m1_system.json")
  let #(x, y) = world.body_position(w, "meridian", 0.0)
  assert close(x, 4000.0) && close(y, 0.0)
}

pub fn planet_position_at_quarter_period_test() {
  let assert Ok(w) = world.load("worlds/m1_system.json")
  // Meridian: radius 4000, period_s 900, phase 0.0 -> 90 degrees at t=225.
  let #(x, y) = world.body_position(w, "meridian", 225.0)
  assert close(x, 0.0) && close(y, 4000.0)
}

pub fn station_position_chains_through_planet_test() {
  let assert Ok(w) = world.load("worlds/m1_system.json")
  let #(px, py) = world.body_position(w, "meridian", 0.0)
  let #(sx, sy) = world.station_position(w, "meridian_highport", 0.0)
  assert close(sx, px +. 850.0) && close(sy, py +. 0.0)
}

pub fn station_velocity_magnitude_test() {
  let w = station_only_world()
  let expected = two_pi *. 400.0 /. 180.0
  let #(vx, vy) = world.station_velocity(w, "s1", 0.0)
  let assert Ok(magnitude) = float.square_root(vx *. vx +. vy *. vy)
  assert close(magnitude, expected)
}

pub fn gravity_points_toward_star_test() {
  let w = star_only_world()
  // Test point due "east" of the star at r=4000, well outside the 500
  // radius, so no clamping applies.
  let #(ax, ay) = world.gravity_at(w, 4000.0, 0.0, 0.0)
  let expected_mag = 20_000_000.0 /. { 4000.0 *. 4000.0 }
  let assert Ok(magnitude) = float.square_root(ax *. ax +. ay *. ay)
  assert close(magnitude, expected_mag)
  // Points from (4000, 0) toward the star at the origin: pulls in -x.
  assert ax <. 0.0
  assert close(ay, 0.0)
}

pub fn gravity_clamp_holds_inside_body_radius_test() {
  let w = star_only_world()
  // Inside the star's 500-unit radius (0 < r < body_radius): the magnitude
  // holds flat at exactly mu / body_radius^2, along the true unit vector
  // toward the centre (from (10, 0) that is -x).
  let #(ax, ay) = world.gravity_at(w, 10.0, 0.0, 0.0)
  let assert Ok(magnitude) = float.square_root(ax *. ax +. ay *. ay)
  let expected = 20_000_000.0 /. { 500.0 *. 500.0 }
  assert close(magnitude, expected)
  assert ax <. 0.0
  assert close(ay, 0.0)
}

pub fn station_velocity_chains_through_planet_test() {
  let assert Ok(w) = world.load("worlds/m1_system.json")
  let t = 100.0
  // Hand-computed expectation from the bundled world: meridian's orbital
  // velocity around the star (radius 4000, period 900, phase 0) plus
  // meridian_highport's own orbital velocity term around meridian
  // (radius 850, period 180, phase 0).
  let planet_angle = two_pi *. t /. 900.0
  let planet_omega_r = two_pi *. 4000.0 /. 900.0
  let station_angle = two_pi *. t /. 180.0
  let station_omega_r = two_pi *. 850.0 /. 180.0
  let expected_vx =
    0.0
    -. planet_omega_r
    *. sin(planet_angle)
    -. station_omega_r
    *. sin(station_angle)
  let expected_vy =
    planet_omega_r *. cos(planet_angle) +. station_omega_r *. cos(station_angle)
  let #(vx, vy) = world.station_velocity(w, "meridian_highport", t)
  assert close(vx, expected_vx)
  assert close(vy, expected_vy)
}

pub fn load_reads_trade_fields_test() {
  let assert Ok(w) = world.load("worlds/m1_system.json")
  assert list.length(w.commodities) == 4
  let assert Ok(highport) = world.get_station(w, "meridian_highport")
  assert highport.crane == True
  let assert option.Some(plan) = highport.concourse
  assert plan.spawn_tile == #(47, 3)
  assert list.length(highport.market) == 4
  let assert Ok(solis) = world.get_station(w, "solis_ring")
  assert solis.crane == False
}

pub fn decode_defaults_market_to_empty_when_absent_test() {
  // A station with a class ref but no market key loads with an empty market;
  // crane/concourse come from the (resolved) class.
  let doc =
    "{\"schema\":2,\"name\":\"T\",\"seed\":1,"
    <> "\"bodies\":[{\"id\":\"star\",\"name\":\"S\",\"kind\":\"star\","
    <> "\"parent\":null,\"orbit\":null,\"radius\":10.0,\"mu\":0.0}],"
    <> "\"stations\":[{\"id\":\"stn\",\"name\":\"Stn\",\"class\":\"bare\","
    <> "\"parent\":\"star\","
    <> "\"orbit\":{\"radius\":50.0,\"period_s\":60.0,\"phase\":0.0}}],"
    <> "\"spawn_station\":\"stn\"}"
  let assert Ok(w) = world.decode_with(station_classes(), doc)
  let assert Ok(stn) = world.get_station(w, "stn")
  assert stn.crane == False
  assert stn.market == []
  let assert option.Some(_) = stn.concourse
}

pub fn decode_rejects_market_with_unknown_commodity_test() {
  let doc =
    one_station_world(
      "trader",
      "[{\"commodity\":\"unobtainium\",\"initial\":5,\"price\":10,\"elasticity\":1}]",
      "stn",
    )
  let assert Error(_) = world.decode_with(station_classes(), doc)
}

pub fn decode_rejects_market_without_broker_console_test() {
  // The "bare" class concourse has no broker-kind console.
  let doc =
    one_station_world(
      "bare",
      "[{\"commodity\":\"water\",\"initial\":5,\"price\":10,\"elasticity\":1}]",
      "stn",
    )
  let assert Error(_) = world.decode_with(station_classes(), doc)
}

pub fn decode_accepts_market_with_broker_console_test() {
  // The "trader" class concourse has a broker (`b` glyph).
  let doc =
    one_station_world(
      "trader",
      "[{\"commodity\":\"water\",\"initial\":5,\"price\":10,\"elasticity\":1}]",
      "stn",
    )
  let assert Ok(_) = world.decode_with(station_classes(), doc)
}

pub fn station_berths_derive_from_q_glyphs_test() {
  // Berths are the concourse's `Q` docking ports (issue #31): the glyph tile is
  // the berth, its north-facing void door gives the side-on orientation. No
  // authored anchor.
  let assert Ok(w) = world.load("worlds/m1_system.json")
  let o = composite.default_orientation_deg
  let assert Ok(meridian) = world.get_station(w, "meridian_highport")
  assert world.station_berths(meridian)
    == [
      composite.Berth(x: 22, y: 1, orientation: o),
      composite.Berth(x: 54, y: 1, orientation: o),
      composite.Berth(x: 86, y: 1, orientation: o),
    ]
  let assert Ok(solis) = world.get_station(w, "solis_ring")
  assert world.station_berths(solis)
    == [composite.Berth(x: 5, y: 1, orientation: o)]
}

pub fn moored_heading_uses_ship_port_test() {
  let assert Ok(w) = world.load("worlds/m1_system.json")
  // The moored heading derives from the docking ship's own dock-port
  // orientation: a nose-forward port (0°) must NOT yield the same heading as
  // the side-on default (90°), or the ship-port argument is being ignored.
  let side_on = world.moored_heading(w, "meridian_highport", 0, 90.0)
  let nose_in = world.moored_heading(w, "meridian_highport", 0, 0.0)
  assert side_on != nose_in
}
