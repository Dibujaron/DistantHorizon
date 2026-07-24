//// The authored HULL document (`server/shipclasses/*.json`, schema 3): a
//// hull's deck plan kept as raw 3x3 TEXT rows, the slot regions modules may
//// overlay, the exterior mount points parts hang on, its dry mass and the
//// capability tags it supplies for free, plus the default loadout it ships
//// with. See `docs/modules.md`.
////
//// A hull is not directly flyable: `loadout.resolve` stamps its default (or a
//// player's) modules into these rows and re-parses the result into a
//// `shipclass.ShipClass` — the resolved plan the sim, the composite and the
//// wire all speak. Rows are kept as text precisely so a refit can re-stamp
//// from the authored map rather than trying to un-stamp the previous fit.

import dh_server/shipclass.{type Handling}
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import simplifile

/// One modulable interior region. `digit` is the hex digit hull tiles carry in
/// their SW corner (`docs/deckplan-format.md`, "Slots"); `id` is what a module
/// names in its `slot` field.
pub type Slot {
  Slot(digit: Int, id: String, name: String)
}

/// One exterior attach point. `kind` gates what can hang there ("engine"),
/// `size` is the ordered scale `"s" | "m" | "l"` — a mount takes any part of
/// its kind up to its size. Mount GEOMETRY (sprite-space position/rotation)
/// lands with client-side part layering in M4 iteration 2; a mount is
/// currently a capability slot only.
pub type Mount {
  Mount(id: String, kind: String, size: String)
}

