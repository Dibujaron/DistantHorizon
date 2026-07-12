//// Simulated ships. Each ship flies a circular orbit around a random centre:
//// per tick its position advances by its velocity and its velocity vector is
//// rotated by a fixed per-ship angle. The rotation is exact (unit rotation
//// matrix), so speed is constant and orbits stay bounded forever.
////
//// Fleet generation is deterministic: a fixed-seed LCG drives all the
//// per-ship parameters, so every server run simulates the same fleet.

import gleam/float
import gleam/int
import gleam/list

/// Simulation timestep in seconds (60 Hz).
pub const dt = 0.016666666666666666

const two_pi = 6.283185307179586

pub type Ship {
  Ship(
    id: Int,
    x: Float,
    y: Float,
    vx: Float,
    vy: Float,
    /// Precomputed cos/sin of the per-tick velocity rotation angle.
    cos_d: Float,
    sin_d: Float,
  )
}

@external(erlang, "math", "cos")
fn cos(x: Float) -> Float

@external(erlang, "math", "sin")
fn sin(x: Float) -> Float

/// Advance one ship by one tick: integrate position, rotate velocity.
pub fn advance(ship: Ship) -> Ship {
  Ship(
    ..ship,
    x: ship.x +. ship.vx *. dt,
    y: ship.y +. ship.vy *. dt,
    vx: ship.vx *. ship.cos_d -. ship.vy *. ship.sin_d,
    vy: ship.vx *. ship.sin_d +. ship.vy *. ship.cos_d,
  )
}

/// Advance the whole fleet by one tick.
pub fn advance_fleet(ships: List(Ship)) -> List(Ship) {
  list.map(ships, advance)
}

/// Build a deterministic fleet of `count` ships with ids 1..count.
/// Coordinates stay within roughly -9500..9500.
pub fn init_fleet(count: Int) -> List(Ship) {
  init_loop(1, count, 42, [])
}

fn init_loop(id: Int, count: Int, seed: Int, acc: List(Ship)) -> List(Ship) {
  case id > count {
    True -> list.reverse(acc)
    False -> {
      let #(ship, seed) = make_ship(id, seed)
      init_loop(id + 1, count, seed, [ship, ..acc])
    }
  }
}

fn make_ship(id: Int, seed: Int) -> #(Ship, Int) {
  // Orbit centre within +/-8000 on each axis.
  let #(u1, seed) = next_unit(seed)
  let #(u2, seed) = next_unit(seed)
  let cx = { u1 -. 0.5 } *. 16_000.0
  let cy = { u2 -. 0.5 } *. 16_000.0
  // Orbit radius 200..1500, so |coord| <= 8000 + 1500 = 9500.
  let #(u3, seed) = next_unit(seed)
  let radius = 200.0 +. u3 *. 1300.0
  // Angular speed 0.05..0.5 rad/s, random direction.
  let #(u4, seed) = next_unit(seed)
  let #(u5, seed) = next_unit(seed)
  let sign = case u4 <. 0.5 {
    True -> -1.0
    False -> 1.0
  }
  let omega = sign *. { 0.05 +. u5 *. 0.45 }
  // Random starting angle on the orbit.
  let #(u6, seed) = next_unit(seed)
  let angle = u6 *. two_pi
  let delta = omega *. dt
  let ship =
    Ship(
      id: id,
      x: cx +. radius *. cos(angle),
      y: cy +. radius *. sin(angle),
      vx: 0.0 -. radius *. omega *. sin(angle),
      vy: radius *. omega *. cos(angle),
      cos_d: cos(delta),
      sin_d: sin(delta),
    )
  #(ship, seed)
}

/// Speed of a ship in units/second (handy for tests).
pub fn speed(ship: Ship) -> Float {
  let assert Ok(s) = float.square_root(ship.vx *. ship.vx +. ship.vy *. ship.vy)
  s
}

// A small linear congruential generator; determinism matters more than
// quality here.
const lcg_a = 1_103_515_245

const lcg_c = 12_345

const lcg_m = 2_147_483_648

fn next_unit(seed: Int) -> #(Float, Int) {
  let seed = { seed * lcg_a + lcg_c } % lcg_m
  #(int.to_float(seed) /. int.to_float(lcg_m), seed)
}
