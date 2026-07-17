//// Name pools and principal generation for quest slots.
////
//// Quests declare generated principals (character/ship slots); this module
//// loads the tag-matched pools in server/names/ and will generate typed
//// Person/Ship records deterministically from a seed (see the 2026-07-17
//// quest-principals spec). Files are organizational only: entries merge
//// into pools keyed purely by tags, so mods extend any pool by dropping a
//// new file in the folder.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile

/// Canonical domain vocabularies. The closed ones are mirrored as enums in
/// schemas/names.schema.json; factions and manufacturers are open strings
/// there and cross-checked against these at test time (world files carry no
/// factions yet, so these constants are the authority until they do).
pub const races = ["human", "selkie", "grafter", "senti"]

pub const factions = ["uce", "freehold", "company", "wake", "breakers"]

pub const wealths = ["low", "mid", "high"]

pub const genders = ["female", "male", "neutral"]

pub const ship_roles = ["packet", "hauler", "liner", "gunship", "tug", "yacht"]

pub const manufacturers = [
  "rijay", "porter", "harrow", "theseus", "deepwright", "aratori", "bureau",
  "consolidated", "lintel_vastworks", "apogee_grand",
]

/// Effective tags on one pool entry. `None` on an axis = usable for anyone.
pub type Tags {
  Tags(
    type_: String,
    part: String,
    race: Option(String),
    faction: Option(String),
    wealth: Option(String),
    gender: Option(String),
    role: Option(String),
    manufacturer: Option(String),
  )
}

pub type Entry {
  Entry(name: String, tags: Tags)
}

/// Parse one names file (already validated against names.schema.json by the
/// data tests; this decoder is the typed boundary).
pub fn parse_names_file(text: String) -> Result(List(Entry), String) {
  json.parse(text, entries_decoder())
  |> result.map_error(fn(err) {
    "invalid names file: " <> string.inspect(err)
  })
}

/// Load and merge every *.json in dir. Filenames carry no meaning.
pub fn load(dir: String) -> Result(List(Entry), String) {
  use files <- result.try(
    simplifile.read_directory(dir)
    |> result.map_error(fn(err) {
      "failed to read names dir " <> dir <> ": " <> string.inspect(err)
    }),
  )
  files
  |> list.filter(string.ends_with(_, ".json"))
  |> list.sort(string.compare)
  |> list.try_map(fn(file) {
    use text <- result.try(
      simplifile.read(dir <> "/" <> file)
      |> result.map_error(fn(err) {
        "failed to read " <> file <> ": " <> string.inspect(err)
      }),
    )
    parse_names_file(text)
    |> result.map_error(fn(err) { file <> ": " <> err })
  })
  |> result.map(list.flatten)
}

fn entries_decoder() -> decode.Decoder(List(Entry)) {
  use base <- decode.field("tags", base_tags_decoder())
  use entries <- decode.field("entries", decode.list(entry_decoder(base)))
  decode.success(entries)
}

fn base_tags_decoder() -> decode.Decoder(Tags) {
  use type_ <- decode.field("type", decode.string)
  use part <- decode.field("part", decode.string)
  use race <- decode.optional_field("race", None, some_string())
  use faction <- decode.optional_field("faction", None, some_string())
  use wealth <- decode.optional_field("wealth", None, some_string())
  use gender <- decode.optional_field("gender", None, some_string())
  use role <- decode.optional_field("role", None, some_string())
  use manufacturer <- decode.optional_field("manufacturer", None, some_string())
  decode.success(Tags(
    type_:,
    part:,
    race:,
    faction:,
    wealth:,
    gender:,
    role:,
    manufacturer:,
  ))
}

fn some_string() -> decode.Decoder(Option(String)) {
  decode.map(decode.string, Some)
}

fn entry_decoder(base: Tags) -> decode.Decoder(Entry) {
  let object = {
    use name <- decode.field("name", decode.string)
    use tags <- decode.optional_field("tags", base, override_tags_decoder(base))
    decode.success(Entry(name:, tags:))
  }
  let plain = decode.map(decode.string, fn(name) { Entry(name:, tags: base) })
  decode.one_of(plain, or: [object])
}

fn override_tags_decoder(base: Tags) -> decode.Decoder(Tags) {
  use race <- decode.optional_field("race", base.race, some_string())
  use faction <- decode.optional_field("faction", base.faction, some_string())
  use wealth <- decode.optional_field("wealth", base.wealth, some_string())
  use gender <- decode.optional_field("gender", base.gender, some_string())
  use role <- decode.optional_field("role", base.role, some_string())
  use manufacturer <- decode.optional_field(
    "manufacturer",
    base.manufacturer,
    some_string(),
  )
  decode.success(
    Tags(..base, race:, faction:, wealth:, gender:, role:, manufacturer:),
  )
}
