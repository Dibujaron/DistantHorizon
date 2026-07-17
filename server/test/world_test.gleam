import dh_server/world.{type World, Body, Orbit, Station, World}
import gleam/float
import gleam/json
import gleam/list
import gleam/option.{None}

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

pub fn decode_encode_round_trips_test() {
  let assert Ok(w) = world.load("worlds/m1_system.json")
  let text = world.encode(w) |> json.to_string
  let assert Ok(w2) = world.decode(text)
  assert w == w2
}

pub fn decode_rejects_unknown_spawn_station_test() {
  let bad_json =
    "{\"schema\":1,\"name\":\"bad\",\"seed\":1,\"bodies\":["
    <> "{\"id\":\"star\",\"name\":\"Star\",\"kind\":\"star\",\"parent\":null,"
    <> "\"orbit\":null,\"radius\":500.0,\"mu\":1.0}],"
    <> "\"stations\":["
    <> "{\"id\":\"dock\",\"name\":\"Dock\",\"parent\":\"star\","
    <> "\"orbit\":{\"radius\":10.0,\"period_s\":10.0,\"phase\":0.0},"
    <> "\"dock_radius\":5.0}],"
    <> "\"spawn_station\":\"nonexistent\"}"
  assert world.decode(bad_json) |> is_error
}

fn is_error(result: Result(a, b)) -> Bool {
  case result {
    Error(_) -> True
    Ok(_) -> False
  }
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
  assert close(sx, px +. 400.0) && close(sy, py +. 0.0)
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
  // (radius 400, period 180, phase 0).
  let planet_angle = two_pi *. t /. 900.0
  let planet_omega_r = two_pi *. 4000.0 /. 900.0
  let station_angle = two_pi *. t /. 180.0
  let station_omega_r = two_pi *. 400.0 /. 180.0
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
  assert plan.spawn_tile == #(4, 4)
  assert list.length(highport.market) == 4
  let assert Ok(solis) = world.get_station(w, "solis_ring")
  assert solis.crane == False
}

pub fn decode_defaults_trade_fields_when_absent_test() {
  // A schema-1 station (no crane/concourse/market keys) must still load.
  let doc =
    "{\"schema\":1,\"name\":\"T\",\"seed\":1,"
    <> "\"bodies\":[{\"id\":\"star\",\"name\":\"S\",\"kind\":\"star\","
    <> "\"parent\":null,\"orbit\":null,\"radius\":10.0,\"mu\":0.0}],"
    <> "\"stations\":[{\"id\":\"stn\",\"name\":\"Stn\",\"parent\":\"star\","
    <> "\"orbit\":{\"radius\":50.0,\"period_s\":60.0,\"phase\":0.0},"
    <> "\"dock_radius\":10.0}],"
    <> "\"spawn_station\":\"stn\"}"
  let assert Ok(w) = world.decode(doc)
  let assert Ok(stn) = world.get_station(w, "stn")
  assert stn.crane == False
  assert stn.concourse == option.None
  assert stn.market == []
  assert w.commodities == []
}

pub fn decode_rejects_market_with_unknown_commodity_test() {
  let doc =
    tiny_world_with_market(
      "[{\"commodity\":\"unobtainium\",\"initial\":5,\"price\":10,\"elasticity\":1}]",
    )
  let assert Error(_) = world.decode(doc)
}

pub fn decode_rejects_market_without_concourse_test() {
  // Market present, but no concourse at all.
  let doc =
    "{\"schema\":2,\"name\":\"T\",\"seed\":1,"
    <> "\"commodities\":[{\"id\":\"water\",\"name\":\"Water\"}],"
    <> "\"bodies\":[{\"id\":\"star\",\"name\":\"S\",\"kind\":\"star\","
    <> "\"parent\":null,\"orbit\":null,\"radius\":10.0,\"mu\":0.0}],"
    <> "\"stations\":[{\"id\":\"stn\",\"name\":\"Stn\",\"parent\":\"star\","
    <> "\"orbit\":{\"radius\":50.0,\"period_s\":60.0,\"phase\":0.0},"
    <> "\"dock_radius\":10.0,"
    <> "\"market\":[{\"commodity\":\"water\",\"initial\":5,\"price\":10,\"elasticity\":1}]}],"
    <> "\"spawn_station\":\"stn\"}"
  let assert Error(_) = world.decode(doc)
}

pub fn decode_rejects_market_without_broker_console_test() {
  // Concourse exists but has no broker-kind console.
  let doc = tiny_world_with_concourse_consoles("[]")
  let assert Error(_) = world.decode(doc)
}

pub fn decode_accepts_market_with_broker_console_test() {
  let doc =
    tiny_world_with_concourse_consoles(
      "[{\"id\":\"broker_main\",\"kind\":\"broker\",\"x\":1,\"y\":0}]",
    )
  let assert Ok(_) = world.decode(doc)
}

/// Tiny valid world with one station whose market is `market_json` and
/// whose concourse has a broker console.
fn tiny_world_with_market(market_json: String) -> String {
  "{\"schema\":2,\"name\":\"T\",\"seed\":1,"
  <> "\"commodities\":[{\"id\":\"water\",\"name\":\"Water\"}],"
  <> "\"bodies\":[{\"id\":\"star\",\"name\":\"S\",\"kind\":\"star\","
  <> "\"parent\":null,\"orbit\":null,\"radius\":10.0,\"mu\":0.0}],"
  <> "\"stations\":[{\"id\":\"stn\",\"name\":\"Stn\",\"parent\":\"star\","
  <> "\"orbit\":{\"radius\":50.0,\"period_s\":60.0,\"phase\":0.0},"
  <> "\"dock_radius\":10.0,"
  <> "\"concourse\":{\"grid\":{\"width\":3,\"height\":2},"
  <> "\"walkable\":[\"###\",\"###\"],\"rooms\":[],"
  <> "\"consoles\":[{\"id\":\"broker_main\",\"kind\":\"broker\",\"x\":1,\"y\":0}],"
  <> "\"spawn_tile\":[1,1]},"
  <> "\"market\":"
  <> market_json
  <> "}],"
  <> "\"spawn_station\":\"stn\"}"
}

/// Same tiny world, market fixed to water, concourse consoles swappable.
fn tiny_world_with_concourse_consoles(consoles_json: String) -> String {
  "{\"schema\":2,\"name\":\"T\",\"seed\":1,"
  <> "\"commodities\":[{\"id\":\"water\",\"name\":\"Water\"}],"
  <> "\"bodies\":[{\"id\":\"star\",\"name\":\"S\",\"kind\":\"star\","
  <> "\"parent\":null,\"orbit\":null,\"radius\":10.0,\"mu\":0.0}],"
  <> "\"stations\":[{\"id\":\"stn\",\"name\":\"Stn\",\"parent\":\"star\","
  <> "\"orbit\":{\"radius\":50.0,\"period_s\":60.0,\"phase\":0.0},"
  <> "\"dock_radius\":10.0,"
  <> "\"concourse\":{\"grid\":{\"width\":3,\"height\":2},"
  <> "\"walkable\":[\"###\",\"###\"],\"rooms\":[],"
  <> "\"consoles\":"
  <> consoles_json
  <> ","
  <> "\"spawn_tile\":[1,1]},"
  <> "\"market\":[{\"commodity\":\"water\",\"initial\":5,\"price\":10,\"elasticity\":1}]}],"
  <> "\"spawn_station\":\"stn\"}"
}
