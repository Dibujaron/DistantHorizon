//// Walkable characters in a deck plan. A character stands and walks the
//// plan (free movement, per-axis circle-vs-tile collision) or sits at a
//// console, snapped to its tile center with move input ignored. Interior
//// simulation is decoupled from exterior ship physics (artificial gravity
//// handwave): walking never cares whether the ship is docked, thrusting,
//// or tumbling.
////
//// A body's `Place` is either `Aboard` — in a *flying* ship's local frame
//// — or `OnStation(station_id)` — in that station's composite frame, which
//// (M3.1 stitched interiors) includes standing aboard a ship *docked* at
//// the station: its tiles are moored into the station composite. The old
//// airlock/place-transition helpers (near_airlock/disembark_to and the
//// spawn helpers) are gone; ship<->concourse crossing is now plain walking
//// within one composite space, and the dock/undock place transitions live
//// in the sim's join-on-dock / split-on-undock handling.

import dh_server/deckplan.{type DeckPlan}
import dh_server/ship
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

/// Where a character's body is: aboard their crew ship, or ashore on a
/// station concourse. Crew membership is `ship_id` either way — going
/// ashore does not stop you being crew (or keeping your ship alive).
pub type Place {
  Aboard
  OnStation(station_id: String)
}

pub type Character {
  Character(
    id: Int,
    name: String,
    ship_id: Int,
    place: Place,
    x: Float,
    y: Float,
    /// The console id this character is seated at, if any.
    seat: Option(String),
    move_dx: Float,
    move_dy: Float,
  )
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
pub fn step(character: Character, plan: DeckPlan) -> Character {
  case character.seat {
    Some(_) -> character
    None -> {
      let #(ndx, ndy) = normalize(character.move_dx, character.move_dy)
      let candidate_x = character.x +. ndx *. walk_speed *. ship.dt
      let x = case circle_walkable(plan, candidate_x, character.y) {
        True -> candidate_x
        False -> character.x
      }
      let candidate_y = character.y +. ndy *. walk_speed *. ship.dt
      let y = case circle_walkable(plan, x, candidate_y) {
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
/// success the character snaps to the console's tile center, is seated,
/// and its move input is cleared (mirroring `ship.try_dock` zeroing the
/// helm): input held at the moment of sitting must not survive the stay
/// and fire again on the first tick after a later stand.
pub fn try_sit(
  character: Character,
  plan: DeckPlan,
  console_id: String,
  occupied: Bool,
) -> Result(Character, String) {
  case character.seat {
    Some(_) -> Error("already_seated")
    None ->
      case deckplan.find_console(plan, console_id) {
        Error(Nil) -> Error("unknown_console")
        Ok(console) ->
          case occupied {
            True -> Error("occupied")
            False -> {
              let #(cx, cy) = deckplan.tile_center(console.x, console.y)
              case distance(character.x, character.y, cx, cy) <=. sit_range {
                False -> Error("too_far")
                True ->
                  Ok(
                    Character(
                      ..character,
                      x: cx,
                      y: cy,
                      seat: Some(console_id),
                      move_dx: 0.0,
                      move_dy: 0.0,
                    ),
                  )
              }
            }
          }
      }
  }
}

/// Leave the current seat. `"not_seated"` if already standing. The
/// character stays at the console's tile center, with move input cleared —
/// `move` sent while seated is ignored but still buffered, and without the
/// reset it would resume walking the character the tick after standing.
pub fn stand(character: Character) -> Result(Character, String) {
  case character.seat {
    None -> Error("not_seated")
    Some(_) ->
      Ok(Character(..character, seat: None, move_dx: 0.0, move_dy: 0.0))
  }
}

/// Whether `character` is seated at a console of `kind` on `plan`.
pub fn seated_at_kind(
  character: Character,
  plan: DeckPlan,
  kind: String,
) -> Bool {
  case character.seat {
    None -> False
    Some(console_id) ->
      case deckplan.find_console(plan, console_id) {
        Error(Nil) -> False
        Ok(console) -> console.kind == kind
      }
  }
}

/// Whether two characters share an interior (same ship deck, or the same
/// station concourse) — the scope for seat occupancy and interior fan-out.
pub fn same_place(a: Character, b: Character) -> Bool {
  case a.place, b.place {
    Aboard, Aboard -> a.ship_id == b.ship_id
    OnStation(station_a), OnStation(station_b) -> station_a == station_b
    Aboard, OnStation(_) | OnStation(_), Aboard -> False
  }
}

/// Whether `character` is seated at a `"helm"`-kind console of `plan`.
/// Helm/dock/undock take effect only when this holds (and only aboard —
/// the sim checks `place` before consulting the ship plan).
pub fn is_at_helm(character: Character, plan: DeckPlan) -> Bool {
  seated_at_kind(character, plan, "helm")
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

/// Whether a body (collision circle, radius `radius`) can stand centered at
/// `(x, y)` on `plan` — the same circle-vs-tile test `step` gates movement
/// on, so a position that passes here is one the character could have walked
/// to. Used by the sim to detect a body left in void when a mooring despawns
/// under it (a plain `deckplan.is_walkable` on the center tile is not enough:
/// the collision radius matters at tile edges).
pub fn can_stand_at(plan: DeckPlan, x: Float, y: Float) -> Bool {
  circle_walkable(plan, x, y)
}

/// Whether every tile overlapped by the character collision circle
/// centered at `(cx, cy)` is walkable.
fn circle_walkable(plan: DeckPlan, cx: Float, cy: Float) -> Bool {
  let tx0 = tile_index(cx -. radius)
  let tx1 = tile_index(cx +. radius)
  let ty0 = tile_index(cy -. radius)
  let ty1 = tile_index(cy +. radius)
  all_tiles(tx0, tx1, fn(tx) {
    all_tiles(ty0, ty1, fn(ty) {
      case tile_overlaps_circle(tx, ty, cx, cy) {
        False -> True
        True -> deckplan.is_walkable(plan, tx, ty)
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
