//// An interior MODULE: a per-(hull, slot) hand-authored overlay, drawn in the
//// same 3x3-per-cell ASCII the hull itself uses (`docs/deckplan-format.md`).
//// Installing it stamps its patches onto the hull's rows, where **a void cell
//// leaves the hull untouched and any other cell overwrites it**
//// (`docs/modules.md`). Because the overlay is drawn against one specific
//// hull's coordinate space, shape-matching never happens: the doors line up
//// because a human drew them lining up, and loadout validation never does
//// reachability analysis.

import dh_server/hull
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import simplifile

/// One rectangle of overlay, `rows` in the 3x3 block format, with its top-left
/// TILE (not character) position on deck `deck` of the hull.
pub type Patch {
  Patch(deck: Int, x: Int, y: Int, rows: List(String))
}

pub type Module {
  Module(
    schema: Int,
    id: String,
    /// The hull id this overlay is drawn for. A module is never portable
    /// between hulls — that is the whole trade the design makes.
    hull: String,
    /// The hull slot id it occupies.
    slot: String,
    name: String,
    mass: Float,
    provides: Dict(String, Int),
    requires: Dict(String, Int),
    patches: List(Patch),
  )
}

/// Read and decode one module document.
pub fn load(path: String) -> Result(Module, String) {
  use text <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(err) {
      "failed to read module file " <> path <> ": " <> string.inspect(err)
    }),
  )
  decode(text)
}

/// Every module under `dir`, indexed by id. Modules are filed per hull
/// (`server/modules/<hull>/<id>.json`), so this walks one level of
/// subdirectories as well as any loose files.
pub fn load_all(dir: String) -> Result(Dict(String, Module), String) {
  use entries <- result.try(
    simplifile.read_directory(dir)
    |> result.map_error(fn(err) {
      "failed to list module directory " <> dir <> ": " <> string.inspect(err)
    }),
  )
  let sorted = list.sort(entries, string.compare)
  use files <- result.try(
    list.try_fold(sorted, [], fn(acc, entry) {
      let path = dir <> "/" <> entry
      case string.ends_with(entry, ".json") {
        True -> Ok(list.append(acc, [path]))
        False ->
          case simplifile.is_directory(path) {
            // A stray non-directory file: skip it rather than fail the
            // whole registry.
            Ok(False) -> Ok(acc)
            // A genuine per-hull directory: read it, and propagate any
            // error from that read instead of silently losing its modules.
            Ok(True) ->
              case simplifile.read_directory(path) {
                Error(err) ->
                  Error(
                    "failed to list module directory "
                    <> path
                    <> ": "
                    <> string.inspect(err),
                  )
                Ok(inner) ->
                  Ok(list.append(
                    acc,
                    inner
                      |> list.filter(fn(n) { string.ends_with(n, ".json") })
                      |> list.sort(string.compare)
                      |> list.map(fn(n) { path <> "/" <> n }),
                  ))
              }
            Error(err) ->
              Error(
                "failed to check module directory "
                <> path
                <> ": "
                <> string.inspect(err),
              )
          }
      }
    }),
  )
  list.try_fold(files, dict.new(), fn(acc, path) {
    use m <- result.try(load(path))
    case dict.has_key(acc, m.id) {
      True -> Error("duplicate module id \"" <> m.id <> "\" at " <> path)
      False -> Ok(dict.insert(acc, m.id, m))
    }
  })
}

/// Decode a module document from JSON text.
pub fn decode(json_text: String) -> Result(Module, String) {
  case json.parse(json_text, module_decoder()) {
    Ok(m) -> validate(m)
    Error(err) -> Error("invalid module document: " <> string.inspect(err))
  }
}

fn validate(m: Module) -> Result(Module, String) {
  list.try_fold(m.patches, m, fn(_, p) {
    let count = list.length(p.rows)
    let lengths = list.map(p.rows, string.length)
    let ok =
      count > 0
      && count % 3 == 0
      && list.all(lengths, fn(l) { l > 0 && l % 3 == 0 })
      && list.length(list.unique(lengths)) == 1
    case ok, p.deck >= 0 && p.x >= 0 && p.y >= 0 {
      True, True -> Ok(m)
      _, _ ->
        Error(
          "module \""
          <> m.id
          <> "\" has a patch that is not a positive multiple of 3 in both "
          <> "dimensions with a non-negative origin",
        )
    }
  })
}

fn module_decoder() -> decode.Decoder(Module) {
  use schema <- decode.field("schema", decode.int)
  use id <- decode.field("id", decode.string)
  use hull_id <- decode.field("hull", decode.string)
  use slot <- decode.field("slot", decode.string)
  use name <- decode.field("name", decode.string)
  use mass <- decode.optional_field("mass", 0.0, hull.number_decoder())
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
  use patches <- decode.optional_field(
    "patches",
    [],
    decode.list(patch_decoder()),
  )
  decode.success(Module(
    schema: schema,
    id: id,
    hull: hull_id,
    slot: slot,
    name: name,
    mass: mass,
    provides: provides,
    requires: requires,
    patches: patches,
  ))
}

fn patch_decoder() -> decode.Decoder(Patch) {
  use deck <- decode.field("deck", decode.int)
  use x <- decode.field("x", decode.int)
  use y <- decode.field("y", decode.int)
  use rows <- decode.field("grid", decode.list(decode.string))
  decode.success(Patch(deck: deck, x: x, y: y, rows: rows))
}
