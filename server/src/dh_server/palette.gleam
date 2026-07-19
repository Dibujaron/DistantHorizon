//// The 16-colour tile palette (issue #29), loaded at startup from
//// `server/colors.json`. The array index IS the NE-corner hex digit an
//// author writes: index 0-9 = '0'-'9', index 10-15 = 'a'-'f'. Sprites are
//// authored greyscale and MULTIPLIED by the slot colour at render, so
//// retuning a hex here recolours every tile using that slot without
//// re-authoring a single map.
////
//// `default()` is a built-in copy of the shipped `colors.json`, used as a
//// dev fallback when the file is unreadable; `palette_test` asserts it stays
//// identical to the file.

import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/result
import gleam/string
import simplifile

/// One palette slot: a human-readable `name` and its `hex` colour.
pub type Entry {
  Entry(name: String, hex: String)
}

/// The loaded palette: 16 entries, index = slot digit ('0'-'9', 'a'-'f').
pub type Palette {
  Palette(entries: List(Entry))
}

/// Number of entries in the palette (16 for the shipped file).
pub fn count(p: Palette) -> Int {
  list.length(p.entries)
}

/// Read and decode a palette from a file.
pub fn load(path: String) -> Result(Palette, String) {
  use text <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(e) {
      "failed to read palette " <> path <> ": " <> string.inspect(e)
    }),
  )
  json.parse(text, palette_decoder())
  |> result.map_error(fn(e) { "invalid palette: " <> string.inspect(e) })
}

fn palette_decoder() -> decode.Decoder(Palette) {
  use entries <- decode.field("palette", decode.list(entry_decoder()))
  decode.success(Palette(entries: entries))
}

fn entry_decoder() -> decode.Decoder(Entry) {
  use name <- decode.field("name", decode.string)
  use hex <- decode.field("hex", decode.string)
  decode.success(Entry(name: name, hex: hex))
}

/// Forwarded on `welcome` as a flat array of hex strings, index = slot digit.
pub fn encode(p: Palette) -> Json {
  json.array(p.entries, fn(e) { json.string(e.hex) })
}

// ------------------------------------------------------------- default ----

/// The built-in palette — a code mirror of the shipped `colors.json`. Used
/// as a fallback when the file cannot be read. Kept in sync with the file by
/// `palette_test`.
pub fn default() -> Palette {
  Palette([
    Entry("white", "#F9FFFE"),
    Entry("orange", "#F9801D"),
    Entry("magenta", "#C74EBD"),
    Entry("light_blue", "#3AB3DA"),
    Entry("yellow", "#FED83D"),
    Entry("lime", "#80C71F"),
    Entry("pink", "#F38BAA"),
    Entry("gray", "#474F52"),
    Entry("light_gray", "#9D9D97"),
    Entry("cyan", "#169C9C"),
    Entry("purple", "#8932B8"),
    Entry("blue", "#3C44AA"),
    Entry("brown", "#835432"),
    Entry("green", "#5E7C16"),
    Entry("red", "#B02E26"),
    Entry("black", "#1D1D21"),
  ])
}
