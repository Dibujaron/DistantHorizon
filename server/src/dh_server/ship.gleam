//// Player-controlled Newtonian ships. Each connection gets one ship; it
//// flies under thrust + gravity when `Flying`, or is pinned to a station's
//// analytic rail position/velocity when `Docked`.
////
//// Integration per tick is semi-implicit Euler: heading advances first,
//// then thrust (along the new heading) and gravity accelerate the
//// velocity, then the updated velocity advances the position.

import dh_server/world.{type World}
import gleam/dict.{type Dict}
import gleam/float
import gleam/list
import gleam/option.{type Option, None, Some}

/// Simulation timestep in seconds (60 Hz).
pub const dt = 0.016666666666666666

/// Acceleration at full thrust, u/s^2, applied along the ship's heading.
pub const main_accel = 40.0

/// Turn rate at full rotate input, rad/s (counter-clockwise positive).
pub const turn_rate = 3.0

/// Maximum speed relative to a station, u/s, allowed to dock.
pub const max_dock_speed = 60.0

/// Starting money for every newly spawned ship (M3 flat grant; M4's loan
/// structure replaces this).
pub const starting_wallet = 2000

/// Which way an in-progress cargo transfer moves goods.
pub type TransferDirection {
  ToShip
  ToStation
}

/// An in-progress cargo movement between the docked ship and its station.
/// `progress` accumulates `rate * dt` each tick; whole units move as it
/// crosses each 1.0. `price_each` is locked at order time.
pub type Transfer {
  Transfer(
    commodity: String,
    direction: TransferDirection,
    remaining: Int,
    progress: Float,
    price_each: Int,
    rate: Float,
  )
}

/// Helm input, always stored clamped: rotate in [-1, 1], thrust in [0, 1].
pub type Controls {
  Controls(rotate: Float, thrust: Float)
}

/// Whether a ship is flying freely or pinned to a station.
pub type DockState {
  Flying
  /// Docked and holding a claimed berth index on that station's concourse.
  Docked(station_id: String, berth: Int)
}

pub type Ship {
  Ship(
    id: Int,
    x: Float,
    y: Float,
    vx: Float,
    vy: Float,
    heading: Float,
    controls: Controls,
    dock: DockState,
    wallet: Int,
    hold: Dict(String, Int),
    transfers: List(Transfer),
  )
}

@external(erlang, "math", "cos")
fn cos(x: Float) -> Float

@external(erlang, "math", "sin")
fn sin(x: Float) -> Float

/// A new ship, docked at `world.spawn_station`, pinned to that station's
/// position and velocity at sim time `t`, holding the given berth index.
pub fn spawn_docked(id: Int, world: World, t: Float, berth: Int) -> Ship {
  let station_id = world.spawn_station
  let #(x, y) = world.station_position(world, station_id, t)
  let #(vx, vy) = world.station_velocity(world, station_id, t)
  Ship(
    id: id,
    x: x,
    y: y,
    vx: vx,
    vy: vy,
    heading: 0.0,
    controls: Controls(rotate: 0.0, thrust: 0.0),
    dock: Docked(station_id, berth),
    wallet: starting_wallet,
    hold: dict.new(),
    transfers: [],
  )
}

/// Set helm input, clamping rotate to [-1, 1] and thrust to [0, 1].
pub fn set_controls(ship: Ship, rotate: Float, thrust: Float) -> Ship {
  Ship(
    ..ship,
    controls: Controls(
      rotate: float.clamp(rotate, min: -1.0, max: 1.0),
      thrust: float.clamp(thrust, min: 0.0, max: 1.0),
    ),
  )
}

/// Advance a ship by one tick of `dt` at sim time `t` (the time at the end
/// of this tick, used to evaluate rails and gravity). A docked ship is
/// pinned to its station's analytic position/velocity and ignores its
/// controls; a flying ship integrates thrust + gravity.
pub fn step(ship: Ship, world: World, t: Float) -> Ship {
  case ship.dock {
    Docked(station_id, _) -> {
      let #(x, y) = world.station_position(world, station_id, t)
      let #(vx, vy) = world.station_velocity(world, station_id, t)
      Ship(..ship, x: x, y: y, vx: vx, vy: vy)
    }
    Flying -> {
      let heading = ship.heading +. ship.controls.rotate *. turn_rate *. dt
      let #(gx, gy) = world.gravity_at(world, ship.x, ship.y, t)
      let ax = ship.controls.thrust *. main_accel *. cos(heading) +. gx
      let ay = ship.controls.thrust *. main_accel *. sin(heading) +. gy
      let vx = ship.vx +. ax *. dt
      let vy = ship.vy +. ay *. dt
      let x = ship.x +. vx *. dt
      let y = ship.y +. vy *. dt
      Ship(..ship, x: x, y: y, vx: vx, vy: vy, heading: heading)
    }
  }
}

