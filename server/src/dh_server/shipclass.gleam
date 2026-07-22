//// Ship class documents (schema 3): a hull's multi-deck plan (per-deck 3x3
//// tile grids, `docs/deckplan-format.md`) plus the cargo characteristics M3
//// trading needs (DESIGN.md "content is data"). One class exists
//// (`server/shipclasses/mockingbird.json`, path overridable via
//// `DH_SHIP_CLASS`); every ship in the sim is spawned from the same loaded
//// `ShipClass`. The whole document is sent verbatim to clients as
//// `ship_class` in the `welcome` message, so `encode` round-trips exactly
//// what was loaded. Angles are degrees throughout (config, wire, in memory);
//// only the live `heading` and `cos`/`sin` work in radians.

import dh_server/deckplan.{type Console, type DeckPlan}
import dh_server/glyphs.{type Registry}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/result
import gleam/string
import simplifile

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
  )
}

/// Read and decode a ship class document from a file, using the built-in glyph
/// legend. `path` is resolved relative to the process's working directory.
pub fn load(path: String) -> Result(ShipClass, String) {
  load_with(glyphs.default(), path)
}

/// `load`, but interpreting the deck grids with an explicit glyph registry —
/// the runtime path threads the loaded `glyphs.json` here.
pub fn load_with(reg: Registry, path: String) -> Result(ShipClass, String) {
  use text <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(err) {
      "failed to read ship class file " <> path <> ": " <> string.inspect(err)
    }),
  )
  decode_with(reg, text)
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
    ]),
  )
}

/// The first console of kind `"helm"` — every valid class has one.
pub fn helm_console(class: ShipClass) -> Result(Console, Nil) {
  deckplan.find_console_of_kind(class.plan, "helm")
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

fn handling_decoder() -> decode.Decoder(Handling) {
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
  let #(capacity, handling) = cargo
  // Breakbulk hold capacity derives from cargo-pallet tiles on the deck
  // plan ("the map is the single source of truth", as with consoles/berths)
  // — falling back to the authored capacity for hulls with no pallets.
  let derived = deckplan.pallet_count(plan, reg)
  let effective_capacity = case derived > 0 {
    True -> derived
    False -> capacity
  }
  decode.success(ShipClass(
    schema: schema,
    id: id,
    name: name,
    plan: plan,
    cargo_capacity: effective_capacity,
    handling: handling,
    dock_port_orientation: dock_port_orientation,
    dock_standoff: dock_standoff,
  ))
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