pub type Hull {
  Hull(
    schema: Int,
    id: String,
    name: String,
    /// Authored decks as `#(name, rows)` — raw 3x3 text, not parsed cells.
    decks: List(#(String, List(String))),
    slots: List(Slot),
    mounts: List(Mount),
    /// Dry structural mass. Total mass = this + every fitted module and part.
    mass: Float,
    /// Capability tags the bare hull supplies (its built-in reactor's `power`,
    /// for instance) — pooled with every module's and part's `provides`.
    provides: Dict(String, Int),
    /// Capability tags the bare hull demands — `{"engine": 1}` is how a hull
    /// says it will not fly without an engine mounted.
    requires: Dict(String, Int),
    /// Hold capacity used ONLY when the resolved plan draws no pallet tiles.
    fallback_capacity: Int,
    handling: Handling,
    dock_port_orientation: Float,
    dock_standoff: Float,
    /// slot id -> module id.
    default_modules: List(#(String, String)),
    /// mount id -> part id.
    default_parts: List(#(String, String)),
  )
}

/// Read and decode a hull document from a file.
pub fn load(path: String) -> Result(Hull, String) {
  use text <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(err) {
      "failed to read hull file " <> path <> ": " <> string.inspect(err)
    }),
  )
  decode(text)
}

/// Every `*.json` in `dir`, indexed by hull id. A duplicate id is an error
/// rather than a silent last-one-wins.
pub fn load_all(dir: String) -> Result(Dict(String, Hull), String) {
  use names <- result.try(
    simplifile.read_directory(dir)
    |> result.map_error(fn(err) {
      "failed to list hull directory " <> dir <> ": " <> string.inspect(err)
    }),
  )
  names
  |> list.filter(fn(n) { string.ends_with(n, ".json") })
  |> list.sort(string.compare)
  |> list.try_fold(dict.new(), fn(acc, name) {
    use h <- result.try(load(dir <> "/" <> name))
    case dict.has_key(acc, h.id) {
      True -> Error("duplicate hull id \"" <> h.id <> "\" in " <> dir)
      False -> Ok(dict.insert(acc, h.id, h))
    }
  })
}

/// Decode a hull document from JSON text.
pub fn decode(json_text: String) -> Result(Hull, String) {
  case json.parse(json_text, hull_decoder()) {
    Ok(h) -> validate(h)
    Error(err) -> Error("invalid hull document: " <> string.inspect(err))
  }
}

/// The slot with this id, or `Error(Nil)`.
pub fn slot_by_id(h: Hull, id: String) -> Result(Slot, Nil) {
  list.find(h.slots, fn(s) { s.id == id })
}

/// The mount with this id, or `Error(Nil)`.
pub fn mount_by_id(h: Hull, id: String) -> Result(Mount, Nil) {
  list.find(h.mounts, fn(m) { m.id == id })
}

fn validate(h: Hull) -> Result(Hull, String) {
  let digits = list.map(h.slots, fn(s) { s.digit })
  let ids = list.map(h.slots, fn(s) { s.id })
  case list.length(list.unique(digits)) == list.length(digits) {
    False -> Error("hull \"" <> h.id <> "\" has duplicate slot digits")
    True ->
      case list.length(list.unique(ids)) == list.length(ids) {
        False -> Error("hull \"" <> h.id <> "\" has duplicate slot ids")
        True ->
          case list.all(digits, fn(d) { d >= 0 && d <= 15 }) {
            False ->
              Error("hull \"" <> h.id <> "\" has a slot digit outside 0-15")
            True ->
              case h.mass >. 0.0 {
                False -> Error("hull \"" <> h.id <> "\" must have mass > 0")
                True -> Ok(h)
              }
          }
      }
  }
}

fn hull_decoder() -> decode.Decoder(Hull) {
  use schema <- decode.field("schema", decode.int)
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use decks <- decode.field("decks", decode.list(deck_decoder()))
  use slots <- decode.optional_field("slots", [], decode.list(slot_decoder()))
  use mounts <- decode.optional_field(
    "mounts",
    [],
    decode.list(mount_decoder()),
  )
  use mass <- decode.optional_field("mass", 100.0, decode.float)
  use provides <- decode.optional_field("provides", dict.new(), tags_decoder())
  use requires <- decode.optional_field("requires", dict.new(), tags_decoder())
  use cargo <- decode.field("cargo", cargo_decoder())
  use dock_port_orientation <- decode.optional_field(
    "dock_port_orientation",
    shipclass.default_dock_port_orientation_deg,
    decode.float,
  )
  use dock_standoff <- decode.optional_field(
    "dock_standoff",
    shipclass.default_dock_standoff,
    decode.float,
  )
  use loadout <- decode.optional_field(
    "default_loadout",
    #([], []),
    default_loadout_decoder(),
  )
  let #(capacity, handling) = cargo
  let #(default_modules, default_parts) = loadout
  decode.success(Hull(
    schema: schema,
    id: id,
    name: name,
    decks: decks,
    slots: slots,
    mounts: mounts,
    mass: mass,
    provides: provides,
    requires: requires,
    fallback_capacity: capacity,
    handling: handling,
    dock_port_orientation: dock_port_orientation,
    dock_standoff: dock_standoff,
    default_modules: default_modules,
    default_parts: default_parts,
  ))
}

fn deck_decoder() -> decode.Decoder(#(String, List(String))) {
  use name <- decode.field("name", decode.string)
  use grid <- decode.field("grid", decode.list(decode.string))
  decode.success(#(name, grid))
}

fn slot_decoder() -> decode.Decoder(Slot) {
  use digit <- decode.field("digit", decode.int)
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  decode.success(Slot(digit: digit, id: id, name: name))
}

fn mount_decoder() -> decode.Decoder(Mount) {
  use id <- decode.field("id", decode.string)
  use kind <- decode.field("kind", decode.string)
  use size <- decode.field("size", decode.string)
  decode.success(Mount(id: id, kind: kind, size: size))
}

/// A `{tag: amount}` object. Tags are open strings the engine only compares
/// and sums, so new content invents new tags with zero code.
pub fn tags_decoder() -> decode.Decoder(Dict(String, Int)) {
  decode.dict(decode.string, decode.int)
}

fn cargo_decoder() -> decode.Decoder(#(Int, Handling)) {
  use capacity <- decode.field("capacity", decode.int)
  use handling <- decode.field("handling", shipclass.handling_decoder())
  decode.success(#(capacity, handling))
}

fn default_loadout_decoder() -> decode.Decoder(
  #(List(#(String, String)), List(#(String, String))),
) {
  use modules <- decode.optional_field(
    "modules",
    dict.new(),
    decode.dict(decode.string, decode.string),
  )
  use parts <- decode.optional_field(
    "parts",
    dict.new(),
    decode.dict(decode.string, decode.string),
  )
  decode.success(#(sorted_pairs(modules), sorted_pairs(parts)))
}

/// A `Dict` in id order — JSON objects have no order, and a loadout that
/// stamps in a different order every boot would be a nightmare to debug.
fn sorted_pairs(d: Dict(String, String)) -> List(#(String, String)) {
  dict.to_list(d) |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
}
