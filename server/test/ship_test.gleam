import dh_server/ship.{type Ship, Controls, Docked, Flying, Ship}
import dh_server/world.{type World, Body, Orbit, Station, World}
import gleam/float
import gleam/int
import gleam/option.{None}

const epsilon = 0.000001

fn close(a: Float, b: Float, tolerance: Float) -> Bool {
  float.absolute_value(a -. b) <. tolerance
}

/// A single stationary body far from the test ship, with a station on a
/// moving rail. Used for step/dock/undock tests where we want an actual
/// orbiting station rather than one nailed to the origin.
fn test_world() -> World {
  World(
    schema: 1,
    name: "ship test world",
    seed: 1,
    bodies: [
      Body(
        id: "anchor",
        name: "Anchor",
        kind: "star",
        parent: None,
        orbit: None,
        radius: 100.0,
        mu: 20_000_000.0,
      ),
    ],
    stations: [
      Station(
        id: "s1",
        name: "S1",
        parent: "anchor",
        orbit: Orbit(radius: 400.0, period_s: 180.0, phase: 0.0),
        dock_radius: 150.0,
      ),
    ],
    spawn_station: "s1",
  )
}

/// A world with a stationary station (zero-radius orbit around a
/// non-gravitating body) at the origin, for dock-range tests that need
/// simple, hand-checkable geometry.
fn stationary_dock_world() -> World {
  World(
    schema: 1,
    name: "stationary dock world",
    seed: 1,
    bodies: [
      Body(
        id: "anchor",
        name: "Anchor",
        kind: "star",
        parent: None,
        orbit: None,
        radius: 10.0,
        mu: 0.0,
      ),
    ],
    stations: [
      Station(
        id: "s1",
        name: "S1",
        parent: "anchor",
        orbit: Orbit(radius: 0.0, period_s: 180.0, phase: 0.0),
        dock_radius: 150.0,
      ),
    ],
    spawn_station: "s1",
  )
}

fn flying_ship(x: Float, y: Float, vx: Float, vy: Float) -> Ship {
  Ship(
    id: 1,
    x: x,
    y: y,
    vx: vx,
    vy: vy,
    heading: 0.0,
    controls: Controls(rotate: 0.0, thrust: 0.0),
    dock: Flying,
  )
}

pub fn full_thrust_from_rest_reaches_main_accel_speed_test() {
  // Far from every body so gravity is negligible over one second.
  let w = test_world()
  let ship =
    flying_ship(50_000.0, 50_000.0, 0.0, 0.0)
    |> ship.set_controls(0.0, 1.0)
  let after = run_ticks(ship, w, 60)
  assert close(ship.speed(after), 40.0, 1.0)
}

pub fn zero_thrust_coasts_linearly_test() {
  let w = test_world()
  let ship = flying_ship(50_000.0, 50_000.0, 10.0, 5.0)
  let after = run_ticks(ship, w, 60)
  // No thrust and negligible gravity: velocity is unchanged.
  assert close(after.vx, 10.0, 0.01)
  assert close(after.vy, 5.0, 0.01)
  // Position advances linearly: 1 second at (10, 5) u/s.
  assert close(after.x, 50_000.0 +. 10.0, 0.02)
  assert close(after.y, 50_000.0 +. 5.0, 0.02)
}

pub fn full_rotate_turns_heading_by_turn_rate_test() {
  let w = test_world()
  let ship =
    flying_ship(50_000.0, 50_000.0, 0.0, 0.0)
    |> ship.set_controls(1.0, 0.0)
  let after = run_ticks(ship, w, 60)
  assert close(after.heading, 3.0, 0.01)
}

pub fn set_controls_clamps_test() {
  let ship = flying_ship(0.0, 0.0, 0.0, 0.0)
  let after = ship.set_controls(ship, 2.0, -0.5)
  assert after.controls == Controls(rotate: 1.0, thrust: 0.0)
}

