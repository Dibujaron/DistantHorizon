import dh_server/names
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string

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

fn parse_json_dynamic(text: String) -> Dynamic {
  let assert Ok(value) = json.parse(text, decode.dynamic)
  value
}

pub fn constraint_satisfaction_test() {
  let wake_or_breakers =
    names.Any([
      names.AttrIs("faction", "wake"),
      names.AttrIs("faction", "breakers"),
    ])
  let attrs = names.satisfying_character_attrs(Some(wake_or_breakers))
  assert attrs != []
  list.each(attrs, fn(a) {
    assert a.faction == "wake" || a.faction == "breakers"
  })

  let not_high = names.Not(names.AttrIs("wealth", "high"))
  let modest = names.satisfying_character_attrs(Some(not_high))
  assert modest != []
  list.each(modest, fn(a) {
    assert a.wealth != "high"
  })

  // Contradictions produce the empty list, not a crash.
  let impossible =
    names.All([names.AttrIs("race", "senti"), names.AttrIs("race", "human")])
  assert names.satisfying_character_attrs(Some(impossible)) == []

  // Unconstrained = the whole domain: 4 races x 5 factions x 3 wealth x 3 genders.
  assert list.length(names.satisfying_character_attrs(None)) == 180
}

pub fn ship_constraint_satisfaction_test() {
  let packet = names.AttrIs("role", "packet")
  let attrs = names.satisfying_ship_attrs(Some(packet))
  // 1 role x 5 factions x 10 manufacturers.
  assert list.length(attrs) == 50
  list.each(attrs, fn(a) {
    assert a.role == "packet"
  })
}

pub fn parse_constraint_test() {
  let dyn =
    parse_json_dynamic(
      "{ \"faction_is\": \"${patron}\", \"not\": { \"wealth_is\": \"high\" } }",
    )
  let resolve = fn(slot) {
    case slot {
      "patron" -> Ok("wake")
      _ -> Error("unknown slot " <> slot)
    }
  }
  let assert Ok(constraint) = names.parse_constraint(dyn, resolve)
  let attrs = names.satisfying_character_attrs(Some(constraint))
  assert attrs != []
  list.each(attrs, fn(a) {
    assert a.faction == "wake"
    assert a.wealth != "high"
  })
}

pub fn parse_constraint_rejects_bind_leaves_test() {
  // Bind-context keys (station_is etc.) are not generation vocabulary.
  let dyn = parse_json_dynamic("{ \"station_is\": \"solis_ring\" }")
  let assert Error(_) = names.parse_constraint(dyn, fn(_) { Error("no slots") })
}

fn plain_tags(type_: String, part: String) -> names.Tags {
  names.Tags(
    type_:,
    part:,
    race: None,
    faction: None,
    wealth: None,
    gender: None,
    role: None,
    manufacturer: None,
  )
}

fn test_entries() -> List(names.Entry) {
  [
    names.Entry(
      "Jaya",
      names.Tags(..plain_tags("character", "given"), race: Some("human")),
    ),
    names.Entry(
      "Okafor",
      names.Tags(..plain_tags("character", "family"), faction: Some("wake")),
    ),
    names.Entry(
      "${given} ${family}",
      names.Tags(..plain_tags("character", "pattern"), race: Some("human")),
    ),
    names.Entry(
      "IMRI",
      names.Tags(..plain_tags("character", "full"), race: Some("senti")),
    ),
    names.Entry(
      "${full}",
      names.Tags(..plain_tags("character", "pattern"), race: Some("senti")),
    ),
    names.Entry(
      "Mr.",
      names.Tags(..plain_tags("character", "title"), gender: Some("male")),
    ),
    names.Entry(
      "Ms.",
      names.Tags(..plain_tags("character", "title"), gender: Some("female")),
    ),
    names.Entry(
      "Mx.",
      names.Tags(..plain_tags("character", "title"), gender: Some("neutral")),
    ),
    names.Entry(
      "Cormorant's Debt",
      names.Tags(..plain_tags("ship", "full"), role: Some("packet")),
    ),
    names.Entry("${full}", plain_tags("ship", "pattern")),
  ]
}

pub fn generate_person_deterministic_test() {
  let entries = test_entries()
  let constraint =
    Some(
      names.All([
        names.AttrIs("race", "human"),
        names.AttrIs("faction", "wake"),
        names.AttrIs("gender", "female"),
      ]),
    )
  let assert Ok(person) = names.generate_person(constraint, entries, "seed-1")
  let assert Ok(again) = names.generate_person(constraint, entries, "seed-1")
  assert person == again
  // Only one candidate name in these pools, so the render is exact.
  assert person.full == "Jaya Okafor"
  // Wake is a gendered-address culture: she/her, Ms.
  assert person.effective_gender == "female"
  assert person.title == "Ms."
  let assert Ok(short) = names.form(person, "short")
  assert short == "J. Okafor"
  let assert Ok(ey) = names.form(person, "Ey")
  assert ey == "She"
  let assert Ok(eir) = names.form(person, "eir")
  assert eir == "her"
}

