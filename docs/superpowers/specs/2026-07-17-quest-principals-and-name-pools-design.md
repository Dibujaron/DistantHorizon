# Quest Principals & Name Pools — Design

Date: 2026-07-17
Status: approved pending review
Prereq reading: `2026-07-16-quests-design.md` (quest data contract), `docs/lore.md` (races, factions, signatory law)

## Goal

Quests currently hardcode the people and ships they star ("Jaya Okafor", "Mx. Adechike
Voss", "IMRI"). This work makes them **principals**: named individuals (characters and
ships) declared per-quest with constraints, generated deterministically at quest-instance
time, with names drawn from moddable, tag-matched **name pools**. End state: every
hardcoded name in the stock quests is generated, plus one new quest starring a ship
principal.

Characters and ships are *generated on demand*, not fixed at world-start like stations
and planets. Stations are a scarce fixed resource quests compete to **bind**; characters
are billions-strong and **conjured** to fit the story. Different lifecycle, different
mechanism.

## 1. Name data — `server/names/*.json`

Every file has the same shape: schema version, a `tags` block of file-wide defaults, and
`entries`.

```json
{
  "schema": 1,
  "tags": { "type": "character", "part": "family", "faction": "wake" },
  "entries": [
    "Okafor",
    "Ilesanmi",
    { "name": "Montclair", "tags": { "wealth": "high" } }
  ]
}
```

- **Entries** are plain strings normally; the object form overrides/extends the file's
  default tags for individual entries.
- **Filenames mean nothing.** The loader globs the folder, validates each file against
  the schema, and merges all entries into pools keyed purely by their effective tags.
  Any number of files — base game or mod — can contribute entries to the same pool.
  Extension = drop a new file in the folder; base files are never edited.
- **Tag axes:**
  - `type`: `character | ship` (required)
  - `part`: `given | family | full | title | pattern` (required)
  - `race`: `human | selkie | grafter | senti` (character only)
  - `faction`: a faction id (open string in the schema; validated at test time
    against the canonical faction constants in `names.gleam` — world files carry
    no factions yet, so code constants are the authority until they do)
  - `wealth`: `low | mid | high`
  - `gender`: `female | male | neutral`
  - `role`: ship role id (ship only) — starter enum `packet | hauler | liner | gunship |
    tug | yacht`, kept in the names schema; when auto-categorization of hulls lands,
    that feature adopts this same enum
  - `manufacturer`: a manufacturer id (ship only)
- **Matching rule:** every axis except `type`/`part` is optional. An entry serves a
  generated principal iff every tag the entry declares is consistent with that
  principal's attributes. Untagged axis = usable for anyone. There is no
  specificity-preference in v1 — all matching entries are one uniform pool. (A
  prefer-most-specific knob is a possible later refinement; not now.)
- **Patterns are entries too.** `part: "pattern"` entries are templates over parts,
  e.g. `"${given} ${family}"`, `"${title} ${given} ${family}"`, `"${full}"`. They are
  tag-matched exactly like name entries. This is how cultures get different name
  *structures*: Senti pools carry `part: "full"` designations (IMRI-style) and a
  `"${full}"` pattern; a high-wealth pattern can layer honorifics. Modders extend
  structure the same way they extend names.
- **Titles are entries too.** `part: "title"` entries ("Mr.", "Ms.", "Mx.") tagged by
  `gender` (and optionally faction/race/wealth), consumed by patterns via `${title}`
  and exposed as an interpolation form.
- **Authority:** `server/schemas/names.schema.json`, validated by the same jesse
  harness as the quest schema. It owns all closed vocabularies above.

## 2. Quest schema changes

- **Slot kinds.** The unused `npc` slot kind is renamed **`character`**; new kind
  **`ship`**. Unlike bind-kinds (station, broker, faction, commodity), these
  **generate**: the resolver conjures an entity satisfying the slot's constraints,
  deterministically from the quest-instance seed. Generation always succeeds (coverage
  is build-time-enforced, §5), so these slots never veto a quest's existence.
- **Constraints reuse the existing AST** — same `constraints` key, same `any`/`all`/
  `not` combinators, same `${slot}` interpolation in values. New leaf predicates:
  `race_is`, `wealth_is`, `gender_is`, `role_is`; `faction_is` and `manufacturer_is`
  already exist. Generation semantics: the attribute domain (race × faction × wealth ×
  gender, or role × faction × manufacturer for ships) is small and finite, so the
  resolver enumerates satisfying attribute assignments and samples one with the seed —
  the AST is well-defined as a generator, not only as a filter. So "Wake OR Breaker"
  is `any`, "wealth not high" is `not`, with no second predicate dialect.
  A coherence test (same style as the from-only-in-triggered rule) enforces which
  leaves are legal on generated slots.
- **Unconstrained axes are rolled** by the resolver. Gender rolls
  female/male/neutral at default weights 47.5/47.5/5 (per-culture tuning is a later
  knob).
- **Family hyphenation is generated, not curated.** With a small seeded chance
  (10%), the resolver double-barrels the family name from a second distinct draw of
  the same matching pools ("Sandoval-Okafor"). Pools contain no hyphenated entries —
  a lone curated hyphen reads as one family's quirk; the roll makes it a custom.
