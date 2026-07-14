//// Walkable characters aboard a ship. A character stands and walks the
//// deck plan (free movement, per-axis circle-vs-tile collision) or sits at
//// a console, snapped to its tile center with move input ignored. Interior
//// simulation is decoupled from exterior ship physics (artificial gravity
//// handwave): walking never cares whether the ship is docked, thrusting,
//// or tumbling.

import dh_server/ship
import dh_server/shipclass.{type ShipClass}
import gleam/float
import gleam/int
import gleam/option.{type Option, None, Some}

/// Walk speed, tiles/s.
pub const walk_speed = 3.0

/// Character collision radius, tiles.
pub const radius = 0.3

/// Maximum distance (character center to console tile center) to sit,
/// tiles.
pub const sit_range = 1.2

pub type Character {
  Character(
    id: Int,
    name: String,
    ship_id: Int,
    x: Float,
    y: Float,
    /// The console id this character is seated at, if any.
    seat: Option(String),
    move_dx: Float,
    move_dy: Float,
  )
}

/// A new character standing at `class`'s helm console, seated at it. Used
/// for login: every M1 flow (helm/dock/undock) keeps working immediately,
/// since the character spawns already seated at the helm.
pub fn spawn_seated_at_helm(
  id: Int,
  name: String,
  ship_id: Int,
  class: ShipClass,
) -> Character {
  let assert Ok(console) = shipclass.helm_console(class)
  let #(x, y) = tile_center(console.x, console.y)
  Character(
    id: id,
    name: name,
    ship_id: ship_id,
    x: x,
    y: y,
    seat: Some(console.id),
    move_dx: 0.0,
    move_dy: 0.0,
  )
}

/// A new character standing at `class`'s spawn tile, unseated. Used when a
/// character boards a ship.
pub fn spawn_at_spawn_tile(
  id: Int,
  name: String,
  ship_id: Int,
  class: ShipClass,
) -> Character {
  let #(x, y) = spawn_position(class)
  Character(
    id: id,
    name: name,
    ship_id: ship_id,
    x: x,
    y: y,
    seat: None,
    move_dx: 0.0,
    move_dy: 0.0,
  )
}

/// The tile center of `class`'s spawn tile.
pub fn spawn_position(class: ShipClass) -> #(Float, Float) {
  let #(x, y) = class.spawn_tile
  tile_center(x, y)
}

/// Set walk input (cast), clamping each axis to [-1, 1]. Clamping mirrors
/// `ship.set_controls`; the magnitude-1 normalization for diagonal input
/// happens in `step`, since it must be applied every tick (walk speed is
/// derived from the normalized input, not the raw clamped one).
pub fn set_move(character: Character, dx: Float, dy: Float) -> Character {
  Character(
    ..character,
    move_dx: float.clamp(dx, min: -1.0, max: 1.0),
    move_dy: float.clamp(dy, min: -1.0, max: 1.0),
  )
}

/// Advance a character by one tick of `ship.dt`. Seated characters ignore
/// move input and don't move. Standing characters normalize their input if
/// its magnitude exceeds 1, then step x then y independently: each axis
/// step is rejected (and that axis left unchanged) if the character's
/// collision circle at the candidate position overlaps a non-walkable
/// tile — classic per-axis tile collision, so a character sliding into a
/// wall at an angle keeps moving along it instead of stopping dead.
pub fn step(character: Character, class: ShipClass) -> Character {
  case character.seat {
    Some(_) -> character
    None -> {
      let #(ndx, ndy) = normalize(character.move_dx, character.move_dy)
      let candidate_x = character.x +. ndx *. walk_speed *. ship.dt
      let x = case circle_walkable(class, candidate_x, character.y) {
        True -> candidate_x
        False -> character.x
      }
      let candidate_y = character.y +. ndy *. walk_speed *. ship.dt
      let y = case circle_walkable(class, x, candidate_y) {
        True -> candidate_y
        False -> character.y
      }
      Character(..character, x: x, y: y)
    }
  }
}