/// Attempt to dock at the nearest station within its `dock_radius`.
/// `Error("already_docked")` if already docked, `Error("out_of_range")` if
/// no station is within range, `Error("too_fast")` if the relative speed to
/// the nearest in-range station exceeds `max_dock_speed` (checked before
/// claiming a berth); otherwise `claim_berth` is called with the in-range
/// station's id and its result (a claimed berth index, or a refusal reason
/// such as `"berths_full"` / `"no_berths"`) is forwarded as-is.
pub fn try_dock(
  ship: Ship,
  world: World,
  t: Float,
  claim_berth: fn(String) -> Result(Int, String),
) -> Result(Ship, String) {
  case ship.dock {
    Docked(_, _) -> Error("already_docked")
    Flying ->
      case nearest_in_range(ship, world, t) {
        None -> Error("out_of_range")
        Some(#(station_id, svx, svy)) -> {
          let relative_speed = distance(ship.vx, ship.vy, svx, svy)
          case relative_speed >. max_dock_speed {
            True -> Error("too_fast")
            False ->
              case claim_berth(station_id) {
                Error(reason) -> Error(reason)
                // Zero the helm on dock: helm input is ignored while
                // docked, so any controls left set here would silently
                // survive the stay and fire again on the first step after
                // undock.
                Ok(berth) ->
                  Ok(
                    Ship(
                      ..ship,
                      controls: Controls(rotate: 0.0, thrust: 0.0),
                      dock: Docked(station_id, berth),
                    ),
                  )
              }
          }
        }
      }
  }
}

/// Undock: `Error("not_docked")` if already flying, otherwise the ship is
/// released in place — at the station's position with the station's rail
/// velocity, heading unchanged — and set flying. No teleport: the ship
/// starts inside the dock ring and drifts out on the station's velocity.
pub fn undock(ship: Ship, world: World, t: Float) -> Result(Ship, String) {
  case ship.dock {
    Flying -> Error("not_docked")
    Docked(_, _) if ship.transfers != [] -> Error("transfer_in_progress")
    Docked(station_id, _) -> {
      let #(sx, sy) = world.station_position(world, station_id, t)
      let #(svx, svy) = world.station_velocity(world, station_id, t)
      Ok(Ship(..ship, x: sx, y: sy, vx: svx, vy: svy, dock: Flying))
    }
  }
}

/// Speed of a ship in units/second.
pub fn speed(ship: Ship) -> Float {
  distance(0.0, 0.0, ship.vx, ship.vy)
}

/// The id, and velocity, of the nearest station within its own dock_radius
/// of `ship`'s position at sim time `t`; `None` if no station is in range.
fn nearest_in_range(
  ship: Ship,
  world: World,
  t: Float,
) -> Option(#(String, Float, Float)) {
  let best =
    list.fold(world.stations, None, fn(best, station) {
      let #(sx, sy) = world.station_position(world, station.id, t)
      let d = distance(ship.x, ship.y, sx, sy)
      case d <=. station.dock_radius {
        False -> best
        True ->
          case best {
            None -> Some(#(station.id, d))
            Some(#(_, bd)) ->
              case d <. bd {
                True -> Some(#(station.id, d))
                False -> best
              }
          }
      }
    })
  case best {
    None -> None
    Some(#(station_id, _)) -> {
      let #(svx, svy) = world.station_velocity(world, station_id, t)
      Some(#(station_id, svx, svy))
    }
  }
}

fn distance(x1: Float, y1: Float, x2: Float, y2: Float) -> Float {
  let dx = x2 -. x1
  let dy = y2 -. y1
  let assert Ok(d) = float.square_root(dx *. dx +. dy *. dy)
  d
}
