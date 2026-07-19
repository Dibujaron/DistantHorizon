//// Station class documents (schema 1): a station design's concourse deck plan
//// (deck-plan format v3, `docs/deckplan-format.md`) plus its docking
//// characteristics (`dock_radius`, `crane`). Reusable across worlds exactly as
//// ship classes are (issue #30) — a world references a station class by id and
//// carries only per-instance placement/economy. One file per class under
//// `server/stationclasses/`, loaded at startup and keyed by id.
////
//// Berths are NOT authored here as a list: they derive from the concourse's
//// `Q` docking-port glyphs (issue #31), so the concourse is the single source
//// of docking geometry — a `Q` in the grid IS a berth.

import dh_server/deckplan.{type DeckPlan}
import dh_server/glyphs.{type Registry}
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import simplifile

pub type StationClass {
  StationClass(
    id: String,
    name: String,
    dock_radius: Float,
    /// Container-crane berths (the fast handling path; container hulls can
    /// only trade where this is True).
    crane: Bool,
    /// Walkable concourse interior — the station's canonical geometry.
    concourse: DeckPlan,
  )
}

/// Read and decode a station class document from a file (built-in glyph
/// legend).
pub fn load(path: String) -> Result(StationClass, String) {
  load_with(glyphs.default(), path)
}

/// `load`, interpreting the concourse grid with an explicit glyph registry.
pub fn load_with(reg: Registry, path: String) -> Result(StationClass, String) {
  use text <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(err) {
      "failed to read station class file "
      <> path
      <> ": "
      <> string.inspect(err)
    }),
  )
  decode_with(reg, text)
}

/// Decode a station class document from a JSON string (built-in glyph legend).
pub fn decode(json_text: String) -> Result(StationClass, String) {
  decode_with(glyphs.default(), json_text)
}

/// `decode`, interpreting the concourse grid with an explicit glyph registry,
/// validating the concourse geometry and its docking ports.
pub fn decode_with(
  reg: Registry,
  json_text: String,
) -> Result(StationClass, String) {
  case json.parse(json_text, station_class_decoder(reg)) {
    Ok(class) -> validate(class)
    Error(err) ->
      Error("invalid station class document: " <> string.inspect(err))
  }
}

/// Load every `*.json` station class in `dir`, keyed by class id (built-in
/// glyph legend). A duplicate id or a file that fails to decode is an error.
pub fn load_dir(dir: String) -> Result(Dict(String, StationClass), String) {
  load_dir_with(glyphs.default(), dir)
}

/// `load_dir`, interpreting concourse grids with an explicit glyph registry.
pub fn load_dir_with(
  reg: Registry,
  dir: String,
) -> Result(Dict(String, StationClass), String) {
  use entries <- result.try(
    simplifile.read_directory(dir)
    |> result.map_error(fn(e) {
      "failed to read station class dir " <> dir <> ": " <> string.inspect(e)
    }),
  )
  let files =
    entries
    |> list.filter(string.ends_with(_, ".json"))
    |> list.sort(string.compare)
  list.try_fold(files, dict.new(), fn(acc, file) {
    use sc <- result.try(load_with(reg, dir <> "/" <> file))
    case dict.has_key(acc, sc.id) {
      True -> Error("duplicate station class id: " <> sc.id)
      False -> Ok(dict.insert(acc, sc.id, sc))
    }
  })
}

fn validate(class: StationClass) -> Result(StationClass, String) {
  use _ <- result.try(deckplan.validate(class.concourse))
  use _ <- result.try(deckplan.validate_docking_ports(class.concourse))
  Ok(class)
}

fn station_class_decoder(reg: Registry) -> decode.Decoder(StationClass) {
  use _schema <- decode.field("schema", decode.int)
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use dock_radius <- decode.field("dock_radius", decode.float)
  use crane <- decode.optional_field("crane", False, decode.bool)
  use concourse <- decode.then(deckplan.decoder(reg))
  decode.success(StationClass(
    id: id,
    name: name,
    dock_radius: dock_radius,
    crane: crane,
    concourse: concourse,
  ))
}
