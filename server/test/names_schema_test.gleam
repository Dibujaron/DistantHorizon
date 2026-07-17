import dh_server/names
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import simplifile

@external(erlang, "quest_schema_ffi", "validate")
fn validate_with_schema(schema: Dynamic, value: Dynamic) -> Result(Nil, String)

const schema_path = "schemas/names.schema.json"

const names_dir = "names"

fn read_json(path: String) -> Dynamic {
  let assert Ok(text) = simplifile.read(path)
  parse_json(text)
}

fn parse_json(text: String) -> Dynamic {
  let assert Ok(value) = json.parse(text, decode.dynamic)
  value
}

fn names_files() -> List(String) {
  let assert Ok(entries) = simplifile.read_directory(names_dir)
  entries
  |> list.filter(string.ends_with(_, ".json"))
  |> list.sort(string.compare)
}

pub fn all_names_files_match_schema_test() {
  let schema = read_json(schema_path)
  let files = names_files()
  // Guards against a typo'd glob silently validating nothing.
  assert files != []
  list.each(files, fn(file) {
    let value = read_json(names_dir <> "/" <> file)
    case validate_with_schema(schema, value) {
      Ok(Nil) -> Nil
      Error(message) -> panic as { file <> ": " <> message }
    }
  })
}

const quests_dir = "quests"

pub fn name_tags_use_canonical_ids_test() {
  // Race/wealth/gender/role are closed enums in the schema; faction and
  // manufacturer are open strings there, so pin them to the canonical
  // domain constants here (world files carry no factions yet).
  let assert Ok(entries) = names.load(names_dir)
  list.each(entries, fn(entry) {
    case entry.tags.faction {
      Some(faction) -> {
        assert list.contains(names.factions, faction)
        Nil
      }
      None -> Nil
    }
    case entry.tags.manufacturer {
      Some(manufacturer) -> {
        assert list.contains(names.manufacturers, manufacturer)
        Nil
      }
      None -> Nil
    }
  })
}

type SlotInfo {
  SlotInfo(kind: String, constraints: Option(Dynamic))
}

fn slot_info_decoder() -> decode.Decoder(SlotInfo) {
  use kind <- decode.optional_field("kind", "", decode.string)
  use constraints <- decode.optional_field(
    "constraints",
    None,
    decode.map(decode.dynamic, Some),
  )
  decode.success(SlotInfo(kind:, constraints:))
}

fn quest_slot_infos(file: String) -> dict.Dict(String, SlotInfo) {
  let assert Ok(text) = simplifile.read(quests_dir <> "/" <> file)
  let decoder = {
    use slots <- decode.optional_field(
      "slots",
      dict.new(),
      decode.dict(decode.string, slot_info_decoder()),
    )
    decode.success(slots)
  }
  let assert Ok(slots) = json.parse(text, decoder)
  slots
}

/// Slots of kind faction with a literal id constraint, e.g.
/// "wake": {kind: faction, constraints: {id: "wake"}} -> wake=wake.
/// Generation constraints may interpolate ONLY these (coverage must be
/// statically checkable; anything else panics).
fn faction_literals(
  slots: dict.Dict(String, SlotInfo),
) -> dict.Dict(String, String) {
  dict.fold(slots, dict.new(), fn(acc, name, info) {
    case info.kind, info.constraints {
      "faction", Some(dyn) ->
        case decode.run(dyn, decode.at(["id"], decode.string)) {
          Ok(id) -> dict.insert(acc, name, id)
          Error(_) -> acc
        }
      _, _ -> acc
    }
  })
}

fn quest_files_list() -> List(String) {
  let assert Ok(entries) = simplifile.read_directory(quests_dir)
  entries
  |> list.filter(string.ends_with(_, ".json"))
  |> list.sort(string.compare)
}

fn parse_generation_constraint(
  context: String,
  constraints: Option(Dynamic),
  resolve: fn(String) -> Result(String, String),
) -> Option(names.Constraint) {
  case constraints {
    None -> None
    Some(dyn) ->
      case names.parse_constraint(dyn, resolve) {
        Ok(constraint) -> Some(constraint)
        Error(err) -> panic as { context <> err }
      }
  }
}