pub fn generate_senti_test() {
  let entries = test_entries()
  let assert Ok(person) =
    names.generate_person(Some(names.AttrIs("race", "senti")), entries, "s2")
  assert person.race == "senti"
  assert person.full == "IMRI"
  // Senti address is always neutral, whatever the gender roll said.
  assert person.effective_gender == "neutral"
  assert person.title == "Mx."
  // Cultures without a given/family component fall back to the full name.
  let assert Ok(given) = names.form(person, "given")
  assert given == "IMRI"
  let assert Ok(short) = names.form(person, "short")
  assert short == "IMRI"
  let assert Ok(eir) = names.form(person, "eir")
  assert eir == "eir"
  let assert Ok(emself) = names.form(person, "Emself")
  assert emself == "Emself"
}

pub fn generate_person_unsatisfiable_test() {
  let impossible =
    names.All([names.AttrIs("race", "senti"), names.AttrIs("race", "human")])
  let assert Error(_) =
    names.generate_person(Some(impossible), test_entries(), "seed")
}

pub fn generate_ship_test() {
  let entries = test_entries()
  let constraint = Some(names.AttrIs("role", "packet"))
  let assert Ok(ship) = names.generate_ship(constraint, entries, "seed-3")
  assert ship.role == "packet"
  assert ship.name == "Cormorant's Debt"
  let assert Ok(role) = names.ship_form(ship, "role")
  assert role == "Fast Packet"
  let assert Ok(again) = names.generate_ship(constraint, entries, "seed-3")
  assert ship == again
}

pub fn possible_effective_genders_test() {
  let core =
    names.CharacterAttrs(
      race: "human",
      faction: "uce",
      wealth: "mid",
      gender: "female",
    )
  assert names.possible_effective_genders(core) == ["female"]
  let frontier =
    names.CharacterAttrs(
      race: "human",
      faction: "freehold",
      wealth: "mid",
      gender: "female",
    )
  assert list.sort(names.possible_effective_genders(frontier), string.compare)
    == ["female", "neutral"]
  let grafter =
    names.CharacterAttrs(
      race: "grafter",
      faction: "freehold",
      wealth: "low",
      gender: "male",
    )
  assert names.possible_effective_genders(grafter) == ["neutral"]
}

pub fn family_hyphenation_is_occasional_test() {
  // Only one family entry exists in test_entries(), so the deterministic
  // tests above can never hyphenate. Here: two candidate families, 100
  // fixed seeds — hyphenation must appear, but stay well short of the norm.
  let entries = [
    names.Entry(
      "Jaya",
      names.Tags(..plain_tags("character", "given"), race: Some("human")),
    ),
    names.Entry(
      "Okafor",
      names.Tags(..plain_tags("character", "family"), race: Some("human")),
    ),
    names.Entry(
      "Calder",
      names.Tags(..plain_tags("character", "family"), race: Some("human")),
    ),
    names.Entry(
      "${given} ${family}",
      names.Tags(..plain_tags("character", "pattern"), race: Some("human")),
    ),
    names.Entry(
      "Mr.",
      names.Tags(..plain_tags("character", "title"), gender: Some("male")),
    ),
    names.Entry(
      "Ms.",
      names.Tags(..plain_tags("character", "title"), gender: Some("female")),
    ),
    names.Entry(
      "Mx.",
      names.Tags(..plain_tags("character", "title"), gender: Some("neutral")),
    ),
  ]
  let constraint = Some(names.AttrIs("race", "human"))
  let hyphenated =
    list.repeat(Nil, 100)
    |> list.index_map(fn(_, i) { i })
    |> list.filter(fn(i) {
      let assert Ok(person) =
        names.generate_person(constraint, entries, "hyph-" <> int.to_string(i))
      string.contains(person.full, "-")
    })
  assert hyphenated != []
  assert list.length(hyphenated) < 30
}

pub fn generate_from_real_pools_test() {
  // The shipped data can dress a Wake character of any race the roll picks.
  let assert Ok(entries) = names.load("names")
  let assert Ok(person) =
    names.generate_person(
      Some(names.AttrIs("faction", "wake")),
      entries,
      "integration-seed",
    )
  assert person.faction == "wake"
  assert person.full != ""
  assert person.title != ""
}
