# Quest Principals & Name Pools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Quests declare generated principals — characters and ships — whose names are drawn deterministically from moddable, tag-matched name pools; all hardcoded names in stock quests become generated, plus one new ship quest.

**Architecture:** A new `server/names/` folder of JSON pool files (validated by `server/schemas/names.schema.json`, merged purely by tags — filenames mean nothing). A new `dh_server/names` Gleam module loads pools, evaluates the quest constraint AST as a *generator* over a small finite attribute domain, and renders typed `Person`/`Ship` records (full/given/family/short/title forms plus ey/em/eir pronoun rendering). The quest schema gains `character`/`ship` slot kinds (replacing unused `npc`), four generation leaf predicates, and an item→principal link. Data-contract tests (same jesse harness and style as the quest tests) enforce schema validity, coherence, and build-time pool coverage. Quest *engine* wiring stays deferred.

**Tech Stack:** Gleam (Erlang/OTP), jesse (JSON Schema draft-06) via existing `quest_schema_ffi.erl`, gleam_crypto (SHA-256 for deterministic seeded picks), simplifile, gleeunit.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-17-quest-principals-and-name-pools-design.md`. Read it before starting.
- All commands run in PowerShell from the worktree; the Gleam toolchain needs the scoop PATH prefix. The test command, verbatim (used in every task):
  `$env:PATH = "$env:USERPROFILE\scoop\shims;$env:PATH"; cd C:\Users\dibuj\dev\DistantHorizon\.claude\worktrees\quest-principals\server; gleam test`
  Expected baseline before Task 1: `177 passed, no failures` (5 "skipped: no DH_TEST_DATABASE_URL" lines are normal).
- JSON Schemas use draft-06: first line of every schema is `"$schema": "http://json-schema.org/draft-06/schema#"`.
- Canon pronouns (never improvise others): `ey / em / eir / eirs / emself`, grammatically singular ("ey keeps"). Gendered renders: she/her/her/hers/herself, he/him/his/his/himself.
- Domain vocabularies, verbatim (single source in code = `names.gleam` constants; the closed ones are mirrored as enums in `names.schema.json`):
  - races: `human`, `selkie`, `grafter`, `senti`
  - factions: `uce`, `freehold`, `company`, `wake`, `breakers`
  - wealth: `low`, `mid`, `high`
  - genders: `female`, `male`, `neutral`
  - ship roles: `packet`, `hauler`, `liner`, `gunship`, `tug`, `yacht`
  - manufacturers: `rijay`, `porter`, `harrow`, `theseus`, `deepwright`, `aratori`, `bureau`, `consolidated`, `lintel_vastworks`, `apogee_grand`
- Name-pool files are organizational only — the loader merges every `server/names/*.json` by tags. Never write code that gives a filename semantic meaning.
- Typed boundaries: parse JSON into named Gleam types at the edge (`Entry`, `Tags`, `Person`, `Ship`, `Constraint`); do not pass raw dicts/dynamics past the `names` module's public API.
- Commit style: conventional commits as in recent history (`feat(quests): …`, `test(server): …`). End every commit message with the line: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Gender roll weights when unpinned: 475/475/50 tickets (47.5% female / 47.5% male / 5% neutral).
- Address styles (code constant in `names.gleam`, v1): race `senti` or `grafter` → always neutral; else faction `uce`/`company`/`wake` → gendered; faction `freehold`/`breakers` → mixed (seeded per-character coin flip); anything else → gendered with a `// TODO(lore)` comment (Selkie address style is deliberately undecided).

---

### Task 1: Names schema + base name pools + validation test

**Files:**
- Create: `server/schemas/names.schema.json`
- Create: `server/names/titles.json`, `server/names/character_patterns.json`, `server/names/human_given.json`, `server/names/human_family.json`, `server/names/wake_family.json`, `server/names/uce_family.json`, `server/names/freehold_family.json`, `server/names/company_family.json`, `server/names/grafter_given.json`, `server/names/grafter_family.json`, `server/names/selkie_given.json`, `server/names/senti_designations.json`, `server/names/ship_names.json`, `server/names/ship_patterns.json`
- Test: `server/test/names_schema_test.gleam`

**Interfaces:**
- Consumes: `quest_schema_ffi.erl` (already exists; test FFI shared by module name).
- Produces: the `server/names/` data directory and `schemas/names.schema.json` that Tasks 2–7 load. Every pool file shape: `{"schema": 1, "tags": {"type": …, "part": …, …}, "entries": [string | {"name": …, "tags": {…}}]}`.

- [ ] **Step 1: Write the failing test**

Create `server/test/names_schema_test.gleam`:

```gleam
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
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
```

- [ ] **Step 2: Run test to verify it fails**

Run the global test command.
Expected: FAIL — `names_schema_test` crashes (`simplifile.read_directory` on missing `names` dir → `let assert` panic).

- [ ] **Step 3: Write the schema**

Create `server/schemas/names.schema.json`:

```json
{
  "$schema": "http://json-schema.org/draft-06/schema#",
  "$id": "https://distanthorizon.dev/schemas/names.schema.json",
  "title": "Distant Horizon name pool file",
  "description": "One file of name-pool entries. Files are organizational only: the loader merges every server/names/*.json (base game and mods alike) into pools keyed purely by effective tags — file-level tags are defaults, entry-level tags override per entry. An entry serves a generated principal iff every tag it declares is consistent with the principal's attributes; an untagged axis means 'usable for anyone'. part=pattern entries are templates over parts (e.g. \"${given} ${family}\"); part=title entries are honorifics selected by the principal's effective (address-style-adjusted) gender. See docs/superpowers/specs/2026-07-17-quest-principals-and-name-pools-design.md.",
  "type": "object",
  "required": ["schema", "tags", "entries"],
  "additionalProperties": false,
  "properties": {
    "schema": { "const": 1 },
    "tags": {
      "type": "object",
      "required": ["type", "part"],
      "additionalProperties": false,
      "properties": {
        "type": { "enum": ["character", "ship"] },
        "part": { "enum": ["given", "family", "full", "title", "pattern"] },
        "race": { "$ref": "#/definitions/race" },
        "faction": { "$ref": "#/definitions/id_string" },
        "wealth": { "$ref": "#/definitions/wealth" },
        "gender": { "$ref": "#/definitions/gender" },
        "role": { "$ref": "#/definitions/ship_role" },
        "manufacturer": { "$ref": "#/definitions/id_string" }
      }
    },
    "entries": {
      "type": "array",
      "minItems": 1,
      "items": {
        "oneOf": [
          { "type": "string", "minLength": 1 },
          {
            "type": "object",
            "required": ["name"],
            "additionalProperties": false,
            "properties": {
              "name": { "type": "string", "minLength": 1 },
              "tags": {
                "type": "object",
                "minProperties": 1,
                "additionalProperties": false,
                "properties": {
                  "race": { "$ref": "#/definitions/race" },
                  "faction": { "$ref": "#/definitions/id_string" },
                  "wealth": { "$ref": "#/definitions/wealth" },
                  "gender": { "$ref": "#/definitions/gender" },
                  "role": { "$ref": "#/definitions/ship_role" },
                  "manufacturer": { "$ref": "#/definitions/id_string" }
                }
              }
            }
          }
        ]
      }
    }
  },
  "definitions": {
    "race": { "enum": ["human", "selkie", "grafter", "senti"] },
    "wealth": { "enum": ["low", "mid", "high"] },
    "gender": { "enum": ["female", "male", "neutral"] },
    "ship_role": {
      "enum": ["packet", "hauler", "liner", "gunship", "tug", "yacht"],
      "description": "Shared with future hull auto-categorization; this enum is the authority until that feature lands."
    },
    "id_string": {
      "type": "string",
      "pattern": "^[a-z0-9_]+$",
      "description": "A faction or manufacturer id. Open vocabulary in the schema; cross-checked against the canonical domain constants in dh_server/names.gleam at test time (world files carry no factions yet)."
    }
  }
}
```

Note: entry-level tags deliberately exclude `type` and `part` (`additionalProperties: false`) — an entry can refine who it serves, never what it is.

- [ ] **Step 4: Write the pool files**

Create each file exactly as follows.

`server/names/titles.json`:

```json
{
  "schema": 1,
  "tags": { "type": "character", "part": "title" },
  "entries": [
    { "name": "Mr.", "tags": { "gender": "male" } },
    { "name": "Ms.", "tags": { "gender": "female" } },
    { "name": "Mx.", "tags": { "gender": "neutral" } }
  ]
}
```

`server/names/character_patterns.json`:

```json
{
  "schema": 1,
  "tags": { "type": "character", "part": "pattern" },
  "entries": [
    { "name": "${given} ${family}", "tags": { "race": "human" } },
    { "name": "${given} ${family}", "tags": { "race": "grafter" } },
    { "name": "${given}", "tags": { "race": "selkie" } },
    { "name": "${full}", "tags": { "race": "senti" } }
  ]
}
```

`server/names/human_given.json`:

```json
{
  "schema": 1,
  "tags": { "type": "character", "part": "given", "race": "human" },
  "entries": [
    "Jaya", "Adechike", "Mara", "Tomas", "Ines", "Kofi", "Yusuf", "Signe",
    "Priya", "Dario", "Wren", "Halim", "Sofia", "Emeka", "Lena", "Ravi"
  ]
}
```

`server/names/human_family.json`:

```json
{
  "schema": 1,
  "tags": { "type": "character", "part": "family", "race": "human" },
  "entries": [
    "Delgado", "Reyes", "Ilunga", "Novak", "Tran", "Bakari", "Lindqvist",
    "Osei", "Marchetti", "Duran", "Abara", "Kowalczyk"
  ]
}
```

`server/names/wake_family.json`:

```json
{
  "schema": 1,
  "tags": { "type": "character", "part": "family", "faction": "wake" },
  "entries": [
    "Okafor", "Ilesanmi", "Halvorsen", "Anand", "Petrossian", "Sandoval",
    "Kiuru", "Vasari", "Tennant", "Reyes-Okafor"
  ]
}
```

`server/names/uce_family.json`:

```json
{
  "schema": 1,
  "tags": { "type": "character", "part": "family", "faction": "uce" },
  "entries": [
    "Voss", "Castellan", "Okonjo", "Balakrishnan", "Ferreira", "Nakamura",
    "Aldana", "Strand",
    { "name": "Montclair", "tags": { "wealth": "high" } },
    { "name": "Aurelian-Hale", "tags": { "wealth": "high" } }
  ]
}
```

`server/names/freehold_family.json`:

```json
{
  "schema": 1,
  "tags": { "type": "character", "part": "family", "faction": "freehold" },
  "entries": [
    "Calder", "Stroud", "Okoro", "Brandt", "Iyer", "Maddox", "Soto",
    "Varga", "Onishi", "Reyes-Calder"
  ]
}
```

`server/names/company_family.json`:

```json
{
  "schema": 1,
  "tags": { "type": "character", "part": "family", "faction": "company" },
  "entries": [
    "Pemberton", "Chalmers", "Iyengar", "Whitcombe", "Faruqi", "Marsh",
    "Vidal", "Standish", "Okoye", "Grantham"
  ]
}
```

`server/names/grafter_given.json`:

```json
{
  "schema": 1,
  "tags": { "type": "character", "part": "given", "race": "grafter" },
  "entries": [
    "Sable", "Vex", "Arc", "Nadir", "Ash", "Cade", "Onyx", "Ren", "Lux",
    "Vela", "Corin", "Sol"
  ]
}
```

`server/names/grafter_family.json`:

```json
{
  "schema": 1,
  "tags": { "type": "character", "part": "family", "race": "grafter" },
  "entries": [
    "Farside", "Hollow", "Ballast", "Kessler", "Umbra", "Drift",
    "Perigee", "Ullage", "Lagrange", "Spindle"
  ]
}
```

`server/names/selkie_given.json`:

```json
{
  "schema": 1,
  "tags": { "type": "character", "part": "given", "race": "selkie" },
  "entries": [
    "Maren", "Nerith", "Talik", "Sedna", "Ione", "Kaia", "Yara", "Ondu",
    "Liris", "Pelin"
  ]
}
```

`server/names/senti_designations.json`:

```json
{
  "schema": 1,
  "tags": { "type": "character", "part": "full", "race": "senti" },
  "entries": [
    "IMRI", "CANTOR", "AUGUR", "SOLACE", "VERSE", "TALLY", "ORISON",
    "CIPHER", "LATTICE", "HALCYON"
  ]
}
```

`server/names/ship_names.json`:

```json
{
  "schema": 1,
  "tags": { "type": "ship", "part": "full" },
  "entries": [
    "Borrowed Light", "Long Answer", "Second Sunrise", "Quiet Ledger",
    "Distant Cousin", "Kindly Provision", "Weathered Eye", "Old Debt Paid",
    { "name": "Cormorant's Debt", "tags": { "role": "packet" } },
    { "name": "Swift Reply", "tags": { "role": "packet" } },
    { "name": "Overdue Notice", "tags": { "role": "packet" } },
    { "name": "Blunt Instrument", "tags": { "role": "gunship" } },
    { "name": "Measured Response", "tags": { "role": "gunship" } },
    { "name": "Gilded Hour", "tags": { "role": "liner" } },
    { "name": "Perpetual Holiday", "tags": { "role": "liner" } },
    { "name": "Patient Ox", "tags": { "role": "hauler" } },
    { "name": "Deep Keel", "tags": { "role": "hauler" } },
    { "name": "Stubborn Article", "tags": { "role": "tug" } },
    { "name": "Private Weather", "tags": { "role": "yacht" } }
  ]
}
```

`server/names/ship_patterns.json`:

```json
{
  "schema": 1,
  "tags": { "type": "ship", "part": "pattern" },
  "entries": ["${full}"]
}
```

- [ ] **Step 5: Run test to verify it passes**

Run the global test command.
Expected: PASS — `178 passed, no failures` (the 177 baseline + `all_names_files_match_schema_test`).

- [ ] **Step 6: Commit**

```powershell
git add server/schemas/names.schema.json server/names server/test/names_schema_test.gleam
git commit -m "feat(names): names.schema.json, base name pools, schema validation test"
```

---

### Task 2: `names.gleam` — types, file parsing, pool loading

**Files:**
- Create: `server/src/dh_server/names.gleam`
- Test: `server/test/names_test.gleam`

**Interfaces:**
- Consumes: `server/names/*.json` from Task 1.
- Produces (used by Tasks 3, 4, 7):
  - `pub type Tags { Tags(type_: String, part: String, race: Option(String), faction: Option(String), wealth: Option(String), gender: Option(String), role: Option(String), manufacturer: Option(String)) }`
  - `pub type Entry { Entry(name: String, tags: Tags) }`
  - `pub fn parse_names_file(text: String) -> Result(List(Entry), String)`
  - `pub fn load(dir: String) -> Result(List(Entry), String)`
  - `pub const races / factions / wealths / genders / ship_roles / manufacturers: List(String)`

- [ ] **Step 1: Write the failing tests**

Create `server/test/names_test.gleam`:

```gleam
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run the global test command.
Expected: COMPILE ERROR — module `dh_server/names` does not exist.

- [ ] **Step 3: Write the module**

Create `server/src/dh_server/names.gleam`:

```gleam
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run the global test command.
Expected: PASS — `181 passed, no failures`.

- [ ] **Step 5: Commit**

```powershell
git add server/src/dh_server/names.gleam server/test/names_test.gleam
git commit -m "feat(names): typed pool loading and cross-file merge"
```

---

### Task 3: Constraint AST as a generator — parsing, evaluation, enumeration

**Files:**
- Modify: `server/src/dh_server/names.gleam` (append)
- Test: `server/test/names_test.gleam` (append)

**Interfaces:**
- Consumes: Task 2's types and constants.
- Produces (used by Tasks 4 and 7):
  - `pub type Constraint { Any(List(Constraint)) All(List(Constraint)) Not(Constraint) AttrIs(axis: String, value: String) }`
  - `pub type CharacterAttrs { CharacterAttrs(race: String, faction: String, wealth: String, gender: String) }`
  - `pub type ShipAttrs { ShipAttrs(role: String, faction: String, manufacturer: String) }`
  - `pub fn parse_constraint(dyn: Dynamic, resolve: fn(String) -> Result(String, String)) -> Result(Constraint, String)` — `resolve` maps a `${slot}` name to a literal id; leaf keys map `race_is`→axis `race`, `faction_is`→`faction`, `wealth_is`→`wealth`, `gender_is`→`gender`, `role_is`→`role`, `manufacturer_is`→`manufacturer`; any other key is an error ("not legal in generation context").
  - `pub fn satisfying_character_attrs(constraint: Option(Constraint)) -> List(CharacterAttrs)`
  - `pub fn satisfying_ship_attrs(constraint: Option(Constraint)) -> List(ShipAttrs)`

- [ ] **Step 1: Write the failing tests**

Append to `server/test/names_test.gleam` (extend the imports at the top of the file to):

```gleam
import dh_server/names
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
```

Then append:

```gleam
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
  list.each(modest, fn(a) { assert a.wealth != "high" })

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
  list.each(attrs, fn(a) { assert a.role == "packet" })
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run the global test command.
Expected: COMPILE ERROR — `names.Any`, `names.AttrIs`, `satisfying_character_attrs` etc. undefined.

- [ ] **Step 3: Implement**

Append to `server/src/dh_server/names.gleam` (add `import gleam/dict` and `import gleam/dynamic.{type Dynamic}` to the module's imports):

```gleam
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run the global test command.
Expected: PASS — `185 passed, no failures`.

- [ ] **Step 5: Commit**

```powershell
git add server/src/dh_server/names.gleam server/test/names_test.gleam
git commit -m "feat(names): constraint AST as generator over the attribute domain"
```

---

### Task 4: Deterministic generation and rendering

**Files:**
- Modify: `server/src/dh_server/names.gleam` (append)
- Test: `server/test/names_test.gleam` (append)

**Interfaces:**
- Consumes: Tasks 2–3.
- Produces (used by Task 7 and eventually the engine):
  - `pub type Person { Person(race: String, faction: String, wealth: String, gender: String, effective_gender: String, full: String, given: Option(String), family: Option(String), title: String) }`
  - `pub type Ship { Ship(role: String, faction: String, manufacturer: String, name: String) }`
  - `pub fn generate_person(constraint: Option(Constraint), entries: List(Entry), seed: String) -> Result(Person, String)`
  - `pub fn generate_ship(constraint: Option(Constraint), entries: List(Entry), seed: String) -> Result(Ship, String)`
  - `pub fn form(person: Person, key: String) -> Result(String, Nil)` — keys: `given`, `family`, `short`, `title`, `ey`, `em`, `eir`, `eirs`, `emself`, `Ey`, `Em`, `Eir`, `Eirs`, `Emself`
  - `pub fn ship_form(ship: Ship, key: String) -> Result(String, Nil)` — key: `role`
  - `pub fn role_display(role: String) -> String`
  - `pub fn pattern_parts(pattern: String) -> List(String)`
  - `pub fn character_pool(entries: List(Entry), a: CharacterAttrs, part: String, effective_gender: String) -> List(String)`
  - `pub fn ship_pool(entries: List(Entry), a: ShipAttrs, part: String) -> List(String)`
  - `pub fn matching_patterns_for_character(entries: List(Entry), a: CharacterAttrs) -> List(String)`
  - `pub fn matching_patterns_for_ship(entries: List(Entry), a: ShipAttrs) -> List(String)`
  - `pub fn possible_effective_genders(a: CharacterAttrs) -> List(String)`

- [ ] **Step 1: Write the failing tests**

Append to `server/test/names_test.gleam` (add `import gleam/string` to its imports):

```gleam
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run the global test command.
Expected: COMPILE ERROR — `generate_person` etc. undefined.

- [ ] **Step 3: Implement**

Append to `server/src/dh_server/names.gleam` (add `import gleam/bit_array`, `import gleam/crypto`, `import gleam/int` to the module's imports):

```gleam
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run the global test command.
Expected: PASS — `192 passed, no failures`.

- [ ] **Step 5: Commit**

```powershell
git add server/src/dh_server/names.gleam server/test/names_test.gleam
git commit -m "feat(names): deterministic principal generation and form rendering"
```

---

### Task 5: Quest schema v-next + quest test updates

**Files:**
- Modify: `server/schemas/quest.schema.json`
- Modify: `server/test/quest_schema_test.gleam` (full replacement below)

**Interfaces:**
- Consumes: nothing new (pure data contract).
- Produces: slot kinds `character`/`ship`; constraint leaves `race_is`, `wealth_is`, `gender_is`, `role_is`; `character_dead` (renamed from `npc_dead`); item property `principal`. Tests enforce: dotted interpolation forms, generation-vocabulary placement, principal references.

- [ ] **Step 1: Update the failing tests first**

Replace the entire contents of `server/test/quest_schema_test.gleam` with:

```gleam
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

const schema_path = "schemas/quest.schema.json"

const quests_dir = "quests"

/// Dotted interpolation forms legal on character slots (${x.<form>}).
const character_forms = [
  "given", "family", "short", "title", "ey", "em", "eir", "eirs", "emself",
  "Ey", "Em", "Eir", "Eirs", "Emself",
]

const ship_forms = ["role"]

/// Leaves that only mean something when generating a principal.
const generation_leaves = ["race_is", "wealth_is", "gender_is", "role_is"]

const character_legal = [
  "any", "all", "not", "race_is", "faction_is", "wealth_is", "gender_is",
]

const ship_legal = [
  "any", "all", "not", "role_is", "faction_is", "manufacturer_is",
]

fn read_json(path: String) -> Dynamic {
  let assert Ok(text) = simplifile.read(path)
  parse_json(text)
}

fn quest_files() -> List(String) {
  let assert Ok(entries) = simplifile.read_directory(quests_dir)
  entries
  |> list.filter(string.ends_with(_, ".json"))
  |> list.sort(string.compare)
}

fn parse_json(text: String) -> Dynamic {
  let assert Ok(value) = json.parse(text, decode.dynamic)
  value
}

pub fn jesse_wiring_test() {
  let schema = parse_json("{\"type\": \"object\"}")
  assert validate_with_schema(schema, parse_json("{}")) == Ok(Nil)
  assert validate_with_schema(schema, parse_json("[]")) != Ok(Nil)
}

pub fn all_quests_match_schema_test() {
  let schema = read_json(schema_path)
  let files = quest_files()
  // Guards against a typo'd glob silently validating nothing.
  assert files != []
  list.each(files, fn(file) {
    let value = read_json(quests_dir <> "/" <> file)
    case validate_with_schema(schema, value) {
      Ok(Nil) -> Nil
      Error(message) -> panic as { file <> ": " <> message }
    }
  })
}

type ItemRef {
  ItemRef(id: String, principal: String)
}

type QuestRefs {
  QuestRefs(
    id: String,
    acquisition: String,
    trigger_targets: List(String),
    slot_kinds: dict.Dict(String, String),
    parent_refs: List(String),
    items: List(ItemRef),
  )
}

fn refs_decoder() -> decode.Decoder(QuestRefs) {
  let trigger = {
    use quest <- decode.field("quest", decode.string)
    decode.success(quest)
  }
  let slot = {
    use kind <- decode.optional_field("kind", "", decode.string)
    use from <- decode.optional_field("from", "", decode.string)
    decode.success(#(kind, from))
  }
  let item = {
    use id <- decode.field("id", decode.string)
    use principal <- decode.optional_field("principal", "", decode.string)
    decode.success(ItemRef(id:, principal:))
  }
  use id <- decode.field("id", decode.string)
  use acquisition <- decode.field("acquisition", decode.string)
  use slots <- decode.optional_field(
    "slots",
    dict.new(),
    decode.dict(decode.string, slot),
  )
  use items <- decode.optional_field("items", [], decode.list(item))
  use on_complete <- decode.optional_field("on_complete", [], decode.list(trigger))
  use on_failed <- decode.optional_field("on_failed", [], decode.list(trigger))
  use on_expired <- decode.optional_field("on_expired", [], decode.list(trigger))
  decode.success(QuestRefs(
    id:,
    acquisition:,
    trigger_targets: list.flatten([on_complete, on_failed, on_expired]),
    slot_kinds: dict.map_values(slots, fn(_, pair) { pair.0 }),
    parent_refs: dict.values(slots)
      |> list.map(fn(pair) { pair.1 })
      |> list.filter(string.starts_with(_, "parent.")),
    items:,
  ))
}

fn load_refs() -> List(QuestRefs) {
  list.map(quest_files(), fn(file) {
    let assert Ok(text) = simplifile.read(quests_dir <> "/" <> file)
    let assert Ok(refs) = json.parse(text, refs_decoder())
    // Filename coherence checked here so every test that loads refs enforces it.
    assert refs.id <> ".json" == file
    refs
  })
}

pub fn quest_ids_match_filenames_test() {
  // The assert lives in load_refs; calling it is the test.
  let _ = load_refs()
  Nil
}

pub fn quest_triggers_are_coherent_test() {
  let quests = load_refs()
  let ids = list.map(quests, fn(refs) { refs.id })
  let targets = list.flat_map(quests, fn(refs) { refs.trigger_targets })
  // Every trigger target must exist in the folder.
  list.each(targets, fn(target) { assert list.contains(ids, target) })
  list.each(quests, fn(refs) {
    // acquisition "triggered" if and only if some quest triggers it.
    let referenced = list.contains(targets, refs.id)
    assert referenced == { refs.acquisition == "triggered" }
    // parent.* bindings only live in slot "from" fields, and only make sense
    // in triggered quests.
    case refs.parent_refs {
      [] -> Nil
      _ -> {
        assert refs.acquisition == "triggered"
        Nil
      }
    }
  })
}

pub fn broker_quests_declare_offer_broker_test() {
  list.each(load_refs(), fn(refs) {
    // acquisition "broker" implies the reserved offer_broker slot exists —
    // it names the broker where the offer is posted.
    case refs.acquisition == "broker" {
      True -> {
        assert dict.has_key(refs.slot_kinds, "offer_broker")
        Nil
      }
      False -> Nil
    }
  })
}

pub fn parent_bindings_exist_in_all_triggering_parents_test() {
  let quests = load_refs()
  list.each(quests, fn(child) {
    let parents =
      list.filter(quests, fn(p) { list.contains(p.trigger_targets, child.id) })
    list.each(child.parent_refs, fn(ref) {
      // ref is "parent.<slot>" or "parent.item.<itemId>". A child can be
      // triggered by any of its parents, so EVERY parent must satisfy it.
      let assert Ok(#("parent", rest)) = string.split_once(ref, ".")
      list.each(parents, fn(parent) {
        case string.split_once(rest, ".") {
          Ok(#("item", item_id)) ->
            case
              list.contains(list.map(parent.items, fn(i) { i.id }), item_id)
            {
              True -> Nil
              False ->
                panic as {
                  child.id <> ": " <> ref <> " is not an item of parent " <> parent.id
                }
            }
          _ ->
            case dict.has_key(parent.slot_kinds, rest) {
              True -> Nil
              False ->
                panic as {
                  child.id <> ": " <> ref <> " is not a slot of parent " <> parent.id
                }
            }
        }
      })
    })
  })
}

pub fn quest_interpolations_resolve_test() {
  list.each(quest_files(), fn(file) {
    let assert Ok(text) = simplifile.read(quests_dir <> "/" <> file)
    let assert Ok(refs) = json.parse(text, refs_decoder())
    // Every ${token} anywhere in the file must name a declared slot, and a
    // dotted ${slot.form} must use a legal form for that slot's kind — a
    // typo'd interpolation validates against the schema and would otherwise
    // only surface engine-side.
    string.split(text, "${")
    |> list.drop(1)
    |> list.each(fn(chunk) {
      case string.split_once(chunk, "}") {
        Error(Nil) -> panic as { file <> ": unterminated ${ interpolation" }
        Ok(#(token, _)) -> {
          let #(slot, form) = case string.split_once(token, ".") {
            Ok(pair) -> pair
            Error(Nil) -> #(token, "")
          }
          let kind = case dict.get(refs.slot_kinds, slot) {
            Ok(kind) -> kind
            Error(Nil) ->
              panic as {
                file <> ": ${" <> token <> "} does not name a declared slot"
              }
          }
          case form, kind {
            "", _ -> Nil
            f, "character" ->
              case list.contains(character_forms, f) {
                True -> Nil
                False ->
                  panic as {
                    file <> ": unknown character form ${" <> token <> "}"
                  }
              }
            f, "ship" ->
              case list.contains(ship_forms, f) {
                True -> Nil
                False ->
                  panic as { file <> ": unknown ship form ${" <> token <> "}" }
              }
            _, _ ->
              panic as {
                file <> ": dotted form ${" <> token <> "} on a non-generated slot"
              }
          }
        }
      }
    })
  })
}

pub fn item_principals_name_character_slots_test() {
  list.each(load_refs(), fn(refs) {
    list.each(refs.items, fn(item) {
      case item.principal {
        "" -> Nil
        principal ->
          case dict.get(refs.slot_kinds, principal) {
            Ok("character") -> Nil
            _ ->
              panic as {
                refs.id
                <> ": item "
                <> item.id
                <> " principal "
                <> principal
                <> " is not a character slot"
              }
          }
      }
    })
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

fn collect_constraint_keys(dyn: Dynamic) -> List(String) {
  case decode.run(dyn, decode.dict(decode.string, decode.dynamic)) {
    Error(_) -> []
    Ok(fields) ->
      dict.to_list(fields)
      |> list.flat_map(fn(field) {
        case field.0 {
          "any" | "all" ->
            case decode.run(field.1, decode.list(decode.dynamic)) {
              Ok(items) -> [
                field.0,
                ..list.flat_map(items, collect_constraint_keys)
              ]
              Error(_) -> [field.0]
            }
          "not" -> [field.0, ..collect_constraint_keys(field.1)]
          key -> [key]
        }
      })
  }
}

pub fn generation_constraint_vocabulary_test() {
  // Generation leaves only on generated slots; generated slots only use
  // generation-legal vocabulary. Same spirit as the from-only-in-triggered
  // rule.
  list.each(quest_files(), fn(file) {
    quest_slot_infos(file)
    |> dict.to_list
    |> list.each(fn(pair) {
      let #(name, info) = pair
      let keys = case info.constraints {
        Some(dyn) -> collect_constraint_keys(dyn)
        None -> []
      }
      case info.kind {
        "character" | "ship" -> {
          let legal = case info.kind {
            "character" -> character_legal
            _ -> ship_legal
          }
          list.each(keys, fn(key) {
            case list.contains(legal, key) {
              True -> Nil
              False ->
                panic as {
                  file
                  <> " slot "
                  <> name
                  <> ": key "
                  <> key
                  <> " is not legal on a generated slot"
                }
            }
          })
        }
        _ ->
          list.each(keys, fn(key) {
            case list.contains(generation_leaves, key) {
              True ->
                panic as {
                  file
                  <> " slot "
                  <> name
                  <> ": generation leaf "
                  <> key
                  <> " on a bind slot"
                }
              False -> Nil
            }
          })
      }
    })
  })
}
```

- [ ] **Step 2: Run tests to verify the suite still passes (new tests are vacuous so far)**

Run the global test command.
Expected: PASS — no quest yet uses character/ship slots, dotted forms, or principals, so the new checks pass trivially. This step confirms the refactored decoders didn't break existing coherence tests.

- [ ] **Step 3: Update the quest schema**

Apply these five exact edits to `server/schemas/quest.schema.json`.

Edit 1 — slot kinds. Replace:

```json
            "kind": { "enum": ["station", "broker", "faction", "commodity", "npc"] },
```

with:

```json
            "kind": {
              "enum": ["station", "broker", "faction", "commodity", "character", "ship"],
              "description": "station/broker/faction/commodity slots BIND existing world entities. character/ship slots are GENERATED: the resolver conjures a principal satisfying the constraints, deterministically from the quest-instance seed, with names drawn from the tag-matched pools in server/names/ (authority: schemas/names.schema.json). Generated slots never veto a quest's existence; build-time coverage tests guarantee non-empty pools."
            },
```

Edit 2 — generation leaves. Replace:

```json
        "manufacturer_is": { "$ref": "#/definitions/ref_string" },
```

with:

```json
        "manufacturer_is": { "$ref": "#/definitions/ref_string" },

        "race_is": {
          "$ref": "#/definitions/ref_string",
          "description": "Generation leaf (character slots): human | selkie | grafter | senti."
        },
        "wealth_is": {
          "$ref": "#/definitions/ref_string",
          "description": "Generation leaf (character slots): low | mid | high."
        },
        "gender_is": {
          "$ref": "#/definitions/ref_string",
          "description": "Generation leaf (character slots): female | male | neutral. Unpinned, the resolver rolls 47.5/47.5/5."
        },
        "role_is": {
          "$ref": "#/definitions/ref_string",
          "description": "Generation leaf (ship slots): packet | hauler | liner | gunship | tug | yacht (authority: names.schema.json; shared with future hull auto-categorization)."
        },
```

Edit 3 — rename the death predicate. Replace:

```json
        "npc_dead": { "$ref": "#/definitions/ref_string" },
```

with:

```json
        "character_dead": { "$ref": "#/definitions/ref_string" },
```

Edit 4 — item principal link. In `definitions.item.properties`, replace:

```json
        "name": {
          "type": "string",
          "minLength": 1,
          "description": "Display name. Absent = the resolver generates one from the seed."
        },
```

with:

```json
        "name": {
          "type": "string",
          "minLength": 1,
          "description": "Display name; ${slot} interpolations substitute as everywhere. Absent = the principal's full display name when principal is set, else the resolver generates one from the seed."
        },
        "principal": {
          "type": "string",
          "pattern": "^[a-z0-9_]+$",
          "description": "Name of a character slot this item embodies — the berth passenger IS that character (test-enforced to reference a character slot)."
        },
```

Edit 5 — top-level description. Replace the sentence (inside the schema's `description` string):

```
TODO(name-pools): hardcoded names in flavor text (e.g. 'Jaya Okafor') should become substitutable variables drawn from constrained name pools — constrained by faction affiliation, race, and possibly more — sharing machinery with item name generation ('name omitted = resolver generates from seed').
```

with:

```
Name pools: character and ship slots are generated principals whose names come from the server/names/ pools; character slots expose dotted interpolation forms ${x.given}/${x.family}/${x.short}/${x.title} and pronouns ${x.ey}/${x.em}/${x.eir}/${x.eirs}/${x.emself} (capitalized variants Ey/Em/Eir/Eirs/Emself; authored in ey/em/eir, rendered she/he for gendered-culture characters), ship slots expose ${x.role} — see docs/superpowers/specs/2026-07-17-quest-principals-and-name-pools-design.md.
```

- [ ] **Step 4: Run tests to verify everything still passes**

Run the global test command.
Expected: PASS — schema changes are additive; existing quests still validate.

- [ ] **Step 5: Commit**

```powershell
git add server/schemas/quest.schema.json server/test/quest_schema_test.gleam
git commit -m "feat(quests): character/ship generated slots, generation leaves, item principals"
```

---

### Task 6: Migrate the three named-principal quests + add the ship quest

**Files:**
- Modify: `server/quests/keep_the_wake.json` (full replacement)
- Modify: `server/quests/void_abolished.json` (full replacement)
- Modify: `server/quests/a_body_that_can_die.json` (full replacement)
- Create: `server/quests/overdue_packet.json`

**Interfaces:**
- Consumes: Task 5's schema vocabulary. No code interfaces.
- Produces: zero hardcoded principal names in stock quests (end condition); the coverage targets Task 7 verifies.

- [ ] **Step 1: Replace `server/quests/keep_the_wake.json`**

```json
{
  "schema": 1,
  "id": "keep_the_wake",
  "name": "Keep the Wake",
  "flavor": "${okafor} kept the Wake for fifty-one years of hauling and never once made it home. ${okafor.Eir} congregation asks a small thing of whoever is already heading that way: carry ${okafor.em} the rest of it. There is no hurry. ${okafor.Ey} would not want the burn wasted. But mind the still days — ${okafor.ey} kept them all ${okafor.eir} life, and ${okafor.ey} will keep them now.",
  "acquisition": "broker",
  "slots": {
    "wake": { "kind": "faction", "constraints": { "id": "wake" } },
    "okafor": { "kind": "character", "constraints": { "faction_is": "${wake}" } },
    "cathedral": { "kind": "station", "constraints": { "id": "cathedral_of_the_wake" } },
    "offer_broker": {
      "kind": "broker",
      "constraints": { "faction_is": "${wake}", "not": { "station_is": "${cathedral}" } }
    },
    "congregation": {
      "kind": "broker",
      "constraints": { "faction_is": "${wake}", "station_is": "${cathedral}" }
    }
  },
  "eligibility": { "rep_at_least": { "target": "${wake}", "value": 0 } },
  "conduct": { "no_flight_on_holy_days": { "while_aboard": "remains" } },
  "completion": {
    "docked_at": "${cathedral}",
    "deliver_item": { "item": "remains", "to": "${congregation}" }
  },
  "items": [
    { "id": "remains", "name": "Sealed Remains — ${okafor.short}", "space": "hold", "units": 1 }
  ],
  "rewards": {
    "credits": 150,
    "rep": [{ "target": "${wake}", "delta": 25 }]
  }
}
```

(Race deliberately unpinned: a Selkie, Senti, or grafter keeper of the Wake is a legitimate — and interesting — roll. Pronoun prose is authored in ey/em/eir and renders she/he for gendered rolls; note "kept" agrees with every pronoun because the canon neutral is grammatically singular.)

- [ ] **Step 2: Replace `server/quests/void_abolished.json`**

```json
{
  "schema": 1,
  "id": "void_abolished",
  "name": "The Void, Abolished",
  "flavor": "${voss.title} ${voss} has crossed the system eleven times and felt it zero, and ${voss.ey} intends to keep the streak. One berth, one passenger, one rule: the void does not touch ${voss.em}. An Aratori hull holds a glassy one gee from undock to touchdown. Yours will simply have to pretend to be one, the whole way, including the parts where that costs you.",
  "acquisition": "broker",
  "slots": {
    "uce": { "kind": "faction", "constraints": { "id": "uce" } },
    "voss": {
      "kind": "character",
      "constraints": { "race_is": "human", "faction_is": "${uce}", "wealth_is": "high" }
    },
    "dest": {
      "kind": "station",
      "constraints": { "any": [{ "built_by": "apogee_grand" }, { "settlement_class": "hub" }] }
    },
    "offer_broker": {
      "kind": "broker",
      "constraints": { "faction_is": "${uce}", "not": { "station_is": "${dest}" } }
    }
  },
  "eligibility": { "min_passenger_berths": 1 },
  "conduct": {
    "max_burn_g": {
      "value": 1.0,
      "while_aboard": "vip",
      "on_violation": { "reward_multiplier": 0.5 }
    }
  },
  "completion": { "docked_at": "${dest}", "deliver_item": { "item": "vip" } },
  "deadline_s": 2700,
  "items": [
    { "id": "vip", "principal": "voss", "name": "${voss.title} ${voss}", "space": "berth", "units": 1 }
  ],
  "rewards": {
    "credits": 3200,
    "rep": [
      { "target": "${uce}", "delta": 10 },
      { "target": "aratori", "delta": 10 }
    ]
  }
}
```

(Gender left unpinned per the spec: UCE is a gendered-address culture, so the typical roll reads Mr./Ms.; the 5% neutral roll yields an Mx. — present in core life without reading as the norm.)

- [ ] **Step 3: Replace `server/quests/a_body_that_can_die.json`**

```json
{
  "schema": 1,
  "id": "a_body_that_can_die",
  "name": "A Body That Can Die",
  "flavor": "The message reaches you third-hand, the way these things do: a mind needs moving. ${imri} is a person in every court that matters and cargo on every manifest that counts, and out on the border there is a notary who owes somebody a favor and can paper a captaincy — if the substrate arrives before the favor expires, and before anyone official opens the crate to check that it is what it declares. ${imri}, for ${imri.eir} part, is very good company, and would prefer not to be inspected. There is no backup. There is never a backup.",
  "acquisition": "rumor",
  "slots": {
    "imri": { "kind": "character", "constraints": { "race_is": "senti" } },
    "notary_port": { "kind": "station", "constraints": { "faction_is": "freehold" } },
    "notary": {
      "kind": "broker",
      "constraints": { "faction_is": "freehold", "station_is": "${notary_port}" }
    }
  },
  "eligibility": { "min_passenger_berths": 1 },
  "conduct": { "no_inspection": { "while_aboard": "senti" } },
  "completion": {
    "docked_at": "${notary_port}",
    "deliver_item": { "item": "senti", "to": "${notary}" }
  },
  "deadline_s": 3600,
  "items": [
    {
      "id": "senti",
      "principal": "imri",
      "name": "${imri} — Registered Instrument, Itinerant Mind",
      "space": "berth",
      "units": 1
    }
  ],
  "rewards": {
    "credits": 800,
    "rep": [
      { "target": "bureau", "delta": 20 },
      { "target": "company", "delta": -10 }
    ],
    "meta_unlock": "senti_start"
  }
}
```

- [ ] **Step 4: Create `server/quests/overdue_packet.json`**

```json
{
  "schema": 1,
  "id": "overdue_packet",
  "name": "${lost}'s Run",
  "flavor": "The ${lost}, ${lost.role}, was due at ${dest} three days ago and has not been seen since the outer marker. Somebody else gets to find out what happened to her; what matters this morning is that there is a hold's worth of ${cargo} on a standing contract that does not care whose ship it rides. Take the run, collect the fee, and try not to dwell on the manifest line that says the last crew did exactly this.",
  "acquisition": "broker",
  "slots": {
    "patron": { "kind": "faction", "constraints": { "id": "freehold" } },
    "cargo": { "kind": "commodity" },
    "dest": {
      "kind": "station",
      "constraints": { "faction_is": "${patron}", "imports": "${cargo}" }
    },
    "lost": { "kind": "ship", "constraints": { "role_is": "packet" } },
    "recipient": {
      "kind": "broker",
      "constraints": { "faction_is": "${patron}", "station_is": "${dest}" }
    },
    "offer_broker": {
      "kind": "broker",
      "constraints": { "faction_is": "${patron}", "not": { "station_is": "${dest}" } }
    }
  },
  "eligibility": { "any": [{ "min_cargo_units": 30 }, { "min_container_slots": 2 }] },
  "completion": {
    "docked_at": "${dest}",
    "deliver_commodity": { "commodity": "${cargo}", "units": 30, "to": "${recipient}" }
  },
  "deadline_s": 2400,
  "rewards": {
    "credits": 1100,
    "rep": [{ "target": "${patron}", "delta": 12 }]
  }
}
```

- [ ] **Step 5: Run tests to verify everything passes**

Run the global test command.
Expected: PASS — schema validation, interpolation-form checks, principal checks, and generation-vocabulary checks all cover the new content. If `quest_interpolations_resolve_test` panics, a form name or slot reference in the JSON above is typo'd — fix the quest file, not the test.

- [ ] **Step 6: Commit**

```powershell
git add server/quests/keep_the_wake.json server/quests/void_abolished.json server/quests/a_body_that_can_die.json server/quests/overdue_packet.json
git commit -m "feat(quests): migrate named principals to generated slots; add overdue_packet ship quest"
```

---

### Task 7: Build-time coverage — every principal in every quest can be dressed

**Files:**
- Modify: `server/test/names_schema_test.gleam` (append)

**Interfaces:**
- Consumes: `names.load`, `names.parse_constraint`, `names.satisfying_character_attrs`, `names.satisfying_ship_attrs`, `names.matching_patterns_for_character`, `names.matching_patterns_for_ship`, `names.pattern_parts`, `names.character_pool`, `names.ship_pool`, `names.possible_effective_genders`, `names.factions`, `names.manufacturers` (Tasks 2–4); quest files (Task 6).
- Produces: CI-time guarantee that no principal declaration can hit an empty pool at runtime, and that pool tags stay within canonical vocabularies.

- [ ] **Step 1: Write the tests (failing only if coverage genuinely has holes)**

Append to `server/test/names_schema_test.gleam` (extend the file's imports to include `import dh_server/names`, `import gleam/dict`, `import gleam/option.{type Option, None, Some}`):

```gleam
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
```

- [ ] **Step 2: Run tests**

Run the global test command.
Expected: PASS. If `quest_principals_are_coverable_test` panics, the message names the quest, slot, attribute assignment, and part with an empty pool — fix by adding pool entries or patterns for that combination in `server/names/` (never by weakening the test). Known-good by construction: every race has a pattern; given/family pools exist for human (generic), grafter (race-tagged), selkie (given-only single-name pattern), senti (full designations); wake/uce/freehold/company have family pools but generic race-tagged family pools cover all factions anyway; titles cover all three genders.

- [ ] **Step 3: Force one red run to prove the coverage test bites**

Temporarily edit `server/names/senti_designations.json`, changing `"race": "senti"` to `"race": "grafter"` in its `tags`. Run the global test command.
Expected: FAIL — `quest_principals_are_coverable_test` panics with `a_body_that_can_die.json slot imri: empty pool for part full …` (or `no pattern matches`). Revert the edit (`git checkout -- server/names/senti_designations.json`), re-run, confirm PASS. This guards against the coverage test being vacuously green.

- [ ] **Step 4: Commit**

```powershell
git add server/test/names_schema_test.gleam
git commit -m "test(names): build-time coverage of quest principals against pools"
```

---

### Task 8: Full-suite verification and docs touch-up

**Files:**
- Modify: `docs/superpowers/specs/2026-07-17-quest-principals-and-name-pools-design.md` (status line only)

**Interfaces:** none.

- [ ] **Step 1: Run the complete suite one final time**

Run the global test command.
Expected: PASS with 0 failures; count should be 195+ (177 baseline + ~18 new). Also run `gleam build` inside `server/` (same PATH prefix) and confirm no warnings introduced by the new module.

- [ ] **Step 2: Update the spec status**

In the spec file, change `Status: approved pending review` to `Status: implemented (see docs/superpowers/plans/2026-07-17-quest-principals-and-name-pools.md)`.

- [ ] **Step 3: Commit**

```powershell
git add docs/superpowers/specs/2026-07-17-quest-principals-and-name-pools-design.md
git commit -m "docs(design): mark quest principals spec implemented"
```

---

## Plan Self-Review Notes (already applied)

- Spec §1 (files/tags/matching/patterns/titles) → Tasks 1–2. Spec §2 (slot kinds, AST-as-generator, forms, principal link, `character_dead`, TODO removal) → Tasks 3–5. Spec §3 (pronouns/address/lore) → Task 4 code + Task 6 prose. Spec §4 (migrations + ship quest + pools) → Tasks 1, 6. Spec §5 (module, determinism, tests, coverage) → Tasks 2–4, 7.
- Uniqueness/collision re-roll is explicitly deferred to engine integration (spec §5) — no task, by design.
- Faction validation deviates from "against the world" to "against `names.gleam` constants" — the world carries no factions yet; the spec was amended 2026-07-17 to match.
- Test-count expectations are approximate on purpose; the invariant that matters is `no failures`.
