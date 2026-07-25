//// A ship class is a hull's RESOLVED deck plan (schema 3) — what a specific
//// ship actually is once its loadout has been stamped onto its hull
//// (`loadout.resolve`, `docs/modules.md`) — plus the cargo characteristics M3
//// trading needs and the flight stats M4 moved out of `ship.gleam`'s
//// constants. The authored hull document lives in `hull.gleam`; this type is
//// the bake's OUTPUT, and the whole document is sent verbatim to clients as
//// `ship_class` in the `welcome` message, so `encode` round-trips exactly what
//// was resolved. Angles are degrees throughout.

import dh_server/deckplan.{type Console, type DeckPlan}
import dh_server/glyphs.{type Registry}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/result
import gleam/string

/// How cargo physically gets aboard (DESIGN.md "Cargo handling"):
/// break-bulk hulls load by robot stevedores anywhere; container hulls
/// need a station crane and never open their holds.
pub type Handling {
  BreakBulk
  Container
}

/// The default ship docking-port normal, ship-local DEGREES (0 = nose/+x):
/// 90 = the port flank. A hull with this port moors side-on — the M3.5
/// look. This is the canonical default fed (via `angle.deg_to_rad`) into
/// `world.moored_heading` for a class that doesn't author its own
/// `dock_port_orientation`.
pub const default_dock_port_orientation_deg = 90.0

/// The default moored standoff, in tiles (= metres): how far this hull's centre
/// sits off the berth's mooring line, along the berth's outward normal. There
/// is no good universal constant — a tiny shuttle and a wide-winged freighter
/// stand off differently — so it is authored per class; this default is the
/// Mockingbird's side-on standoff so an unspecified hull still moors sensibly.
pub const default_dock_standoff = 20.0

/// A resolved hull's flight performance, derived from the loadout: total
/// thrust and torque of the mounted engine parts divided by the fit's total
/// mass (`loadout.resolve`). These replaced `ship.main_accel` /
/// `ship.turn_rate`, which were global constants until M4.
pub type Flight {
  Flight(
    /// Acceleration at full thrust, u/s^2, along the ship's heading.
    accel: Float,
    /// Turn rate at full rotate input, DEGREES/s.
    turn_rate: Float,
  )
}

pub type ShipClass {
  ShipClass(
    schema: Int,
    id: String,
    name: String,
    plan: DeckPlan,
    /// Hold size in cargo units.
    cargo_capacity: Int,
    handling: Handling,
    /// This hull's docking-port outward normal in its OWN frame, in DEGREES
    /// (0 = nose/+x). The station berth's `orientation` and this value together
    /// fix the moored heading (`world.moored_heading`), so a hull can dock
    /// side-on (90°, the default — port flank to the gangway), nose-in (0°),
    /// etc., instead of the old hardcoded side-on (issue #14).
    dock_port_orientation: Float,
    /// How far this hull's centre stands off the berth mooring line, in tiles
    /// (= metres), along the berth's outward normal — the per-ship half of the
    /// moored sim pose (`world.moored_position`, issue #31). Wide hulls stand
    /// off further than narrow ones; there is no good constant, so it is
    /// authored per class.
    dock_standoff: Float,
    /// Flight performance derived from the fitted engine parts and the fit's
    /// total mass — data now, not constants.
    flight: Flight,
  )
}

/// Decode a ship class document (built-in glyph legend), validating the deck
/// plan's geometry and that the class has a helm console.
pub fn decode(json_text: String) -> Result(ShipClass, String) {
  decode_with(glyphs.default(), json_text)
}

/// `decode`, but interpreting the deck grids with an explicit glyph registry.
pub fn decode_with(
  reg: Registry,
  json_text: String,
) -> Result(ShipClass, String) {
  case json.parse(json_text, ship_class_decoder(reg)) {
    Ok(class) -> validate(class)
    Error(err) -> Error("invalid ship class document: " <> string.inspect(err))
  }
}

/// Encode a ship class document, e.g. for the `welcome` message. The deck
/// plan's fields stay at the top level (the M2 shape), with the schema-2
/// `cargo` block appended.
pub fn encode(class: ShipClass) -> Json {
  json.object(
    [
      #("schema", json.int(class.schema)),
      #("id", json.string(class.id)),
      #("name", json.string(class.name)),
    ]
    |> list.append(deckplan.encode_fields(class.plan))
    |> list.append([
      #("cargo", encode_cargo(class)),
      #("dock_port_orientation", json.float(class.dock_port_orientation)),
      #("dock_standoff", json.float(class.dock_standoff)),
      #(
        "flight",
        json.object([
          #("accel", json.float(class.flight.accel)),
          #("turn_rate", json.float(class.flight.turn_rate)),
        ]),
      ),
    ]),
  )
}