pub fn spawn_docked_pins_to_spawn_station_test() {
  let w = test_world()
  let ship = ship.spawn_docked(1, w, 0.0)
  let #(sx, sy) = world.station_position(w, "s1", 0.0)
  assert close(ship.x, sx, epsilon)
  assert close(ship.y, sy, epsilon)
  assert ship.dock == Docked("s1")
}

pub fn docked_ship_stays_pinned_while_station_moves_test() {
  let w = test_world()
  let ship = ship.spawn_docked(1, w, 0.0)
  let final_t = 100.0 *. ship.dt
  let after = run_ticks(ship, w, 100)
  let #(sx, sy) = world.station_position(w, "s1", final_t)
  assert close(after.x, sx, epsilon)
  assert close(after.y, sy, epsilon)
  assert after.dock == Docked("s1")
  // Sanity: the station (and thus the ship) actually moved.
  assert !close(after.x, ship.x, epsilon) || !close(after.y, ship.y, epsilon)
}

pub fn try_dock_succeeds_in_range_at_low_speed_test() {
  let w = stationary_dock_world()
  let ship = flying_ship(50.0, 0.0, 0.0, 0.0)
  let assert Ok(docked) = ship.try_dock(ship, w, 0.0)
  assert docked.dock == Docked("s1")
}

pub fn try_dock_zeroes_controls_test() {
  // Helm input is ignored while docked, so controls held at dock time must
  // be cleared — otherwise they'd silently fire again on the first step
  // after a later undock.
  let w = stationary_dock_world()
  let ship =
    flying_ship(50.0, 0.0, 0.0, 0.0)
    |> ship.set_controls(1.0, 1.0)
  let assert Ok(docked) = ship.try_dock(ship, w, 0.0)
  assert docked.controls == Controls(rotate: 0.0, thrust: 0.0)
}

pub fn try_dock_fails_out_of_range_test() {
  let w = stationary_dock_world()
  let ship = flying_ship(10_000.0, 10_000.0, 0.0, 0.0)
  assert ship.try_dock(ship, w, 0.0) == Error("out_of_range")
}

pub fn try_dock_fails_too_fast_test() {
  let w = stationary_dock_world()
  let ship = flying_ship(50.0, 0.0, 100.0, 0.0)
  assert ship.try_dock(ship, w, 0.0) == Error("too_fast")
}

pub fn try_dock_fails_already_docked_test() {
  let w = stationary_dock_world()
  let ship = ship.spawn_docked(1, w, 0.0)
  assert ship.try_dock(ship, w, 0.0) == Error("already_docked")
}

pub fn undock_releases_ship_in_place_test() {
  let w = test_world()
  let t = 42.0
  let docked = Ship(..ship.spawn_docked(1, w, 0.0), heading: 1.5)
  let assert Ok(after) = ship.undock(docked, w, t)
  let #(sx, sy) = world.station_position(w, "s1", t)
  let #(svx, svy) = world.station_velocity(w, "s1", t)
  // No teleport: released exactly at the station, on its rail velocity,
  // heading untouched.
  assert close(after.x, sx, epsilon)
  assert close(after.y, sy, epsilon)
  assert close(after.vx, svx, epsilon)
  assert close(after.vy, svy, epsilon)
  assert after.heading == 1.5
  assert after.dock == Flying
}

pub fn undock_while_flying_errors_test() {
  let w = test_world()
  let ship = flying_ship(0.0, 0.0, 0.0, 0.0)
  assert ship.undock(ship, w, 0.0) == Error("not_docked")
}

fn run_ticks(ship: Ship, w: World, n: Int) -> Ship {
  run_ticks_loop(ship, w, 0, n)
}

fn run_ticks_loop(ship: Ship, w: World, tick: Int, n: Int) -> Ship {
  case tick >= n {
    True -> ship
    False -> {
      let t = int.to_float(tick + 1) *. ship.dt
      run_ticks_loop(ship.step(ship, w, t), w, tick + 1, n)
    }
  }
}
