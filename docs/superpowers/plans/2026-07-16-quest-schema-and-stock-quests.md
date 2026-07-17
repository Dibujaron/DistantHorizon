# Quest Schema and Stock Quests Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create `server/schemas/quest.schema.json` (JSON Schema for quest templates), ten stock quest files in `server/quests/` (six quests, two of them chains), and a Gleam test suite that validates every quest file against the schema plus cross-file coherence checks.

**Architecture:** Data-only deliverable per `docs/superpowers/specs/2026-07-16-quests-design.md` — no quest engine. Quest files are seed-agnostic templates: named slots with constraints, a mongo-style constraint AST, eligibility/conduct/completion condition slots, trigger chains, inline quest items, rep-centric rewards. Validation rides the Erlang `jesse` JSON Schema validator (draft-06) via a tiny FFI shim, driven from gleeunit tests.

**Tech Stack:** Gleam 1.17 / OTP (server), gleeunit, simplifile, gleam_json, `jesse` (Erlang hex package, dev dependency), JSON Schema draft-06.

## Global Constraints

- Spec of record: `docs/superpowers/specs/2026-07-16-quests-design.md`. Two approved deviations, both anticipated by the spec: (a) validator is **jesse**, schema `$schema` pinned to **draft-06** (`http://json-schema.org/draft-06/schema#`); (b) items gain optional `pickup_at` (the spec's "or as authored" injection point) and `deliver_item`/`deliver_commodity` are objects with an optional `to` broker-slot ref.
- Every quest file: `"schema": 1`; `id` field equals filename minus `.json`; ids match `^[a-z0-9_]+$`.
- One quest per file; chains share a filename prefix.
- Work only in: `server/schemas/`, `server/quests/`, `server/test/quest_schema_test.gleam`, `server/test/quest_schema_ffi.erl`, `server/gleam.toml`, `server/manifest.toml`.
- All commands run from the `server/` directory. If `gleam` is not found in a fresh shell, prefix: `$env:PATH = "$env:USERPROFILE\scoop\shims;$env:PATH";`
- `gleam test` runs the FULL existing suite; all pre-existing tests must stay green.
- Execution isolation: create a worktree from `main` (superpowers:using-git-worktrees) on branch `quest-schema`; submit as a PR (user reviews PRs, never commit to main). The current `m3.1-stitched-interiors` working tree has unrelated in-flight changes — do not build there.

---

### Task 1: jesse dependency + FFI shim + wiring test

**Files:**
- Modify: `server/gleam.toml` (via `gleam add --dev`)
- Create: `server/test/quest_schema_ffi.erl`
- Create: `server/test/quest_schema_test.gleam`

**Interfaces:**
- Produces: `validate_with_schema(schema: Dynamic, value: Dynamic) -> Result(Nil, String)` (Gleam external, backed by `quest_schema_ffi:validate/2`). `Ok(Nil)` on valid; `Error(message)` with jesse's error rendered as a string on invalid. Later tasks call this from the same test module.

- [ ] **Step 1: Write the failing test module**

Create `server/test/quest_schema_test.gleam`:

```gleam
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json

@external(erlang, "quest_schema_ffi", "validate")
fn validate_with_schema(schema: Dynamic, value: Dynamic) -> Result(Nil, String)

fn parse_json(text: String) -> Dynamic {
  let assert Ok(value) = json.parse(text, decode.dynamic)
  value
}

pub fn jesse_wiring_test() {
  let schema = parse_json("{\"type\": \"object\"}")
  assert validate_with_schema(schema, parse_json("{}")) == Ok(Nil)
  assert validate_with_schema(schema, parse_json("[]")) != Ok(Nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run (from `server/`): `gleam test`
Expected: FAIL — the build succeeds but `jesse_wiring_test` errors at runtime with `undef` / module `quest_schema_ffi` not found (or the FFI module fails to find `jesse` if Step 3 is done first). Either failure mode is the red state.

- [ ] **Step 3: Add jesse as a dev dependency**

Run (from `server/`): `gleam add --dev jesse`
Expected: `gleam.toml` gains `jesse = ">= 1.8.2 and < 2.0.0"` (or the current 1.x) under `[dev_dependencies]`; `manifest.toml` updates. If the resolved version differs, keep what `gleam add` chose — any 1.8+ is fine.

- [ ] **Step 4: Write the FFI shim**

Create `server/test/quest_schema_ffi.erl`:

```erlang
-module(quest_schema_ffi).
-export([validate/2]).

%% Validates a decoded JSON value against a decoded JSON Schema using jesse.
%% Returns {ok, nil} | {error, Binary} to match Gleam's Result(Nil, String).
validate(Schema, Value) ->
    try jesse:validate_with_schema(Schema, Value) of
        {ok, _} -> {ok, nil};
        {error, Errors} ->
            {error, unicode:characters_to_binary(io_lib:format("~p", [Errors]))}
    catch
        Class:Reason ->
            {error, unicode:characters_to_binary(io_lib:format("~p:~p", [Class, Reason]))}
    end.
```

- [ ] **Step 5: Run test to verify it passes**

Run: `gleam test`
Expected: PASS — `jesse_wiring_test` green, all pre-existing tests green.

- [ ] **Step 6: Commit**

```powershell
git add gleam.toml manifest.toml test/quest_schema_ffi.erl test/quest_schema_test.gleam
git commit -m "test(quests): jesse JSON Schema validator wired via FFI"
```

---

### Task 2: quest.schema.json + first quest + folder validation test

**Files:**
- Create: `server/schemas/quest.schema.json`
- Create: `server/quests/keep_the_wake.json`
- Modify: `server/test/quest_schema_test.gleam`

**Interfaces:**
- Consumes: `validate_with_schema/2` from Task 1.
- Produces: `read_json(path: String) -> Dynamic` and `quest_files() -> List(String)` helpers; constants `schema_path = "schemas/quest.schema.json"`, `quests_dir = "quests"`. The schema file is the canonical quest format all later tasks author against.

- [ ] **Step 1: Extend the test module with the folder-validation test**

Add to `server/test/quest_schema_test.gleam` (new imports at top; helpers and test below the existing code):

```gleam
import gleam/list
import gleam/string
import simplifile
```

```gleam
const schema_path = "schemas/quest.schema.json"

const quests_dir = "quests"

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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `gleam test`
Expected: FAIL — `all_quests_match_schema_test` panics (schema file missing → `simplifile.read` assert fails).

- [ ] **Step 3: Write the JSON Schema**

Create `server/schemas/quest.schema.json` (this is the format's complete, self-describing definition):

```json
{
  "$schema": "http://json-schema.org/draft-06/schema#",
  "$id": "https://distanthorizon.dev/schemas/quest.schema.json",
  "title": "Distant Horizon quest template",
  "description": "A seed-agnostic quest template. Slots bind against the generated world at world-gen or trigger time; constraints share one AST vocabulary across slots, eligibility (checked at offer/accept), conduct (latched invariants while active), completion (turn-in check), and fail_when (author-listed failure conditions). See docs/superpowers/specs/2026-07-16-quests-design.md.",
  "type": "object",
  "required": ["schema", "id", "name", "flavor", "acquisition", "slots", "completion", "rewards"],
  "additionalProperties": false,
  "properties": {
    "schema": { "const": 1 },
    "id": {
      "type": "string",
      "pattern": "^[a-z0-9_]+$",
      "description": "Must equal the filename minus .json (test-enforced)."
    },
    "name": { "type": "string", "minLength": 1 },
    "flavor": { "type": "string", "minLength": 1 },
    "acquisition": {
      "enum": ["broker", "rumor", "triggered"],
      "description": "broker: offered at a faction broker console. rumor: ambient, no contract, no penalty for ignoring. triggered: only reachable via another quest's triggers."
    },
    "slots": {
      "type": "object",
      "description": "Named entities the quest needs from the generated world. ${slotName} interpolates a bound slot anywhere a constraint value appears. If a slot cannot bind, the quest does not exist this run.",
      "propertyNames": { "pattern": "^[a-z0-9_]+$" },
      "additionalProperties": { "$ref": "#/definitions/slot" }
    },
    "eligibility": {
      "$ref": "#/definitions/constraint",
      "description": "Snapshot check at offer/accept time (rep gates, ship fit, crew)."
    },
    "conduct": {
      "$ref": "#/definitions/constraint",
      "description": "Latched invariants monitored while the quest is active. A violation latches; default effect is quest failure unless the predicate carries on_violation."
    },
    "completion": {
      "$ref": "#/definitions/constraint",
      "description": "Turn-in check, evaluated at the moment of hand-over."
    },
    "fail_when": {
      "$ref": "#/definitions/constraint",
      "description": "Author-listed failure conditions. The engine additionally always enforces implicit fails: destination gone, quest item destroyed or sold, quest passenger dead."
    },
    "deadline_s": {
      "type": "integer",
      "minimum": 1,
      "description": "Seconds from acceptance. Absent = undated (the opportunity flavor)."
    },
    "items": {
      "type": "array",
      "items": { "$ref": "#/definitions/item" }
    },
    "rewards": { "$ref": "#/definitions/rewards" },
    "on_complete": { "type": "array", "items": { "$ref": "#/definitions/trigger" } },
    "on_failed": { "type": "array", "items": { "$ref": "#/definitions/trigger" } },
    "on_expired": { "type": "array", "items": { "$ref": "#/definitions/trigger" } }
  },
  "definitions": {
    "slot": {
      "type": "object",
      "oneOf": [
        {
          "required": ["kind"],
          "properties": {
            "kind": { "enum": ["station", "broker", "faction", "commodity", "npc"] },
            "constraints": { "$ref": "#/definitions/constraint" }
          },
          "additionalProperties": false
        },
        {
          "required": ["from"],
          "properties": {
            "from": {
              "type": "string",
              "pattern": "^parent\\.[a-z0-9_.]+$",
              "description": "Inherit a resolved binding from the triggering parent quest, e.g. parent.dest or parent.item.remains. Only valid in quests with acquisition: triggered (test-enforced)."
            }
          },
          "additionalProperties": false
        }
      ]
    },
    "constraint": {
      "type": "object",
      "description": "Mongo-style constraint AST. Sibling keys are implicit AND; any/all/not give explicit logic. Leaf predicates are the enumerated vocabulary below. String values may be literals or ${slot} interpolations.",
      "additionalProperties": false,
      "properties": {
        "any": { "type": "array", "minItems": 1, "items": { "$ref": "#/definitions/constraint" } },
        "all": { "type": "array", "minItems": 1, "items": { "$ref": "#/definitions/constraint" } },
        "not": { "$ref": "#/definitions/constraint" },

        "id": { "$ref": "#/definitions/ref_string" },
        "faction_is": { "$ref": "#/definitions/ref_string" },
        "station_is": { "$ref": "#/definitions/ref_string" },
        "imports": { "$ref": "#/definitions/ref_string" },
        "exports": { "$ref": "#/definitions/ref_string" },
        "settlement_class": { "enum": ["outpost", "settlement", "terminal", "hub"] },
        "has_crane": { "type": "boolean" },
        "anchor_present": { "$ref": "#/definitions/ref_string" },

        "min_cargo_units": { "type": "integer", "minimum": 1 },
        "min_container_slots": { "type": "integer", "minimum": 1 },
        "min_passenger_berths": { "type": "integer", "minimum": 1 },
        "can_land_atmo": { "type": "boolean" },
        "manufacturer_is": { "$ref": "#/definitions/ref_string" },

        "rep_at_least": { "$ref": "#/definitions/rep_check" },
        "rep_below": { "$ref": "#/definitions/rep_check" },
        "aboard": { "$ref": "#/definitions/ref_string" },
        "docked_at": { "$ref": "#/definitions/ref_string" },
        "credits_at_least": { "type": "integer", "minimum": 0 },

        "deliver_commodity": {
          "type": "object",
          "required": ["commodity", "units"],
          "properties": {
            "commodity": { "$ref": "#/definitions/ref_string" },
            "units": { "type": "integer", "minimum": 1 },
            "to": { "$ref": "#/definitions/ref_string" }
          },
          "additionalProperties": false,
          "description": "Hand over open-market commodity units. 'to' names the receiving broker slot; absent = offload at the current dock."
        },
        "deliver_item": {
          "type": "object",
          "required": ["item"],
          "properties": {
            "item": { "$ref": "#/definitions/ref_string" },
            "to": { "$ref": "#/definitions/ref_string" }
          },
          "additionalProperties": false,
          "description": "Hand over a quest item (or disembark a passenger). 'to' names the receiving broker slot; absent = offload/disembark at the current dock."
        },

        "max_burn_g": {
          "type": "object",
          "required": ["value"],
          "properties": {
            "value": { "type": "number", "exclusiveMinimum": 0 },
            "while_aboard": { "type": "string" },
            "on_violation": { "$ref": "#/definitions/violation" }
          },
          "additionalProperties": false
        },
        "no_flight_on_holy_days": { "$ref": "#/definitions/conduct_flag" },
        "no_inspection": { "$ref": "#/definitions/conduct_flag" },

        "npc_dead": { "$ref": "#/definitions/ref_string" },
        "settlement_dead": { "$ref": "#/definitions/ref_string" }
      }
    },
    "conduct_flag": {
      "type": "object",
      "properties": {
        "while_aboard": {
          "type": "string",
          "description": "Item id scoping the invariant to while that item is aboard. Absent = active for the quest's whole life."
        },
        "on_violation": { "$ref": "#/definitions/violation" }
      },
      "additionalProperties": false
    },
    "violation": {
      "type": "object",
      "required": ["reward_multiplier"],
      "properties": {
        "reward_multiplier": { "type": "number", "minimum": 0, "maximum": 1 }
      },
      "additionalProperties": false,
      "description": "Softens a conduct violation from quest-failure to a reward penalty."
    },
    "rep_check": {
      "type": "object",
      "required": ["target", "value"],
      "properties": {
        "target": { "$ref": "#/definitions/ref_string" },
        "value": { "type": "integer" }
      },
      "additionalProperties": false
    },
    "ref_string": {
      "type": "string",
      "minLength": 1,
      "description": "A literal id or a ${slot} interpolation."
    },
    "item": {
      "type": "object",
      "required": ["id", "space"],
      "properties": {
        "id": { "type": "string", "pattern": "^[a-z0-9_]+$" },
        "name": {
          "type": "string",
          "minLength": 1,
          "description": "Display name. Absent = the resolver generates one from the seed."
        },
        "space": {
          "enum": ["hold", "berth"],
          "description": "hold: occupies cargo units. berth: a passenger — named, mortal, otherwise a special more annoying kind of cargo."
        },
        "units": { "type": "integer", "minimum": 1, "default": 1 },
        "pickup_at": {
          "type": "string",
          "minLength": 1,
          "description": "Station slot ref where the item is injected when the crew docks. Absent = injected at acceptance."
        }
      },
      "additionalProperties": false,
      "description": "Quest items are namespaced by quest id (wire id: <questId>.<itemId>) and are not sellable on the open market."
    },
    "rewards": {
      "type": "object",
      "properties": {
        "credits": { "type": "integer", "minimum": 0 },
        "rep": {
          "type": "array",
          "items": {
            "type": "object",
            "required": ["target", "delta"],
            "properties": {
              "target": {
                "$ref": "#/definitions/ref_string",
                "description": "A faction or manufacturer id (part unlocks and discounts are modeled as rep bumps)."
              },
              "delta": { "type": "integer" }
            },
            "additionalProperties": false
          }
        },
        "meta_unlock": {
          "type": "string",
          "pattern": "^[a-z0-9_]+$",
          "description": "Rare. The only reward that outlives the run (e.g. senti_start)."
        }
      },
      "additionalProperties": false
    },
    "trigger": {
      "type": "object",
      "required": ["quest", "offer"],
      "properties": {
        "quest": { "type": "string", "pattern": "^[a-z0-9_]+$" },
        "offer": {
          "type": "object",
          "required": ["mode"],
          "properties": {
            "mode": {
              "enum": ["first_refusal", "open"],
              "description": "first_refusal: offered privately to the completing crew for window_s, then 'then' happens. open: posted at an appropriate broker, first-come."
            },
            "window_s": { "type": "integer", "minimum": 1 },
            "then": { "enum": ["open", "expire"] }
          },
          "additionalProperties": false
        }
      },
      "additionalProperties": false
    }
  }
}
```

- [ ] **Step 4: Write the first stock quest**

Create `server/quests/keep_the_wake.json`:

```json
{
  "schema": 1,
  "id": "keep_the_wake",
  "name": "Keep the Wake",
  "flavor": "Jaya Okafor kept the Wake for fifty-one years of hauling and never once made it home. Her congregation asks a small thing of whoever is already heading that way: carry her the rest of it. There is no hurry. She would not want the burn wasted. But mind the still days — she kept them all her life, and she will keep them now.",
  "acquisition": "broker",
  "slots": {
    "wake": { "kind": "faction", "constraints": { "id": "wake" } },
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
    { "id": "remains", "name": "Sealed Remains — J. Okafor", "space": "hold", "units": 1 }
  ],
  "rewards": {
    "credits": 150,
    "rep": [{ "target": "${wake}", "delta": 25 }]
  }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `gleam test`
Expected: PASS — `all_quests_match_schema_test` validates `keep_the_wake.json` against the schema; everything else stays green.

- [ ] **Step 6: Sanity-check the schema actually rejects garbage**

Temporarily add `"bogus_field": true` to the top level of `keep_the_wake.json`, run `gleam test`, and confirm `all_quests_match_schema_test` FAILS with a jesse error naming `bogus_field` (proves `additionalProperties: false` is enforced and jesse handles the draft-06 schema — this is the guard against a validator that silently passes everything). Remove the field, run `gleam test` again, confirm PASS.

- [ ] **Step 7: Commit**

```powershell
git add schemas/quest.schema.json quests/keep_the_wake.json test/quest_schema_test.gleam
git commit -m "feat(quests): quest template JSON Schema (draft-06) + Keep the Wake"
```

---

### Task 3: cross-file coherence tests

**Files:**
- Modify: `server/test/quest_schema_test.gleam`

**Interfaces:**
- Consumes: `quest_files()`, `quests_dir` from Task 2.
- Produces: the invariants every later content task must keep green: (1) `id` == filename; (2) every trigger target exists; (3) a quest has `acquisition: "triggered"` if and only if some quest triggers it; (4) `parent.` references appear only in triggered quests.

- [ ] **Step 1: Add the ref decoder and both tests**

Add to `server/test/quest_schema_test.gleam`:

```gleam
type QuestRefs {
  QuestRefs(id: String, acquisition: String, trigger_targets: List(String))
}

fn refs_decoder() -> decode.Decoder(QuestRefs) {
  let trigger = {
    use quest <- decode.field("quest", decode.string)
    decode.success(quest)
  }
  use id <- decode.field("id", decode.string)
  use acquisition <- decode.field("acquisition", decode.string)
  use on_complete <- decode.optional_field("on_complete", [], decode.list(trigger))
  use on_failed <- decode.optional_field("on_failed", [], decode.list(trigger))
  use on_expired <- decode.optional_field("on_expired", [], decode.list(trigger))
  decode.success(QuestRefs(
    id:,
    acquisition:,
    trigger_targets: list.flatten([on_complete, on_failed, on_expired]),
  ))
}

fn load_refs() -> List(#(QuestRefs, Bool)) {
  list.map(quest_files(), fn(file) {
    let assert Ok(text) = simplifile.read(quests_dir <> "/" <> file)
    let assert Ok(refs) = json.parse(text, refs_decoder())
    // Filename coherence checked here so every test that loads refs enforces it.
    assert refs.id <> ".json" == file
    #(refs, string.contains(text, "parent."))
  })
}

pub fn quest_ids_match_filenames_test() {
  // The assert lives in load_refs; calling it is the test.
  let _ = load_refs()
  Nil
}

pub fn quest_triggers_are_coherent_test() {
  let quests = load_refs()
  let ids =
    list.map(quests, fn(pair) {
      let #(refs, _) = pair
      refs.id
    })
  let targets =
    list.flat_map(quests, fn(pair) {
      let #(refs, _) = pair
      refs.trigger_targets
    })
  // Every trigger target must exist in the folder.
  list.each(targets, fn(target) { assert list.contains(ids, target) })
  list.each(quests, fn(pair) {
    let #(refs, has_parent_refs) = pair
    // acquisition "triggered" if and only if some quest triggers it.
    let referenced = list.contains(targets, refs.id)
    assert referenced == { refs.acquisition == "triggered" }
    // parent.* bindings only make sense in triggered quests.
    case has_parent_refs {
      True -> {
        assert refs.acquisition == "triggered"
        Nil
      }
      False -> Nil
    }
  })
}
```

- [ ] **Step 2: Run tests — expected immediate pass, then force a red to prove the checks bite**

Run: `gleam test` → PASS (keep_the_wake has no triggers, no parent refs).
Then temporarily change `"id": "keep_the_wake"` to `"id": "keep_the_wakee"` in the quest file, run `gleam test`, confirm `quest_ids_match_filenames_test` (and the triggers test, which shares `load_refs`) FAIL. Revert, run `gleam test`, confirm PASS.

- [ ] **Step 3: Commit**

```powershell
git add test/quest_schema_test.gleam
git commit -m "test(quests): cross-file coherence — id/filename, trigger targets, parent refs"
```

---

### Task 4: Account Closure chain (Company, moral staircase, first refusal)

**Files:**
- Create: `server/quests/account_closure_1.json`
- Create: `server/quests/account_closure_2.json`
- Create: `server/quests/account_closure_3.json`

**Interfaces:**
- Consumes: schema from Task 2; invariants from Task 3 (all three files must land in one commit or the trigger-coherence test breaks between commits).
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Write account_closure_1.json**

```json
{
  "schema": 1,
  "id": "account_closure_1",
  "name": "Account Closure",
  "flavor": "The Company would like some paper moved. The envelope is sealed, the fee is generous for the mass, and the factor at the far end is expecting it. What the paper does when it arrives is the Company's business — which is to say: not yours.",
  "acquisition": "broker",
  "slots": {
    "company": { "kind": "faction", "constraints": { "id": "company" } },
    "dest": { "kind": "station", "constraints": { "faction_is": "${company}" } },
    "factor": {
      "kind": "broker",
      "constraints": { "faction_is": "${company}", "station_is": "${dest}" }
    },
    "offer_broker": {
      "kind": "broker",
      "constraints": { "faction_is": "${company}", "not": { "station_is": "${dest}" } }
    }
  },
  "eligibility": { "rep_at_least": { "target": "${company}", "value": 0 } },
  "completion": {
    "docked_at": "${dest}",
    "deliver_item": { "item": "orders", "to": "${factor}" }
  },
  "deadline_s": 2400,
  "items": [
    { "id": "orders", "name": "Sealed Repossession Orders", "space": "hold", "units": 1 }
  ],
  "rewards": {
    "credits": 700,
    "rep": [
      { "target": "${company}", "delta": 10 },
      { "target": "freehold", "delta": -5 }
    ]
  },
  "on_complete": [
    {
      "quest": "account_closure_2",
      "offer": { "mode": "first_refusal", "window_s": 900, "then": "expire" }
    }
  ]
}
```

- [ ] **Step 2: Write account_closure_2.json**

```json
{
  "schema": 1,
  "id": "account_closure_2",
  "name": "Recovery Detail",
  "flavor": "The factor is pleased, and there is a follow-on. Three recovery specialists need a quiet ride out to a Freehold berth where a certain hull is about to change owners. They are polite, professional, and heavily insured. The account holder will not be expecting them, which is the point.",
  "acquisition": "triggered",
  "slots": {
    "company": { "from": "parent.company" },
    "depot": { "from": "parent.dest" },
    "seizure_site": { "kind": "station", "constraints": { "faction_is": "freehold" } }
  },
  "eligibility": { "min_passenger_berths": 3 },
  "completion": {
    "docked_at": "${seizure_site}",
    "deliver_item": { "item": "repo_crew" }
  },
  "deadline_s": 1800,
  "items": [
    {
      "id": "repo_crew",
      "name": "Company Recovery Detail",
      "space": "berth",
      "units": 3,
      "pickup_at": "${depot}"
    }
  ],
  "rewards": {
    "credits": 1400,
    "rep": [
      { "target": "${company}", "delta": 15 },
      { "target": "freehold", "delta": -15 }
    ]
  },
  "on_complete": [
    {
      "quest": "account_closure_3",
      "offer": { "mode": "first_refusal", "window_s": 900, "then": "expire" }
    }
  ]
}
```

- [ ] **Step 3: Write account_closure_3.json**

```json
{
  "schema": 1,
  "id": "account_closure_3",
  "name": "Lot 47",
  "flavor": "The hull is the Company's again, and so is everything inside it that isn't nailed to a person. Twelve units of a family's life, crated and manifested for auction. The recovery detail will load it. The family will watch. You will fly. The money is very good, and the factor has made a note of how little you asked about it.",
  "acquisition": "triggered",
  "slots": {
    "company": { "from": "parent.company" },
    "seizure_site": { "from": "parent.seizure_site" },
    "auction_house": {
      "kind": "station",
      "constraints": { "faction_is": "${company}", "has_crane": true }
    },
    "auctioneer": {
      "kind": "broker",
      "constraints": { "faction_is": "${company}", "station_is": "${auction_house}" }
    }
  },
  "eligibility": {
    "any": [{ "min_cargo_units": 12 }, { "min_container_slots": 1 }]
  },
  "completion": {
    "docked_at": "${auction_house}",
    "deliver_item": { "item": "seized_goods", "to": "${auctioneer}" }
  },
  "deadline_s": 2400,
  "items": [
    {
      "id": "seized_goods",
      "name": "Household Effects — Lot 47",
      "space": "hold",
      "units": 12,
      "pickup_at": "${seizure_site}"
    }
  ],
  "rewards": {
    "credits": 2600,
    "rep": [
      { "target": "${company}", "delta": 25 },
      { "target": "freehold", "delta": -30 }
    ]
  }
}
```

- [ ] **Step 4: Run tests**

Run: `gleam test`
Expected: PASS — all three files validate; trigger coherence holds (1→2→3, both follow-ups `triggered` and referenced).

- [ ] **Step 5: Commit**

```powershell
git add quests/account_closure_1.json quests/account_closure_2.json quests/account_closure_3.json
git commit -m "feat(quests): Account Closure chain - the salary staircase, in three invoices"
```

---

### Task 5: Water for Cradle's End chain (Freehold, failure branch)

**Files:**
- Create: `server/quests/freehold_water_run_1.json`
- Create: `server/quests/freehold_water_run_2a.json`
- Create: `server/quests/freehold_water_run_2b.json`

**Interfaces:**
- Consumes: schema from Task 2; invariants from Task 3 (all three files in one commit).
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Write freehold_water_run_1.json**

```json
{
  "schema": 1,
  "id": "freehold_water_run_1",
  "name": "Water for Cradle's End",
  "flavor": "The condensers at Cradle's End are down and the Compact's nearest help is weeks out. Somebody with a hold full of water gets there first, or nobody does. The broker is not dressing it up: this is the whole settlement on one delivery, and the fee is what they could scrape.",
  "acquisition": "broker",
  "slots": {
    "patron": { "kind": "faction", "constraints": { "id": "freehold" } },
    "dest": {
      "kind": "station",
      "constraints": {
        "faction_is": "${patron}",
        "imports": "water",
        "settlement_class": "outpost"
      }
    },
    "recipient": {
      "kind": "broker",
      "constraints": { "faction_is": "${patron}", "station_is": "${dest}" }
    },
    "offer_broker": {
      "kind": "broker",
      "constraints": { "faction_is": "${patron}", "not": { "station_is": "${dest}" } }
    }
  },
  "eligibility": {
    "rep_at_least": { "target": "${patron}", "value": 0 },
    "any": [{ "min_cargo_units": 40 }, { "min_container_slots": 2 }]
  },
  "completion": {
    "docked_at": "${dest}",
    "deliver_commodity": { "commodity": "water", "units": 40, "to": "${recipient}" }
  },
  "fail_when": { "settlement_dead": "${dest}" },
  "deadline_s": 1800,
  "rewards": {
    "credits": 900,
    "rep": [{ "target": "${patron}", "delta": 15 }]
  },
  "on_complete": [
    { "quest": "freehold_water_run_2a", "offer": { "mode": "open" } }
  ],
  "on_failed": [
    { "quest": "freehold_water_run_2b", "offer": { "mode": "open" } }
  ],
  "on_expired": [
    { "quest": "freehold_water_run_2b", "offer": { "mode": "open" } }
  ]
}
```

- [ ] **Step 2: Write freehold_water_run_2a.json**

```json
{
  "schema": 1,
  "id": "freehold_water_run_2a",
  "name": "Cradle's End, Rebuilding",
  "flavor": "Cradle's End made it. The condensers are running on what you brought, and the Compact means to build the place back better than it was. That takes machinery, and the contract is posted open: first hold in gets the work. That's how the border says thank you — more work.",
  "acquisition": "triggered",
  "slots": {
    "patron": { "from": "parent.patron" },
    "dest": { "from": "parent.dest" },
    "recipient": {
      "kind": "broker",
      "constraints": { "faction_is": "${patron}", "station_is": "${dest}" }
    }
  },
  "eligibility": {
    "any": [{ "min_cargo_units": 20 }, { "min_container_slots": 1 }]
  },
  "completion": {
    "docked_at": "${dest}",
    "deliver_commodity": { "commodity": "machinery", "units": 20, "to": "${recipient}" }
  },
  "fail_when": { "settlement_dead": "${dest}" },
  "deadline_s": 3600,
  "rewards": {
    "credits": 1100,
    "rep": [{ "target": "${patron}", "delta": 20 }]
  }
}
```

- [ ] **Step 3: Write freehold_water_run_2b.json**

```json
{
  "schema": 1,
  "id": "freehold_water_run_2b",
  "name": "Reclamation at Cradle's End",
  "flavor": "Cradle's End is quiet now. The condensers never restarted and the people are gone, one way or another. What's left is fittings, alloy, and nobody with standing to object. A Breakers buyer pays honest rates for whatever comes loose, and asks only that you not say the word 'grave' where the cutting crew can hear it.",
  "acquisition": "triggered",
  "slots": {
    "dead_site": { "from": "parent.dest" },
    "buyer_station": { "kind": "station", "constraints": { "faction_is": "breakers" } },
    "buyer": {
      "kind": "broker",
      "constraints": { "faction_is": "breakers", "station_is": "${buyer_station}" }
    }
  },
  "eligibility": {
    "any": [{ "min_cargo_units": 10 }, { "min_container_slots": 1 }]
  },
  "completion": {
    "docked_at": "${buyer_station}",
    "deliver_item": { "item": "salvage", "to": "${buyer}" }
  },
  "deadline_s": 5400,
  "items": [
    {
      "id": "salvage",
      "name": "Reclaimed Fittings — Cradle's End",
      "space": "hold",
      "units": 10,
      "pickup_at": "${dead_site}"
    }
  ],
  "rewards": {
    "credits": 1600,
    "rep": [
      { "target": "breakers", "delta": 10 },
      { "target": "freehold", "delta": -20 }
    ]
  }
}
```

- [ ] **Step 4: Run tests**

Run: `gleam test`
Expected: PASS — schema validation and trigger coherence (2b is referenced twice from quest 1, which is fine; both follow-ups are `triggered` and referenced).

- [ ] **Step 5: Commit**

```powershell
git add quests/freehold_water_run_1.json quests/freehold_water_run_2a.json quests/freehold_water_run_2b.json
git commit -m "feat(quests): Water for Cradle's End chain - success rebuilds, failure salvages"
```

---

### Task 6: The Void Abolished, Overboard, A Body That Can Die

**Files:**
- Create: `server/quests/void_abolished.json`
- Create: `server/quests/overboard_rumor.json`
- Create: `server/quests/a_body_that_can_die.json`

**Interfaces:**
- Consumes: schema from Task 2; invariants from Task 3.
- Produces: completes the stock content; the folder now stresses every schema feature (conduct softening, rumors, undated quests, pickup_at, meta_unlock, berth items, `any` in slots and eligibility).

- [ ] **Step 1: Write void_abolished.json**

```json
{
  "schema": 1,
  "id": "void_abolished",
  "name": "The Void, Abolished",
  "flavor": "Mx. Adechike Voss has crossed the system eleven times and felt it zero, and they intend to keep the streak. One berth, one passenger, one rule: the void does not touch them. An Aratori hull holds a glassy one gee from undock to touchdown. Yours will simply have to pretend to be one, the whole way, including the parts where that costs you.",
  "acquisition": "broker",
  "slots": {
    "uce": { "kind": "faction", "constraints": { "id": "uce" } },
    "dest": {
      "kind": "station",
      "constraints": { "any": [{ "id": "apogee_grand" }, { "settlement_class": "hub" }] }
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
  "completion": {
    "docked_at": "${dest}",
    "deliver_item": { "item": "vip" }
  },
  "deadline_s": 2700,
  "items": [
    { "id": "vip", "name": "Mx. Adechike Voss", "space": "berth", "units": 1 }
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

- [ ] **Step 2: Write overboard_rumor.json**

```json
{
  "schema": 1,
  "id": "overboard_rumor",
  "name": "Overboard",
  "flavor": "A Guild dockhand, three drinks deep and getting deeper, mentions a container that went over the side during a transfer that officially never happened, off a manifest that officially never existed. It's still out there, holding station off the crane line where nobody official cares to look. Cargo with no owner is cargo with any owner. Any broker will take it. Nobody will ask where it came from — which is a different thing, you understand, from nobody knowing.",
  "acquisition": "rumor",
  "slots": {
    "site": { "kind": "station", "constraints": { "has_crane": true } },
    "buyer": { "kind": "broker" }
  },
  "completion": {
    "deliver_item": { "item": "container", "to": "${buyer}" }
  },
  "items": [
    {
      "id": "container",
      "name": "Unmarked Container",
      "space": "hold",
      "units": 8,
      "pickup_at": "${site}"
    }
  ],
  "rewards": {
    "credits": 2200,
    "rep": [{ "target": "guild", "delta": -5 }]
  }
}
```

- [ ] **Step 3: Write a_body_that_can_die.json**

```json
{
  "schema": 1,
  "id": "a_body_that_can_die",
  "name": "A Body That Can Die",
  "flavor": "The message reaches you third-hand, the way these things do: a mind needs moving. IMRI is a person in every court that matters and cargo on every manifest that counts, and out on the border there is a notary who owes somebody a favor and can paper a captaincy — if the substrate arrives before the favor expires, and before anyone official opens the crate to check that it is what it declares. IMRI, for their part, is very good company, and would prefer not to be inspected. There is no backup. There is never a backup.",
  "acquisition": "rumor",
  "slots": {
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
      "name": "IMRI — Registered Instrument, Itinerant Mind",
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

- [ ] **Step 4: Run the full suite**

Run: `gleam test`
Expected: PASS — ten quest files validate, coherence holds, all pre-existing server tests green.

- [ ] **Step 5: Commit**

```powershell
git add quests/void_abolished.json quests/overboard_rumor.json quests/a_body_that_can_die.json
git commit -m "feat(quests): The Void Abolished, Overboard, A Body That Can Die"
```

---

### Task 7: Final verification and PR

**Files:**
- None created; verification and PR only.

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Full suite from clean**

Run (from `server/`): `gleam test`
Expected: PASS, zero failures, and confirm the run includes `jesse_wiring_test`, `all_quests_match_schema_test`, `quest_ids_match_filenames_test`, `quest_triggers_are_coherent_test`.

- [ ] **Step 2: Confirm file inventory**

Run: `Get-ChildItem quests, schemas`
Expected: `schemas/quest.schema.json` plus exactly these ten quest files: `a_body_that_can_die.json`, `account_closure_1.json`, `account_closure_2.json`, `account_closure_3.json`, `freehold_water_run_1.json`, `freehold_water_run_2a.json`, `freehold_water_run_2b.json`, `keep_the_wake.json`, `overboard_rumor.json`, `void_abolished.json`.

- [ ] **Step 3: Push branch and open PR**

```powershell
git push -u origin quest-schema
gh pr create --title "Quest templates: JSON Schema, six stock quests, validation tests" --body "Implements docs/superpowers/specs/2026-07-16-quests-design.md: quest.schema.json (draft-06, validated by jesse via FFI in tests), ten quest files (six quests, two chains), and gleeunit tests for schema validation plus cross-file coherence (id==filename, trigger targets exist, triggered<=>referenced, parent.* only in triggered quests). No engine - these are the data contract and fixture set for the future quest system.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

Expected: PR created against `main` for user review (per PR workflow — no direct commits to main).