/// Attempt to sit at `console_id`. Requires standing (`"already_seated"`
/// otherwise), the console to exist (`"unknown_console"`), it to be
/// unoccupied (`"occupied"`, decided by the caller since occupancy depends
/// on every other character aboard) and the character's center to be
/// within `sit_range` of the console's tile center (`"too_far"`). On
/// success the character snaps to the console's tile center and is seated.
pub fn try_sit(
  character: Character,
  class: ShipClass,
  console_id: String,
  occupied: Bool,
) -> Result(Character, String) {
  case character.seat {
    Some(_) -> Error("already_seated")
    None ->
      case shipclass.find_console(class, console_id) {
        Error(Nil) -> Error("unknown_console")
        Ok(console) ->
          case occupied {
            True -> Error("occupied")
            False -> {
              let #(cx, cy) = tile_center(console.x, console.y)
              case distance(character.x, character.y, cx, cy) <=. sit_range {
                False -> Error("too_far")
                True ->
                  Ok(
                    Character(..character, x: cx, y: cy, seat: Some(console_id)),
                  )
              }
            }
          }
      }
  }
}

/// Leave the current seat. `"not_seated"` if already standing. The
/// character stays at the console's tile center.
pub fn stand(character: Character) -> Result(Character, String) {
  case character.seat {
    None -> Error("not_seated")
    Some(_) -> Ok(Character(..character, seat: None))
  }
}

/// Whether `character` is seated at a `"helm"`-kind console of `class`.
/// Helm/dock/undock take effect only when this holds.
pub fn is_at_helm(character: Character, class: ShipClass) -> Bool {
  case character.seat {
    None -> False
    Some(console_id) ->
      case shipclass.find_console(class, console_id) {
        Error(Nil) -> False
        Ok(console) -> console.kind == "helm"
      }
  }
}

fn tile_center(x: Int, y: Int) -> #(Float, Float) {
  #(int.to_float(x) +. 0.5, int.to_float(y) +. 0.5)
}

/// Normalize `(dx, dy)` to a magnitude of at most 1, leaving it unchanged
/// if already within the unit disc (so e.g. gentle analog input keeps its
/// magnitude, but diagonal WASD at (1, 1) is scaled down to unit speed).
fn normalize(dx: Float, dy: Float) -> #(Float, Float) {
  let magnitude_sq = dx *. dx +. dy *. dy
  case magnitude_sq >. 1.0 {
    False -> #(dx, dy)
    True -> {
      let assert Ok(magnitude) = float.square_root(magnitude_sq)
      #(dx /. magnitude, dy /. magnitude)
    }
  }
}

/// Whether every tile overlapped by the character collision circle
/// centered at `(cx, cy)` is walkable.
fn circle_walkable(class: ShipClass, cx: Float, cy: Float) -> Bool {
  let tx0 = tile_index(cx -. radius)
  let tx1 = tile_index(cx +. radius)
  let ty0 = tile_index(cy -. radius)
  let ty1 = tile_index(cy +. radius)
  all_tiles(tx0, tx1, fn(tx) {
    all_tiles(ty0, ty1, fn(ty) {
      case tile_overlaps_circle(tx, ty, cx, cy) {
        False -> True
        True -> shipclass.is_walkable(class, tx, ty)
      }
    })
  })
}

/// True if `predicate` holds for every integer in `[from, to]` inclusive.
fn all_tiles(from: Int, to: Int, predicate: fn(Int) -> Bool) -> Bool {
  case from > to {
    True -> True
    False -> predicate(from) && all_tiles(from + 1, to, predicate)
  }
}

fn tile_overlaps_circle(tx: Int, ty: Int, cx: Float, cy: Float) -> Bool {
  let tx_f = int.to_float(tx)
  let ty_f = int.to_float(ty)
  let closest_x = float.clamp(cx, min: tx_f, max: tx_f +. 1.0)
  let closest_y = float.clamp(cy, min: ty_f, max: ty_f +. 1.0)
  let dx = cx -. closest_x
  let dy = cy -. closest_y
  dx *. dx +. dy *. dy <=. radius *. radius
}

fn tile_index(v: Float) -> Int {
  float.round(float.floor(v))
}

fn distance(x1: Float, y1: Float, x2: Float, y2: Float) -> Float {
  let dx = x2 -. x1
  let dy = y2 -. y1
  let assert Ok(d) = float.square_root(dx *. dx +. dy *. dy)
  d
}
