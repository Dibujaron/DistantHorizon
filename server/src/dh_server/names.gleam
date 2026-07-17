//// Name pools and principal generation for quest slots.
////
//// Quests declare generated principals (character/ship slots); this module
//// loads the tag-matched pools in server/names/ and will generate typed
//// Person/Ship records deterministically from a seed (see the 2026-07-17
//// quest-principals spec). Files are organizational only: entries merge
//// into pools keyed purely by tags, so mods extend any pool by dropping a
//// new file in the folder.

import gleam/bit_array
import gleam/crypto
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
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

/// A generated character principal: attributes plus rendered name material.
/// effective_gender is the address-style-adjusted gender that titles and
/// pronouns render with (a grafter woman is still a woman; prose calls em
/// ey).
pub type Person {
  Person(
    race: String,
    faction: String,
    wealth: String,
    gender: String,
    effective_gender: String,
    full: String,
    given: Option(String),
    family: Option(String),
    title: String,
  )
}

pub type Ship {
  Ship(role: String, faction: String, manufacturer: String, name: String)
}

type Pronouns {
  Pronouns(ey: String, em: String, eir: String, eirs: String, emself: String)
}

/// Deterministic seeded pick: SHA-256 of the seed string, first 48 bits as
/// an index. Same pools + same constraint + same seed = same principal.
fn hash_int(seed: String) -> Int {
  let hex =
    crypto.hash(crypto.Sha256, bit_array.from_string(seed))
    |> bit_array.base16_encode
  let assert Ok(n) = int.base_parse(string.slice(hex, 0, 12), 16)
  n
}

fn pick(items: List(a), seed: String) -> Result(a, Nil) {
  case items {
    [] -> Error(Nil)
    _ -> {
      let assert Ok(index) = int.modulo(hash_int(seed), list.length(items))
      items
      |> list.drop(index)
      |> list.first
    }
  }
}

fn tag_ok(tag: Option(String), value: String) -> Bool {
  case tag {
    None -> True
    Some(tagged) -> tagged == value
  }
}

/// Entries usable for `part` on a character with attributes `a`. Titles
/// match against the effective (address-adjusted) gender; everything else
/// against the rolled gender. Ship-only axes on a character entry never
/// match.
pub fn character_pool(
  entries: List(Entry),
  a: CharacterAttrs,
  part: String,
  effective_gender: String,
) -> List(String) {
  let gender = case part {
    "title" -> effective_gender
    _ -> a.gender
  }
  entries
  |> list.filter(fn(entry) {
    let tags = entry.tags
    tags.type_ == "character"
    && tags.part == part
    && tag_ok(tags.race, a.race)
    && tag_ok(tags.faction, a.faction)
    && tag_ok(tags.wealth, a.wealth)
    && tag_ok(tags.gender, gender)
    && tags.role == None
    && tags.manufacturer == None
  })
  |> list.map(fn(entry) { entry.name })
}

pub fn ship_pool(
  entries: List(Entry),
  a: ShipAttrs,
  part: String,
) -> List(String) {
  entries
  |> list.filter(fn(entry) {
    let tags = entry.tags
    tags.type_ == "ship"
    && tags.part == part
    && tag_ok(tags.role, a.role)
    && tag_ok(tags.faction, a.faction)
    && tag_ok(tags.manufacturer, a.manufacturer)
    && tags.race == None
    && tags.wealth == None
    && tags.gender == None
  })
  |> list.map(fn(entry) { entry.name })
}

pub fn matching_patterns_for_character(
  entries: List(Entry),
  a: CharacterAttrs,
) -> List(String) {
  character_pool(entries, a, "pattern", a.gender)
}

pub fn matching_patterns_for_ship(
  entries: List(Entry),
  a: ShipAttrs,
) -> List(String) {
  ship_pool(entries, a, "pattern")
}

/// The part names a pattern references, e.g. "${given} ${family}" ->
/// ["given", "family"].
pub fn pattern_parts(pattern: String) -> List(String) {
  string.split(pattern, "${")
  |> list.drop(1)
  |> list.filter_map(fn(chunk) {
    string.split_once(chunk, "}")
    |> result.map(fn(pair) { pair.0 })
  })
}

