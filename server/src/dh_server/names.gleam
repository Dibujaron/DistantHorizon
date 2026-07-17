//// Name pools and principal generation for quest slots.
////
//// Quests declare generated principals (character/ship slots); this module
//// loads the tag-matched pools in server/names/ and will generate typed
//// Person/Ship records deterministically from a seed (see the 2026-07-17
//// quest-principals spec). Files are organizational only: entries merge
//// into pools keyed purely by tags, so mods extend any pool by dropping a
//// new file in the folder.

import gleam/dict
import gleam/dynamic.{type Dynamic}
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

/// The quest constraint AST, restricted to generation vocabulary. Over the
/// finite attribute domain a constraint is a *generator*: enumerate the
/// satisfying assignments, sample one with the seed.
pub type Constraint {
  Any(List(Constraint))
  All(List(Constraint))
  Not(Constraint)
  AttrIs(axis: String, value: String)
}

pub type CharacterAttrs {
  CharacterAttrs(race: String, faction: String, wealth: String, gender: String)
}

pub type ShipAttrs {
  ShipAttrs(role: String, faction: String, manufacturer: String)
}

/// Parse a quest slot's constraints object into a Constraint. `resolve`
/// turns a ${slot} interpolation into a literal id (the engine will resolve
/// against bound slots; tests resolve against literal faction slots).
pub fn parse_constraint(
  dyn: Dynamic,
  resolve: fn(String) -> Result(String, String),
) -> Result(Constraint, String) {
  use fields <- result.try(
    decode.run(dyn, decode.dict(decode.string, decode.dynamic))
    |> result.map_error(fn(_) { "constraint is not an object" }),
  )
  use parts <- result.try(
    fields
    |> dict.to_list
    // dict order is unspecified; sort so parsing is deterministic.
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    |> list.try_map(fn(field) {
      parse_constraint_field(field.0, field.1, resolve)
    }),
  )
  Ok(All(parts))
}

fn parse_constraint_field(
  key: String,
  value: Dynamic,
  resolve: fn(String) -> Result(String, String),
) -> Result(Constraint, String) {
  case key {
    "any" -> parse_constraint_list(value, resolve) |> result.map(Any)
    "all" -> parse_constraint_list(value, resolve) |> result.map(All)
    "not" -> parse_constraint(value, resolve) |> result.map(Not)
    "race_is" -> leaf("race", value, resolve)
    "faction_is" -> leaf("faction", value, resolve)
    "wealth_is" -> leaf("wealth", value, resolve)
    "gender_is" -> leaf("gender", value, resolve)
    "role_is" -> leaf("role", value, resolve)
    "manufacturer_is" -> leaf("manufacturer", value, resolve)
    other -> Error("constraint key not legal in generation context: " <> other)
  }
}

fn parse_constraint_list(
  value: Dynamic,
  resolve: fn(String) -> Result(String, String),
) -> Result(List(Constraint), String) {
  use items <- result.try(
    decode.run(value, decode.list(decode.dynamic))
    |> result.map_error(fn(_) { "any/all expects a list" }),
  )
  list.try_map(items, parse_constraint(_, resolve))
}

fn leaf(
  axis: String,
  value: Dynamic,
  resolve: fn(String) -> Result(String, String),
) -> Result(Constraint, String) {
  use raw <- result.try(
    decode.run(value, decode.string)
    |> result.map_error(fn(_) { axis <> "_is value must be a string" }),
  )
  use resolved <- result.try(case
    string.starts_with(raw, "${") && string.ends_with(raw, "}")
  {
    True -> resolve(string.slice(raw, 2, string.length(raw) - 3))
    False -> Ok(raw)
  })
  Ok(AttrIs(axis, resolved))
}

pub fn satisfying_character_attrs(
  constraint: Option(Constraint),
) -> List(CharacterAttrs) {
  list.flat_map(races, fn(race) {
    list.flat_map(factions, fn(faction) {
      list.flat_map(wealths, fn(wealth) {
        list.filter_map(genders, fn(gender) {
          let attrs = CharacterAttrs(race:, faction:, wealth:, gender:)
          case satisfied_character(constraint, attrs) {
            True -> Ok(attrs)
            False -> Error(Nil)
          }
        })
      })
    })
  })
}

pub fn satisfying_ship_attrs(constraint: Option(Constraint)) -> List(ShipAttrs) {
  list.flat_map(ship_roles, fn(role) {
    list.flat_map(factions, fn(faction) {
      list.filter_map(manufacturers, fn(manufacturer) {
        let attrs = ShipAttrs(role:, faction:, manufacturer:)
        case satisfied_ship(constraint, attrs) {
          True -> Ok(attrs)
          False -> Error(Nil)
        }
      })
    })
  })
}

fn satisfied_character(c: Option(Constraint), a: CharacterAttrs) -> Bool {
  case c {
    None -> True
    Some(c) ->
      eval(c, fn(axis) {
        case axis {
          "race" -> a.race
          "faction" -> a.faction
          "wealth" -> a.wealth
          "gender" -> a.gender
          _ -> ""
        }
      })
  }
}

fn satisfied_ship(c: Option(Constraint), a: ShipAttrs) -> Bool {
  case c {
    None -> True
    Some(c) ->
      eval(c, fn(axis) {
        case axis {
          "role" -> a.role
          "faction" -> a.faction
          "manufacturer" -> a.manufacturer
          _ -> ""
        }
      })
  }
}

fn eval(c: Constraint, get: fn(String) -> String) -> Bool {
  case c {
    Any(cs) -> list.any(cs, eval(_, get))
    All(cs) -> list.all(cs, eval(_, get))
    Not(inner) -> !eval(inner, get)
    AttrIs(axis, value) -> get(axis) == value
  }
}