fn check_character_coverage(
  context: String,
  entries: List(names.Entry),
  attrs: names.CharacterAttrs,
) {
  let effective_genders = names.possible_effective_genders(attrs)
  let patterns = names.matching_patterns_for_character(entries, attrs)
  case patterns {
    [] -> panic as { context <> "no pattern matches " <> string.inspect(attrs) }
    _ -> Nil
  }
  list.each(patterns, fn(pattern) {
    list.each(names.pattern_parts(pattern), fn(part) {
      list.each(effective_genders, fn(effective) {
        case names.character_pool(entries, attrs, part, effective) {
          [] ->
            panic as {
              context
              <> "empty pool for part "
              <> part
              <> " with "
              <> string.inspect(attrs)
            }
          _ -> Nil
        }
      })
    })
  })
  // ${x.title} must render even when no pattern uses it.
  list.each(effective_genders, fn(effective) {
    case names.character_pool(entries, attrs, "title", effective) {
      [] -> panic as { context <> "no title for " <> string.inspect(attrs) }
      _ -> Nil
    }
  })
}

fn check_ship_coverage(
  context: String,
  entries: List(names.Entry),
  attrs: names.ShipAttrs,
) {
  let patterns = names.matching_patterns_for_ship(entries, attrs)
  case patterns {
    [] -> panic as { context <> "no ship pattern matches " <> string.inspect(attrs) }
    _ -> Nil
  }
  list.each(patterns, fn(pattern) {
    list.each(names.pattern_parts(pattern), fn(part) {
      case names.ship_pool(entries, attrs, part) {
        [] ->
          panic as {
            context
            <> "empty ship pool for part "
            <> part
            <> " with "
            <> string.inspect(attrs)
          }
        _ -> Nil
      }
    })
  })
}

pub fn quest_principals_are_coverable_test() {
  // For every generated slot in every quest: at least one satisfying
  // attribute assignment exists, and EVERY satisfying assignment can be
  // fully dressed from the pools — holes fail the build, not the run.
  let assert Ok(entries) = names.load(names_dir)
  list.each(quest_files_list(), fn(file) {
    let slots = quest_slot_infos(file)
    let literals = faction_literals(slots)
    let resolve = fn(slot: String) {
      case dict.get(literals, slot) {
        Ok(id) -> Ok(id)
        Error(Nil) ->
          Error(
            "${"
            <> slot
            <> "} does not resolve to a literal faction slot — generation "
            <> "constraints must stay statically checkable",
          )
      }
    }
    dict.to_list(slots)
    |> list.each(fn(pair) {
      let #(slot_name, info) = pair
      let context = file <> " slot " <> slot_name <> ": "
      case info.kind {
        "character" -> {
          let constraint =
            parse_generation_constraint(context, info.constraints, resolve)
          let attrs = names.satisfying_character_attrs(constraint)
          assert attrs != []
          list.each(attrs, fn(a) {
            check_character_coverage(context, entries, a)
          })
        }
        "ship" -> {
          let constraint =
            parse_generation_constraint(context, info.constraints, resolve)
          let attrs = names.satisfying_ship_attrs(constraint)
          assert attrs != []
          list.each(attrs, fn(a) { check_ship_coverage(context, entries, a) })
        }
        _ -> Nil
      }
    })
  })
}

pub fn pattern_entries_are_well_formed_test() {
  // pattern_parts silently drops an unterminated "${" chunk, so a malformed
  // pattern would pass coverage yet fail at generation time — enforce
  // well-formedness here so holes fail the build, not the run.
  let assert Ok(entries) = names.load(names_dir)
  entries
  |> list.filter(fn(entry) { entry.tags.part == "pattern" })
  |> list.each(fn(entry) {
    string.split(entry.name, "${")
    |> list.drop(1)
    |> list.each(fn(chunk) {
      case string.contains(chunk, "}") {
        True -> Nil
        False -> panic as { "malformed pattern entry: " <> entry.name }
      }
    })
  })
}