fn render_pattern(
  pattern: String,
  resolve_part: fn(String) -> Result(String, String),
) -> Result(String, String) {
  case string.split(pattern, "${") {
    [] -> Ok("")
    [head, ..chunks] ->
      list.try_fold(chunks, head, fn(acc, chunk) {
        case string.split_once(chunk, "}") {
          Ok(#(part, rest)) ->
            resolve_part(part)
            |> result.map(fn(value) { acc <> value <> rest })
          Error(Nil) -> Error("unterminated ${ in pattern: " <> pattern)
        }
      })
  }
}

/// Which address styles a character's culture can produce. Race trumps
/// faction; mixed cultures return both and generation flips a seeded coin.
pub fn possible_address_styles(race: String, faction: String) -> List(String) {
  case race {
    "senti" | "grafter" -> ["neutral"]
    _ ->
      case faction {
        "uce" | "company" | "wake" -> ["gendered"]
        "freehold" | "breakers" -> ["gendered", "neutral"]
        // TODO(lore): Selkie address style deliberately undecided (spec
        // 2026-07-17 §3); unknown factions take the conservative default
        // until this table moves data-side.
        _ -> ["gendered"]
      }
  }
}

fn effective_gender(gender: String, style: String) -> String {
  case gender, style {
    "neutral", _ -> "neutral"
    _, "neutral" -> "neutral"
    g, _ -> g
  }
}

/// All effective genders a character's culture could render — used by the
/// build-time coverage test so every reachable title/pronoun render is
/// backed by pool entries.
pub fn possible_effective_genders(a: CharacterAttrs) -> List(String) {
  possible_address_styles(a.race, a.faction)
  |> list.map(effective_gender(a.gender, _))
  |> list.unique
}

fn weighted_gender(genders: List(String), seed: String) -> String {
  // 475/475/50 tickets = the spec's 47.5/47.5/5 roll, restricted to the
  // genders the constraint left open.
  let tickets =
    list.flat_map(list.unique(genders), fn(gender) {
      case gender {
        "neutral" -> list.repeat(gender, 50)
        _ -> list.repeat(gender, 475)
      }
    })
  let assert Ok(gender) = pick(tickets, seed)
  gender
}

/// Chance per 1000 that a family name double-barrels from a second distinct
/// draw ("Sandoval-Okafor"). Hyphenated names are generated, never curated —
/// pools contain no hyphen entries (spec §2).
const double_family_chance_per_1000 = 100

fn maybe_hyphenate_family(
  resolved: List(#(String, String)),
  entries: List(Entry),
  attrs: CharacterAttrs,
  effective_gender: String,
  seed: String,
) -> List(#(String, String)) {
  case list.key_find(resolved, "family") {
    Error(Nil) -> resolved
    Ok(family) -> {
      let assert Ok(roll) = int.modulo(hash_int(seed <> ":hyphen"), 1000)
      case roll < double_family_chance_per_1000 {
        False -> resolved
        True ->
          case
            character_pool(entries, attrs, "family", effective_gender)
            |> list.filter(fn(other) { other != family })
            |> pick(seed <> ":family2")
          {
            Ok(second) ->
              list.key_set(resolved, "family", family <> "-" <> second)
            Error(Nil) -> resolved
          }
      }
    }
  }
}

pub fn generate_person(
  constraint: Option(Constraint),
  entries: List(Entry),
  seed: String,
) -> Result(Person, String) {
  let assignments = satisfying_character_attrs(constraint)
  let bodies =
    assignments
    |> list.map(fn(a) { #(a.race, a.faction, a.wealth) })
    |> list.unique
  use body <- result.try(
    pick(bodies, seed <> ":body")
    |> result.replace_error("no attribute assignment satisfies the constraints"),
  )
  let #(race, faction, wealth) = body
  let genders =
    assignments
    |> list.filter(fn(a) {
      a.race == race && a.faction == faction && a.wealth == wealth
    })
    |> list.map(fn(a) { a.gender })
  let gender = weighted_gender(genders, seed <> ":gender")
  let attrs = CharacterAttrs(race:, faction:, wealth:, gender:)
  let assert Ok(style) =
    pick(possible_address_styles(race, faction), seed <> ":address")
  let effective = effective_gender(gender, style)
  let patterns = matching_patterns_for_character(entries, attrs)
  use pattern <- result.try(
    pick(patterns, seed <> ":pattern")
    |> result.replace_error("no pattern matches " <> string.inspect(attrs)),
  )
  let parts = list.unique(pattern_parts(pattern))
  use resolved <- result.try(
    list.try_map(parts, fn(part) {
      pick(character_pool(entries, attrs, part, effective), seed <> ":" <> part)
      |> result.replace_error(
        "no entries for part " <> part <> " (" <> string.inspect(attrs) <> ")",
      )
      |> result.map(fn(value) { #(part, value) })
    }),
  )
  let resolved =
    maybe_hyphenate_family(resolved, entries, attrs, effective, seed)
  let lookup = dict.from_list(resolved)
  use full <- result.try(
    render_pattern(pattern, fn(part) {
      dict.get(lookup, part)
      |> result.replace_error("pattern part not resolved: " <> part)
    }),
  )
  // ${x.title} must render even when the pattern didn't use it.
  use title <- result.try(case dict.get(lookup, "title") {
    Ok(title) -> Ok(title)
    Error(Nil) ->
      pick(character_pool(entries, attrs, "title", effective), seed <> ":title")
      |> result.replace_error(
        "no title entry matches " <> string.inspect(attrs),
      )
  })
  Ok(Person(
    race:,
    faction:,
    wealth:,
    gender:,
    effective_gender: effective,
    full:,
    given: option.from_result(dict.get(lookup, "given")),
    family: option.from_result(dict.get(lookup, "family")),
    title:,
  ))
}

pub fn generate_ship(
  constraint: Option(Constraint),
  entries: List(Entry),
  seed: String,
) -> Result(Ship, String) {
  let assignments = satisfying_ship_attrs(constraint)
  use attrs <- result.try(
    pick(assignments, seed <> ":ship")
    |> result.replace_error("no ship attributes satisfy the constraints"),
  )
  let patterns = matching_patterns_for_ship(entries, attrs)
  use pattern <- result.try(
    pick(patterns, seed <> ":pattern")
    |> result.replace_error("no ship pattern matches"),
  )
  let parts = list.unique(pattern_parts(pattern))
  use resolved <- result.try(
    list.try_map(parts, fn(part) {
      pick(ship_pool(entries, attrs, part), seed <> ":" <> part)
      |> result.replace_error("no entries for ship part " <> part)
      |> result.map(fn(value) { #(part, value) })
    }),
  )
  let lookup = dict.from_list(resolved)
  use name <- result.try(
    render_pattern(pattern, fn(part) {
      dict.get(lookup, part)
      |> result.replace_error("pattern part not resolved: " <> part)
    }),
  )
  Ok(Ship(
    role: attrs.role,
    faction: attrs.faction,
    manufacturer: attrs.manufacturer,
    name:,
  ))
}

fn pronouns(effective: String) -> Pronouns {
  case effective {
    "female" -> Pronouns("she", "her", "her", "hers", "herself")
    "male" -> Pronouns("he", "him", "his", "his", "himself")
    _ -> Pronouns("ey", "em", "eir", "eirs", "emself")
  }
}

/// Resolve a dotted interpolation form (${x.<key>}) for a character.
/// Authors write prose in ey/em/eir; gendered-culture characters render
/// she/he. Capitalized keys are for sentence-initial position.
pub fn form(person: Person, key: String) -> Result(String, Nil) {
  let p = pronouns(person.effective_gender)
  case key {
    "given" -> Ok(option.unwrap(person.given, person.full))
    "family" -> Ok(option.unwrap(person.family, person.full))
    "short" ->
      case person.given, person.family {
        Some(given), Some(family) ->
          Ok(string.slice(given, 0, 1) <> ". " <> family)
        _, _ -> Ok(person.full)
      }
    "title" -> Ok(person.title)
    "ey" -> Ok(p.ey)
    "em" -> Ok(p.em)
    "eir" -> Ok(p.eir)
    "eirs" -> Ok(p.eirs)
    "emself" -> Ok(p.emself)
    "Ey" -> Ok(string.capitalise(p.ey))
    "Em" -> Ok(string.capitalise(p.em))
    "Eir" -> Ok(string.capitalise(p.eir))
    "Eirs" -> Ok(string.capitalise(p.eirs))
    "Emself" -> Ok(string.capitalise(p.emself))
    _ -> Error(Nil)
  }
}

pub fn role_display(role: String) -> String {
  case role {
    "packet" -> "Fast Packet"
    "hauler" -> "Bulk Hauler"
    "liner" -> "Liner"
    "gunship" -> "Gunship"
    "tug" -> "Tug"
    "yacht" -> "Yacht"
    other -> other
  }
}

pub fn ship_form(ship: Ship, key: String) -> Result(String, Nil) {
  case key {
    "role" -> Ok(role_display(ship.role))
    _ -> Error(Nil)
  }
}
