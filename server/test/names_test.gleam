import dh_server/names
import gleam/option.{None, Some}

pub fn parse_names_file_test() {
  let text =
    "{ \"schema\": 1,
       \"tags\": { \"type\": \"character\", \"part\": \"family\", \"faction\": \"wake\" },
       \"entries\": [ \"Okafor\", { \"name\": \"Adeyemi\", \"tags\": { \"wealth\": \"high\" } } ] }"
  let assert Ok([first, second]) = names.parse_names_file(text)
  assert first.name == "Okafor"
  assert first.tags.type_ == "character"
  assert first.tags.part == "family"
  assert first.tags.faction == Some("wake")
  assert first.tags.wealth == None
  // Entry-level tags override/extend the file defaults, never replace them.
  assert second.name == "Adeyemi"
  assert second.tags.faction == Some("wake")
  assert second.tags.wealth == Some("high")
}

pub fn parse_names_file_rejects_garbage_test() {
  let assert Error(_) = names.parse_names_file("{ \"entries\": [] }")
}

pub fn load_real_pools_test() {
  // Integration against the shipped data: the merge is across ALL files.
  let assert Ok(entries) = names.load("names")
  assert entries != []
}