/// The first console of kind `"helm"` — every valid class has one.
pub fn helm_console(class: ShipClass) -> Result(Console, Nil) {
  deckplan.find_console_of_kind(class.plan, "helm")
}

/// Build a resolved class from a baked plan. This is the bake's exit: the plan
/// has already been stamped and re-parsed, so consoles, the mooring tile and
/// the pallet-derived hold capacity all come from the RESOLVED map. Validates
/// the same invariants an authored class always had (geometry, void-facing
/// dock doors, a helm) — which is what makes a cockpit-less loadout illegal.
pub fn from_plan(
  reg: Registry,
  id: String,
  name: String,
  schema: Int,
  plan: DeckPlan,
  fallback_capacity: Int,
  handling: Handling,
  dock_port_orientation: Float,
  dock_standoff: Float,
  flight: Flight,
) -> Result(ShipClass, String) {
  validate(ShipClass(
    schema: schema,
    id: id,
    name: name,
    plan: plan,
    cargo_capacity: effective_capacity(reg, plan, fallback_capacity),
    handling: handling,
    dock_port_orientation: dock_port_orientation,
    dock_standoff: dock_standoff,
    flight: flight,
  ))
}

/// The hold capacity of a resolved plan: breakbulk capacity derives from the
/// cargo-pallet tiles the map draws ("the map is the single source of truth",
/// as with consoles and berths), falling back to the authored number for a
/// hull whose plan draws no pallets.
///
/// Deliberately ONE function with two callers — the bake (`from_plan`) and the
/// wire (`ship_class_decoder`). Spelled out twice, a change to one of them
/// would quietly stop `encode`/`decode` round-tripping, and the decoder has no
/// production caller to notice.
fn effective_capacity(reg: Registry, plan: DeckPlan, fallback: Int) -> Int {
  let derived = deckplan.pallet_count(plan, reg)
  case derived > 0 {
    True -> derived
    False -> fallback
  }
}

fn validate(class: ShipClass) -> Result(ShipClass, String) {
  use _ <- result.try(deckplan.validate(class.plan))
  use _ <- result.try(deckplan.validate_docking_ports(class.plan))
  case helm_console(class) {
    Error(Nil) -> Error("no console of kind \"helm\"")
    Ok(_) ->
      case class.cargo_capacity >= 0 {
        False -> Error("cargo.capacity must be >= 0")
        True -> Ok(class)
      }
  }
}

pub fn handling_decoder() -> decode.Decoder(Handling) {
  use raw <- decode.then(decode.string)
  case raw {
    "breakbulk" -> decode.success(BreakBulk)
    "container" -> decode.success(Container)
    _ -> decode.failure(BreakBulk, "\"breakbulk\" or \"container\"")
  }
}

fn cargo_decoder() -> decode.Decoder(#(Int, Handling)) {
  use capacity <- decode.field("capacity", decode.int)
  use handling <- decode.field("handling", handling_decoder())
  decode.success(#(capacity, handling))
}

fn ship_class_decoder(reg: Registry) -> decode.Decoder(ShipClass) {
  use schema <- decode.field("schema", decode.int)
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use plan <- decode.then(deckplan.decoder(reg))
  use cargo <- decode.field("cargo", cargo_decoder())
  use dock_port_orientation <- decode.optional_field(
    "dock_port_orientation",
    default_dock_port_orientation_deg,
    decode.float,
  )
  use dock_standoff <- decode.optional_field(
    "dock_standoff",
    default_dock_standoff,
    decode.float,
  )
  // Required, not optional: `encode` always writes it, so every document that
  // legitimately exists carries it. There is no defaulting left to do now that
  // the pre-M4 global constants are gone — a class without flight stats is a
  // malformed document, and failing loudly beats an unflyable ship.
  use flight <- decode.field("flight", flight_decoder())
  let #(capacity, handling) = cargo
  decode.success(ShipClass(
    schema: schema,
    id: id,
    name: name,
    plan: plan,
    cargo_capacity: effective_capacity(reg, plan, capacity),
    handling: handling,
    dock_port_orientation: dock_port_orientation,
    dock_standoff: dock_standoff,
    flight: flight,
  ))
}

fn flight_decoder() -> decode.Decoder(Flight) {
  use accel <- decode.field("accel", decode.float)
  use turn_rate <- decode.field("turn_rate", decode.float)
  decode.success(Flight(accel: accel, turn_rate: turn_rate))
}

fn encode_cargo(class: ShipClass) -> Json {
  let handling = case class.handling {
    BreakBulk -> "breakbulk"
    Container -> "container"
  }
  json.object([
    #("capacity", json.int(class.cargo_capacity)),
    #("handling", json.string(handling)),
  ])
}