- **Interpolation forms** on character slots, usable anywhere `${slot}` already works
  (name, flavor, item names, constraint values):
  - `${x}` — full display name (the pattern's output)
  - `${x.given}`, `${x.family}` — components; cultures without that component fall
    back to full
  - `${x.short}` — given-initial + family ("J. Okafor"); falls back to full
  - `${x.title}` — Mr./Ms./Mx. etc. per gender/culture
  - Pronouns: `${x.ey}`, `${x.em}`, `${x.eir}`, `${x.eirs}`, `${x.emself}` plus
    capitalized variants (`${x.Ey}`, …) for sentence-initial position. Authors write
    prose in ey/em/eir; the resolver renders she/he forms for gendered characters.
  - Ship slots: `${x}` (name) and `${x.role}` (role display name, e.g. "Fast
    Packet") for now.
- **Items link to principals.** Item gains optional `"principal": "<slotName>"` — a
  berth item with a principal *is* that character; item `name` defaults to the
  principal's full display name when omitted.
- `npc_dead` renames to `character_dead`. `from: parent.x` inheritance already covers
  generated slots — sequel quests inherit the same generated person/ship for free.
- The schema `const` stays `"schema": 1` — the contract is pre-release with no
  external consumers; the `npc` kind it removes was never used. The TODO(name-pools)
  in the schema description is deleted; remaining TODOs stay.

## 3. Pronouns, address, and the lore behind them

**Canon: the neutral pronoun is `ey / em / eir / eirs / emself`** — "they/them/their"
with the *th* eroded off, grammatically **singular** ("ey keeps", like she/he), which
is what makes pronoun interpolation safe: all three pronoun sets conjugate
identically, so authored prose renders correctly for every generated character.

Cultural alignment — address style is a property of the character's culture:

- **Gendered address** (she/he, Mr./Ms.): the core — UCE and Company — and the Wake.
  Signatory law's obsession with the *natural-born human* is the tell: a society whose
  supreme legal category is inherited embodiment keeps its inherited categories.
- **Neutral address** (ey, Mx.): grafter communities (the void-born lineage above all) — when bodies are
  instruments, unused categories get spaced (indifference, not ideology) — and the
  Senti, who **popularized ey**: there is no way to force em into a binary. ("It" is
  reserved for non-sentient robots, and is a slur when aimed at a Senti.)
- **Mixed**: Freehold and frontier melting pots — per-character roll.
- **Selkies**: address style deliberately undecided; reserved for a lore session.

**Individual deviation exists everywhere**: any character can be `gender: neutral` in
a gendered culture (rendered ey/Mx., slightly marked), and a quest can pin any of this
with `gender_is`. Our flagship quests cast *representative* members of their cultures,
so e.g. Voss reads Mr./Ms. by the roll, not Mx.

v1 mechanics: pronoun rendering derives from gender + culture address style; the
culture → address-style table (race first, then faction) is a code constant in the
resolver with a TODO to move it data-side (likely per-faction in the world schema)
when modders need it. Titles come from `part: "title"` pool entries (§1), so *those*
are already moddable.

## 4. Content

- **Migrations** (end condition: zero hardcoded principal names in stock quests):
  - `keep_the_wake` — Okafor becomes a `character` slot constrained to Wake; gender
    unpinned; flavor rewritten with pronoun interpolation; item name
    `"Sealed Remains — ${okafor.short}"`.
  - `void_abolished` — Voss becomes a high-wealth UCE `character` slot; gender
    left unpinned so the default roll weights (47.5/47.5/5) apply: the typical
    Voss reads Mr./Ms., and roughly one in twenty is Mx. — nonbinary core
    citizens exist without reading as the core norm; flavor interpolated.
  - `a_body_that_can_die` — IMRI becomes a `race_is: senti` character slot.
  - `account_closure_2`'s "Company Recovery Detail" is an anonymous group, not a
    named principal — unchanged.
- **New ship quest** (working id `overdue_packet`): a generated ship principal in the
  background — "the ${ship}, ${ship.role}, was due at ${dest} days ago; hasn't been
  seen; someone needs to take its run" — mechanically a standard commodity run to
  `${dest}`. Demonstrates ship pools, `role_is`, and that the machinery isn't secretly
  character-shaped (no gender, no parts, different patterns).
- **Name pools** (base set, all reviewable as lore): human given/family generics;
  wake-, freehold-, company-, uce-flavored family pools; selkie names; grafter
  names; senti designations; titles; character patterns; ship names (some
  role-tagged); ship patterns. Sized to feel alive but stay reviewable.

## 5. Implementation & tests (data-contract level, engine wiring stays deferred)

- `server/src/dh_server/names.gleam`: load/validate/merge pools;
  `generate(constraints, seed) -> Character` and `-> Ship` returning **typed
  records** (attributes + all rendered forms: full, given, family, short, title,
  pronoun set) — no dict plumbing past the boundary.
- Determinism: same pools + same constraints + same seed → same principal.
  Cross-instance name uniqueness (collision re-roll against active principals) is an
  engine-integration concern, noted here, not built now.
- Tests, following the existing quest-test conventions:
  - names files validate against `names.schema.json`; quest files against the updated
    quest schema
  - merge behavior: multiple files contributing to one pool; entry-level tag override
  - deterministic generation; constraint AST honored (`any`/`not` over attributes)
  - pronoun/title rendering per gender × address style; ey-authored prose renders
    she/he correctly, capitalized forms included
  - every interpolation form resolves; unknown forms/slots rejected
  - **coverage test**: for every character/ship slot in every quest, and for every
    satisfiable attribute assignment's chosen pattern, all referenced parts have a
    non-empty pool — holes fail the build, not the run
  - coherence tests: generation-legal leaves only on character/ship slots;
    `principal` refs name an existing character slot; faction/manufacturer tags
    in name files exist in the canonical domain constants

## Out of scope

- Quest engine runtime (offer/accept/complete) — still deferred with the engine.
- Dialogue beyond `flavor` (TODO stands in the quest schema).
- Ship auto-categorization from hull stats — only the shared `role` enum lands now.
- Selkie address style and any deep faction-specific honorific sets — lore sessions.
- Per-culture gender-weight tuning; prefer-most-specific pool matching — later knobs
  if content demands them.
