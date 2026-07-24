//// An exterior PART: the shared, cross-hull half of the loadout. A part hangs
//// on a hull mount point of matching `kind` and sufficient `size`, contributes
//// its mass and its capability tags, and — for engines — carries the thrust and
//// torque that used to be global constants in `ship.gleam` (`docs/modules.md`).
////
//// Parts are shared across hulls by design: the Rijay nacelle the Mockingbird
//// mounts is the same document the Finch mounts. `sprite` is the client's key
//// for layering the part onto the hull at its mount; the layering itself lands
//// in M4 iteration 2, and until then the client draws the whole-hull bake.

import dh_server/hull
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile

pub type Part {
  Part(
    schema: Int,
    id: String,
    name: String,
    /// What sort of mount takes it — "engine" for now.
    kind: String,
    /// The ordered scale "s" | "m" | "l".
    size: String,
    mass: Float,
    provides: Dict(String, Int),
    requires: Dict(String, Int),
    /// Force along the heading; 0 for a non-engine part. Divided by the fit's
    /// total mass to give acceleration.
    thrust: Float,
    /// Turning authority; divided by total mass to give degrees/s.
    torque: Float,
    sprite: Option(String),
  )
}

/// Read and decode one part document.
pub fn load(path: String) -> Result(Part, String) {
  use text <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(err) {
      "failed to read part file " <> path <> ": " <> string.inspect(err)
    }),
  )
  decode(text)
}

/// Every `*.json` in `dir`, indexed by part id.
pub fn load_all(dir: String) -> Result(Dict(String, Part), String) {
  use names <- result.try(
    simplifile.read_directory(dir)
    |> result.map_error(fn(err) {
      "failed to list part directory " <> dir <> ": " <> string.inspect(err)
    }),
  )
  names
  |> list.filter(fn(n) { string.ends_with(n, ".json") })
  |> list.sort(string.compare)
  |> list.try_fold(dict.new(), fn(acc, name) {
    use p <- result.try(load(dir <> "/" <> name))
    case dict.has_key(acc, p.id) {
      True -> Error("duplicate part id \"" <> p.id <> "\" in " <> dir)
      False -> Ok(dict.insert(acc, p.id, p))
    }
  })
}

/// Decode a part document from JSON text.
pub fn decode(json_text: String) -> Result(Part, String) {
  case json.parse(json_text, part_decoder()) {
    Ok(p) ->
      case size_rank(p.size) {
        Ok(_) -> Ok(p)
        Error(Nil) ->
          Error("part \"" <> p.id <> "\" has size outside \"s\"|\"m\"|\"l\"")
      }
    Error(err) -> Error("invalid part document: " <> string.inspect(err))
  }
}

/// The size scale as an ordering: a mount takes any part of its kind whose
/// rank is at most the mount's.
pub fn size_rank(size: String) -> Result(Int, Nil) {
  case size {
    "s" -> Ok(0)
    "m" -> Ok(1)
    "l" -> Ok(2)
    _ -> Error(Nil)
  }
}

fn part_decoder() -> decode.Decoder(Part) {
  use schema <- decode.field("schema", decode.int)
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use kind <- decode.field("kind", decode.string)
  use size <- decode.field("size", decode.string)
  use mass <- decode.optional_field("mass", 0.0, decode.float)
  use provides <- decode.optional_field(
    "provides",
    dict.new(),
    hull.tags_decoder(),
  )
  use requires <- decode.optional_field(
    "requires",
    dict.new(),
    hull.tags_decoder(),
  )
  use thrust <- decode.optional_field("thrust", 0.0, decode.float)
  use torque <- decode.optional_field("torque", 0.0, decode.float)
  use sprite <- decode.optional_field(
    "sprite",
    None,
    decode.map(decode.string, Some),
  )
  decode.success(Part(
    schema: schema,
    id: id,
    name: name,
    kind: kind,
    size: size,
    mass: mass,
    provides: provides,
    requires: requires,
    thrust: thrust,
    torque: torque,
    sprite: sprite,
  ))
}
