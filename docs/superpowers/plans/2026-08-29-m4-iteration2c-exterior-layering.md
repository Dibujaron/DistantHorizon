# M4 Iteration 2c — Exterior Part Layering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A refit you can see — swap a ship's engine and her sprite changes, on every hull in the world, flying or moored or seen from inside.

**Architecture:** The server keeps owning *capability* (a mount is `{id, kind, size}`) and the renderer takes over *geometry* (a named mount anchor in the sprite's `meta.json`). Each ship's appearance — its hull sprite key and its fitted mounts' part sprite keys — is computed once at fit time, stored on `loadout.Fit`, and rides the snapshot. The client layers standalone part sprites onto hull sprites as child `Sprite2D`s in hull-texture px.

**Tech Stack:** Gleam (server, `gleam test`), GDScript/Godot 4 (client), Python (`tools/artspike` art pipeline via resvg + numpy + PIL; `harness/` pytest protocol tests).

**Spec:** `docs/superpowers/specs/2026-08-29-m4-iteration2c-exterior-layering-design.md`

## Global Constraints

- **Branch:** `feat/m4-exterior-layering`. One PR for the whole iteration. Never commit to `main`.
- **Commit message suffix:** every commit subject ends with ` (#M4)`.
- **Gleam tests:** `cd server; gleam test` — 366 tests green on `main` today; the count only goes up.
- **Harness tests:** `cd harness; python -m pytest -q` — 30 green today. Needs `$env:Path = "$env:USERPROFILE\scoop\shims;$env:Path"` so `gleam` is on PATH (the fixture spawns a real server).
- **Artspike tests:** `python -m pytest tools/artspike -q` from the repo root.
- **Scale canon:** every sprite export shares one `px_per_unit` = `classic_px / model_units` = `45/195`. One deckplan tile ≈ 1 m ≈ 6.5 model units. Never introduce a second scale.
- **Sprite keys, never part ids, on the wire.** The client has no parts catalog.
- **No mount rotation.** Engines only point aft; `rot_deg` is a turret field and turrets do not exist.
- **Lowercase says what a tile IS, uppercase says which slot it BELONGS TO** — the deckplan invariant. Nothing in this plan touches deck rows, but do not break it.

---

## File Structure

**Server (Gleam)**

| File | Responsibility | Change |
| --- | --- | --- |
| `server/src/dh_server/hull.gleam` | Hull document type + decoder | Add `sprite: String` (Task 1) |
| `server/src/dh_server/loadout.gleam` | Fit resolution | Add `Appearance` type, compute in `resolve`, store on `Fit` (Task 2) |
| `server/src/dh_server/protocol.gleam` | Wire encoding | `encode_snapshot` takes appearances (Task 3) |
| `server/src/dh_server/sim.gleam` | Sim actor | Pair ships with their fits' appearances at broadcast (Task 3) |
| `server/schemas/hull.schema.json` | Hull schema | Add `sprite` (Task 1) |
| `server/shipclasses/*.json` | The three hulls | Author `sprite` (Task 1) |

**Art pipeline (Python)**

| File | Responsibility | Change |
| --- | --- | --- |
| `tools/artspike/composer.py` | Rasterise + export | Named mount anchors (Task 5); `PART_EXPORTS` + `export_part` (Task 6) |
| `tools/artspike/manufacturers.py` | Authored ship/part SVG | Mount anchor ids (Task 5); `engine_rijay`/`engine_consol` (Tasks 6, 7); Mockingbird re-cut (Task 7); Wren (Task 11); Sparrow (Task 12); Goldfinch (Task 13) |
| `tools/artspike/test_composer.py` | Pipeline tests | Every art task |

**Client (GDScript)**

| File | Responsibility | Change |
| --- | --- | --- |
| `client/scripts/ship_state.gd` | Snapshot ship entry | Add `hull_sprite`, `mounts` (Task 4) |
| `client/scripts/asset_library.gd` | Runtime asset loading | Directory enumeration; `part()`; `mount_anchor()`/`attach_px()` (Tasks 4, 8) |
| `client/scripts/world_view.gd` | Space rendering | Per-ship hull; `_dress_hull`; plume from mounts (Tasks 4, 8, 9) |
| `client/scripts/main.gd` | Frame orchestration | Per-ship interior backdrops (Tasks 4, 8) |
| `client/scripts/interior_view.gd` | Walk-mode rendering | `Backdrop` carries fittings (Task 8) |

**Harness (Python)**

| File | Responsibility | Change |
| --- | --- | --- |
| `harness/dh_client.py` | Protocol validator | `validate_snapshot` checks appearance (Task 3) |
| `harness/test_m4_exterior.py` | **NEW** — cross-tree consistency | Mount ids ↔ anchor ids; part sprite keys ↔ asset dirs (Tasks 5, 6) |

---

# HALF 1 — MACHINERY

---

### Task 1: Hull documents gain a `sprite` key

**Files:**
- Modify: `server/src/dh_server/hull.gleam:37-68` (the `Hull` type), `:153-202` (`hull_decoder`)
- Modify: `server/schemas/hull.schema.json`
- Modify: `server/shipclasses/mockingbird.json`, `server/shipclasses/sparrow.json`, `server/shipclasses/goldfinch.json`
- Test: `server/test/hull_test.gleam`

**Interfaces:**
- Consumes: nothing.
- Produces: `hull.Hull` gains field `sprite: String` — the art directory name under `client/assets/ships/`. Absent in the document ⇒ defaults to the hull's `id`.

- [ ] **Step 1: Write the failing tests**

Append to `server/test/hull_test.gleam`:

```gleam
pub fn hull_sprite_defaults_to_id_test() {
  let json =
    "{\"schema\":3,\"id\":\"testbed\",\"name\":\"Testbed\","
    <> "\"decks\":[{\"name\":\"Main\",\"grid\":[\"...\"]}],"
    <> "\"cargo\":{\"capacity\":1,\"handling\":\"breakbulk\"}}"
  let assert Ok(h) = hull.decode(json)
  assert h.sprite == "testbed"
}

pub fn hull_sprite_is_authored_when_present_test() {
  let json =
    "{\"schema\":3,\"id\":\"testbed\",\"name\":\"Testbed\","
    <> "\"sprite\":\"other_art\","
    <> "\"decks\":[{\"name\":\"Main\",\"grid\":[\"...\"]}],"
    <> "\"cargo\":{\"capacity\":1,\"handling\":\"breakbulk\"}}"
  let assert Ok(h) = hull.decode(json)
  assert h.sprite == "other_art"
}

pub fn shipped_hulls_author_their_sprite_test() {
  let assert Ok(hulls) = hull.load_all("shipclasses")
  let assert Ok(mb) = dict.get(hulls, "mockingbird")
  let assert Ok(sp) = dict.get(hulls, "sparrow")
  let assert Ok(gf) = dict.get(hulls, "goldfinch")
  assert mb.sprite == "mockingbird"
  assert sp.sprite == "sparrow"
  assert gf.sprite == "goldfinch"
}
```

(If `hull_test.gleam` does not already import `gleam/dict`, add `import gleam/dict`.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server; gleam test`
Expected: compile error — `Hull` has no field `sprite`.

- [ ] **Step 3: Add the field and the decoder line**

In `hull.gleam`, add to the `Hull` type after `name`:

```gleam
    /// The art directory under `client/assets/ships/` this hull is drawn
    /// with. Geometry (where a part sits) lives in that directory's
    /// meta.json as a named mount anchor; the hull document deliberately
    /// carries none. Defaults to `id`.
    sprite: String,
```

In `hull_decoder()`, after the `name` field:

```gleam
  use sprite <- decode.optional_field("sprite", id, decode.string)
```

and add `sprite: sprite,` to the `decode.success(Hull(...))` construction.

- [ ] **Step 4: Add `sprite` to the schema**

In `server/schemas/hull.schema.json`, alongside `"name"` in `properties`:

```json
"sprite": {
  "type": "string",
  "description": "Art directory under client/assets/ships/. Defaults to the hull id. Mount GEOMETRY lives in that directory's meta.json as a named mount anchor, never here."
},
```

- [ ] **Step 5: Author it on the three shipped hulls**

Add `"sprite": "mockingbird",` / `"sparrow"` / `"goldfinch"` immediately after each hull's `"name"` line in `server/shipclasses/*.json`. Leave `server/test/fixtures/dock_testbed_hulls/dock_testbed.json` and `refit_testbed_hulls/refit_testbed.json` alone — they never reach a client and exercise the default.

- [ ] **Step 6: Run the full suite**

Run: `cd server; gleam test`
Expected: PASS, 369 tests.

- [ ] **Step 7: Commit**

```bash
git add server/src/dh_server/hull.gleam server/schemas/hull.schema.json server/shipclasses server/test/hull_test.gleam
git commit -m "feat(hull): a hull names its art directory with sprite (#M4)"
```

---

### Task 2: `Appearance` on the resolved fit

**Files:**
- Modify: `server/src/dh_server/loadout.gleam:31-52` (types), `:96-134` (`resolve`)
- Test: `server/test/loadout_test.gleam`

**Interfaces:**
- Consumes: `hull.Hull.sprite` (Task 1); `part.Part.sprite: Option(String)` (already exists).
- Produces:
  ```gleam
  pub type Appearance {
    Appearance(hull_sprite: String, mounts: List(#(String, String)))
  }
  pub type Fit {
    Fit(loadout: Loadout, class: ShipClass, mass: Float, appearance: Appearance)
  }
  ```
  `mounts` pairs mount id → part **sprite key**, in the hull's declared mount order, omitting mounts with nothing fitted and parts with no `sprite`.

**Why here:** `resolve` already holds the hull and `mounted: List(#(String, Part))`. Computing appearance once at fit time means the sim does no per-tick catalog lookups and the appearance can never disagree with the fit that produced it.

- [ ] **Step 1: Write the failing test**

Append to `server/test/loadout_test.gleam`:

```gleam
pub fn appearance_carries_hull_sprite_and_fitted_part_sprites_test() {
  let assert Ok(fit) = mockingbird_default_fit()
  assert fit.appearance.hull_sprite == "mockingbird"
  // Her lore default: a Consol centre between two Rijay originals.
  assert list.key_find(fit.appearance.mounts, "engine_port")
    == Ok("engine_rijay")
  assert list.key_find(fit.appearance.mounts, "engine_center")
    == Ok("engine_consol")
  assert list.key_find(fit.appearance.mounts, "engine_stbd")
    == Ok("engine_rijay")
}

pub fn appearance_omits_an_unfitted_mount_test() {
  // The Sparrow ships engine_center bare by design.
  let assert Ok(fit) = sparrow_default_fit()
  assert list.key_find(fit.appearance.mounts, "engine_port")
    == Ok("engine_rijay_small")
  assert list.key_find(fit.appearance.mounts, "engine_center") == Error(Nil)
  assert list.length(fit.appearance.mounts) == 2
}
```

Use whatever fixture helper `loadout_test.gleam` already has for resolving a shipped hull's default loadout; if there is none, write these two helpers at the top of the file:

```gleam
fn default_fit_for(hull_id: String) -> Result(loadout.Fit, String) {
  let assert Ok(reg) = glyphs.load("../server/glyphs.json")
  let assert Ok(hulls) = hull.load_all("shipclasses")
  let assert Ok(modules) = module.load_all("modules")
  let assert Ok(parts) = part.load_all("parts")
  let assert Ok(h) = dict.get(hulls, hull_id)
  loadout.resolve(reg, h, modules, parts, loadout.default_for(h))
}

fn mockingbird_default_fit() { default_fit_for("mockingbird") }
fn sparrow_default_fit() { default_fit_for("sparrow") }
```

(Match the existing file's loading idiom for `glyphs`/`module`/`part` — copy it verbatim from a neighbouring test rather than inventing paths.)

- [ ] **Step 2: Run to verify it fails**

Run: `cd server; gleam test`
Expected: compile error — `Fit` has no field `appearance`.

- [ ] **Step 3: Add the type and the field**

In `loadout.gleam`, after the `Loadout` type:

```gleam
/// What a fit LOOKS LIKE: the hull's art directory and the sprite key of the
/// part on each fitted mount. Sprite keys, never part ids — the client has no
/// parts catalog, so ids would mean shipping it one. Computed once here rather
/// than per tick, so it cannot disagree with the fit that produced it.
pub type Appearance {
  Appearance(hull_sprite: String, mounts: List(#(String, String)))
}
```

Change `Fit` to:

```gleam
pub type Fit {
  Fit(
    loadout: Loadout,
    class: ShipClass,
    mass: Float,
    appearance: Appearance,
  )
}
```

- [ ] **Step 4: Compute it in `resolve`**

Add this helper below `resolve`:

```gleam
/// A mount with nothing on it, or a part with no `sprite`, simply does not
/// appear — the client draws the hull's blanking plate there.
fn appearance_of(h: Hull, mounted: List(#(String, Part))) -> Appearance {
  let mounts =
    list.filter_map(mounted, fn(entry) {
      let #(mount_id, p) = entry
      case p.sprite {
        Some(key) -> Ok(#(mount_id, key))
        option.None -> Error(Nil)
      }
    })
  Appearance(hull_sprite: h.sprite, mounts: mounts)
}
```

and change `resolve`'s final line from

```gleam
  Ok(Fit(loadout: lo, class: class, mass: mass))
```

to

```gleam
  Ok(Fit(
    loadout: lo,
    class: class,
    mass: mass,
    appearance: appearance_of(h, mounted),
  ))
```

`loadout.gleam` already imports `gleam/option.{Some}`; widen it to `import gleam/option.{type Option, Some}` only if the compiler asks. Using `option.None` qualified avoids touching the import at all.

- [ ] **Step 5: Run to verify it passes**

Run: `cd server; gleam test`
Expected: PASS. Any other construction site of `Fit(...)` in tests will fail to compile first — fix those by adding the field, and prefer reading it off a real `resolve` rather than hand-building an `Appearance`.

- [ ] **Step 6: Commit**

```bash
git add server/src/dh_server/loadout.gleam server/test/loadout_test.gleam
git commit -m "feat(loadout): a resolved fit carries its appearance (#M4)"
```

---

### Task 3: Appearance rides the snapshot

**Files:**
- Modify: `server/src/dh_server/protocol.gleam:37-41` (the doc comment), `:516-538` (`encode_snapshot`, `encode_ship`)
- Modify: `server/src/dh_server/sim.gleam:1971` (the broadcast call site)
- Modify: `server/test/protocol_test.gleam:227-272`, `server/test/dh_server_test.gleam:93`
- Modify: `harness/dh_client.py:365-381` (`validate_snapshot`)

**Interfaces:**
- Consumes: `loadout.Appearance` (Task 2).
- Produces: wire shape — each `snapshot.ships[]` entry gains
  `"hull": "<hull sprite key>"` and `"mounts": {"<mount id>": "<part sprite key>", …}`.
  `encode_snapshot(tick: Int, ships: List(#(Ship, loadout.Appearance))) -> String`.

- [ ] **Step 1: Write the failing test**

Replace `encode_snapshot_round_trip_test` in `server/test/protocol_test.gleam` — keep both existing `Ship` literals verbatim, and change the call plus add assertions:

```gleam
  let flying_look =
    loadout.Appearance(hull_sprite: "mockingbird", mounts: [
      #("engine_port", "engine_rijay"),
      #("engine_center", "engine_consol"),
    ])
  let docked_look =
    loadout.Appearance(hull_sprite: "sparrow", mounts: [])

  let text =
    protocol.encode_snapshot(42, [#(flying, flying_look), #(docked, docked_look)])
  assert string.contains(text, "\"tick\":42")
  assert string.contains(text, "\"hull\":\"mockingbird\"")
  assert string.contains(text, "\"engine_center\":\"engine_consol\"")
  assert string.contains(text, "\"hull\":\"sparrow\"")
```

Then add a second test pinning the empty case:

```gleam
pub fn encode_snapshot_empty_appearance_is_an_empty_object_test() {
  let s =
    ship.Ship(
      id: 9,
      x: 0.0,
      y: 0.0,
      vx: 0.0,
      vy: 0.0,
      heading: 0.0,
      controls: ship.Controls(rotate: 0.0, thrust: 0.0),
      dock: ship.Flying,
      wallet: ship.starting_wallet,
      hold: dict.new(),
      transfers: [],
    )
  let text =
    protocol.encode_snapshot(1, [
      #(s, loadout.Appearance(hull_sprite: "", mounts: [])),
    ])
  assert string.contains(text, "\"mounts\":{}")
}
```

Add `import dh_server/loadout` to the test file if absent.

- [ ] **Step 2: Run to verify it fails**

Run: `cd server; gleam test`
Expected: compile error — `encode_snapshot` expects `List(Ship)`.

- [ ] **Step 3: Change the encoder**

In `protocol.gleam`, add the import `import dh_server/loadout` if absent, then:

```gleam
/// Serialize a world snapshot. Each ship is paired with its APPEARANCE — the
/// hull art key and the part sprite key on each fitted mount — so a client can
/// always draw any ship it can see, with no separate appearance message to
/// miss and no parts catalog of its own.
pub fn encode_snapshot(
  tick: Int,
  ships: List(#(Ship, loadout.Appearance)),
) -> String {
  json.object([
    #("v", json.int(version)),
    #("type", json.string("snapshot")),
    #("tick", json.int(tick)),
    #("ships", json.preprocessed_array(list.map(ships, encode_ship))),
  ])
  |> json.to_string
}

fn encode_ship(entry: #(Ship, loadout.Appearance)) -> Json {
  let #(s, look) = entry
  json.object([
    #("id", json.int(s.id)),
    #("x", json.float(s.x)),
    #("y", json.float(s.y)),
    #("vx", json.float(s.vx)),
    #("vy", json.float(s.vy)),
    #("heading", json.float(s.heading)),
    #("thrust", json.float(s.controls.thrust)),
    #("docked", encode_docked(s.dock)),
    #("berth", encode_berth_index(s.dock)),
    #("hull", json.string(look.hull_sprite)),
    #("mounts", json.object(list.map(look.mounts, fn(m) {
      #(m.0, json.string(m.1))
    }))),
  ])
}
```

- [ ] **Step 4: Update the protocol doc comment**

Replace `protocol.gleam:37-41` with:

```gleam
\   {"v":1,"type":"snapshot","tick":N,
\    "ships":[{"id","x","y","vx","vy","heading","thrust","docked",
\              "berth","hull","mounts"}...]} — "berth" is the claimed berth
\   index while docked (null while flying), so the client parks each moored
\   hull at its own berth anchor (the same berth the server releases it at on
\   undock). "hull" is the ship's ART DIRECTORY key and "mounts" maps each
\   FITTED mount id to that part's SPRITE key — sprite keys, never part ids,
\   because the client has no parts catalog. Both change only on refit; they
\   ride the snapshot anyway so a client can draw any ship it can see without
\   a separate appearance message to miss. An unfitted mount is absent, and
\   the hull's blanking plate shows through.
```

- [ ] **Step 5: Fix the sim call site**

At `sim.gleam:1971`, replace

```gleam
      let snapshot = protocol.encode_snapshot(tick, ships)
```

with

```gleam
      let snapshot = protocol.encode_snapshot(tick, with_appearance(ships, state.fits))
```

and add this helper beside `broadcast_cargo`:

```gleam
/// Pair every ship with its fit's appearance. A ship with no fit should be
/// unreachable (spawn resolves or refuses; `prune_fits` only drops dead
/// ships), but if it happens she still appears in the snapshot wearing an
/// EMPTY appearance — a missing fit must never make a hull vanish from the
/// world.
fn with_appearance(
  ships: List(Ship),
  fits: List(#(Int, loadout.Fit)),
) -> List(#(Ship, loadout.Appearance)) {
  list.map(ships, fn(s) {
    case list.find(fits, fn(entry) { entry.0 == s.id }) {
      Ok(#(_, fit)) -> #(s, fit.appearance)
      Error(Nil) -> #(s, loadout.Appearance(hull_sprite: "", mounts: []))
    }
  })
}
```

- [ ] **Step 6: Fix `dh_server_test.gleam:93`**

`protocol.encode_snapshot(42, [])` still compiles (an empty list of pairs). Confirm, and leave it.

- [ ] **Step 7: Run the Gleam suite**

Run: `cd server; gleam test`
Expected: PASS.

- [ ] **Step 8: Teach the harness validator**

In `harness/dh_client.py`, extend `validate_snapshot`'s per-ship loop:

```python
    for ship in ships:
        if not isinstance(ship.get("id"), int):
            raise ProtocolError(f"ship id missing/bad: {ship!r}")
        for key in ("x", "y", "vx", "vy"):
            value = ship.get(key)
            if not isinstance(value, (int, float)):
                raise ProtocolError(f"ship {ship.get('id')} field {key!r} bad: {value!r}")
        if not isinstance(ship.get("hull"), str):
            raise ProtocolError(f"ship {ship.get('id')} 'hull' missing/bad: {ship!r}")
        mounts = ship.get("mounts")
        if not isinstance(mounts, dict):
            raise ProtocolError(f"ship {ship.get('id')} 'mounts' is not an object: {ship!r}")
        for mount_id, sprite in mounts.items():
            if not isinstance(sprite, str):
                raise ProtocolError(
                    f"ship {ship.get('id')} mount {mount_id!r} sprite bad: {sprite!r}")
```

- [ ] **Step 9: Add a harness test that a real server sends it**

Append to `harness/test_m4_refit.py`:

```python
@pytest.mark.asyncio
async def test_snapshot_carries_hull_and_fitted_mounts(server):
    """The wire's appearance channel: hull art key + fitted mount sprite keys."""
    async with DHClient() as client:
        await client.login("appearance_probe", "dev")
        snapshot = await client.next_snapshot()
        validate_snapshot(snapshot, expected_ships=1)
        ship = snapshot["ships"][0]
        assert ship["hull"] == "mockingbird"
        # Her lore default: a Consol centre between two Rijay originals.
        assert ship["mounts"] == {
            "engine_port": "engine_rijay",
            "engine_center": "engine_consol",
            "engine_stbd": "engine_rijay",
        }
```

Match the file's existing fixture/import idiom (`server`, `DHClient`, `validate_snapshot`) rather than inventing one.

- [ ] **Step 10: Run the harness**

Run: `cd harness; python -m pytest -q`
Expected: PASS, 31 tests.

- [ ] **Step 11: Commit**

```bash
git add server/src/dh_server/protocol.gleam server/src/dh_server/sim.gleam server/test harness/dh_client.py harness/test_m4_refit.py
git commit -m "feat(protocol): the snapshot carries each ship's hull and fitted mounts (#M4)"
```

---

### Task 4: The client stops assuming every hull is a Mockingbird

**Files:**
- Modify: `client/scripts/ship_state.gd`
- Modify: `client/scripts/asset_library.gd:11-14`, `:61-82`
- Modify: `client/scripts/world_view.gd:296`, `:374`, `:389-409`, `:412-444`
- Modify: `client/scripts/main.gd:556-583`

**Interfaces:**
- Consumes: the wire fields from Task 3.
- Produces:
  - `ShipState.hull_sprite: String` and `ShipState.mounts: Dictionary` (mount id → sprite key).
  - `AssetLibrary.ship(kind)` now resolves any directory under `assets/ships/`.
  - `WorldView` and `main.gd` select art per ship.

This task changes *which hull sprite* is drawn. Part layering is Task 8 — after this, the Sparrow and Goldfinch will fail to find art and draw nothing, which is correct and temporary (their art is Tasks 12–13). The Mockingbird is unaffected.

- [ ] **Step 1: Decode the new fields**

In `client/scripts/ship_state.gd`, add to the members:

```gdscript
## Art directory key for this ship's hull, from the snapshot. The client
## has no parts catalog, so the wire hands over sprite keys directly.
var hull_sprite: String = ""
## Fitted mount id -> part sprite key. An unfitted mount is simply absent
## and the hull's blanking plate shows through.
var mounts: Dictionary = {}
```

In `from_dict`, before `return ship`:

```gdscript
	ship.hull_sprite = str(data.get("hull", ""))
	var mounts: Variant = data.get("mounts")
	if mounts is Dictionary:
		for mount_id: Variant in mounts:
			ship.mounts[str(mount_id)] = str(mounts[mount_id])
```

In `extrapolated()`, carry both across:

```gdscript
	out.hull_sprite = hull_sprite
	out.mounts = mounts
```

- [ ] **Step 2: Enumerate asset directories instead of a hardcoded list**

In `client/scripts/asset_library.gd`, delete the `SHIP_KINDS` constant (lines 11–12) and replace the ship-loading loop in `load_all` with:

```gdscript
	for kind: String in DirAccess.get_directories_at(root + "/ships"):
		lib._ships[kind] = lib._load_set(root + "/ships/" + kind)
```

Update the class doc comment's first paragraph to say the ship set is discovered from the directory tree rather than listed.

- [ ] **Step 3: Draw each flying ship with her own hull**

In `world_view.gd::_update_ship_sprites` (line 412), delete the hoisted

```gdscript
	var sset := _lib.ship("mockingbird")  # every hull is a Mockingbird until M4
	if sset == null:
		return
	var is_pip := _ship_is_pip(sset, view_scale)
```

and move the lookup inside the per-ship loop, immediately after the `interior_mode` skip:

```gdscript
		var sset := _lib.ship(ship.hull_sprite)
		if sset == null:
			continue  # no art for this hull yet
		var is_pip := _ship_is_pip(sset, view_scale)
```

- [ ] **Step 4: Park moored ships in their own hulls**

In `_update_parked_ships` (line 354), change the real-ship call from

```gdscript
		_park_sprite(station_sprite, "parked_%d" % ship.id, "mockingbird",
			berth_anchors[idx] - half, units_per_px, -ship.heading + PI / 2)
```

to pass `ship.hull_sprite`. Leave the decorative Longhorn call at line 383 exactly as it is — she has no server ship and no hull document.

- [ ] **Step 5: Fix `matched_zoom_ship`**

`matched_zoom_ship` (line 295) hardcodes `"mockingbird"` for THE WINDOW's matched zoom. Give it the own ship's hull:

```gdscript
## Ship-scale matched zoom (aboard a flying hull). `hull_sprite` is the hull
## we are aboard; `fallback` when its art is unknown.
func matched_zoom_ship(hull_sprite: String, fallback: float) -> float:
	var sset := _lib.ship(hull_sprite)
	if sset == null or not sset.has_interior_fit():
		return fallback
```

Then update every caller in `main.gd` (grep `matched_zoom_ship`) to pass the own ship's `hull_sprite`, falling back to `""` when the own ship isn't in the last snapshot yet.

- [ ] **Step 6: Per-ship interior backdrops**

In `main.gd::_interior_backdrops` (line 560), replace the three hardcoded `"mockingbird_interior"` strings. Add a helper above it:

```gdscript
## The walk-mode backdrop asset for a ship id: her hull's art directory with
## the `_interior` suffix (the 2x render). "" when we have no snapshot entry
## for her yet.
func _interior_asset_for(ship_id: int) -> String:
	for ship in _ships:
		if ship.id == ship_id and ship.hull_sprite != "":
			return ship.hull_sprite + "_interior"
	return ""
```

Use `_interior_asset_for(_own_ship_id)` for the two own-ship branches (lines 565 and 582) and `_interior_asset_for(mooring.ship_id)` for the moored loop (line 578); skip a backdrop whose asset resolves to `""`. Update the function's doc comment — delete "Every hull is a Mockingbird until M4."

(Use whatever the file already calls its snapshot ship array and own-ship id; grep for `_ships` and `_own_ship_id` and match.)

- [ ] **Step 7: Launch and check nothing regressed**

Run the server and client:

```powershell
$env:Path = "$env:USERPROFILE\scoop\shims;$env:Path"
cd server; gleam run
# in another shell:
godot --path client -- --username=<you> --password=dev
```

Expected: the Mockingbird looks and behaves exactly as before — flying, parked at a berth, and as the walk backdrop. Nothing about her art has changed yet.

- [ ] **Step 8: Commit**

```bash
git add client/scripts
git commit -m "feat(client): every ship wears her own hull's art (#M4)"
```

---

### Task 5: Named mount anchors

**Files:**
- Modify: `tools/artspike/composer.py:58-63` (`Anchor`), `:330-339` (meta emission)
- Modify: `tools/artspike/manufacturers.py:275-296` (`mb_drums`), `:157-177` (`ship_longhorn`)
- Modify: `tools/artspike/test_composer.py:18-34`
- Create: `harness/test_m4_exterior.py`

**Interfaces:**
- Consumes: `hull.Hull.mounts` ids (`engine_port`, `engine_center`, `engine_stbd`) from Task 1's hull documents.
- Produces: `meta.json` `anchors` entries of the form `{"kind": "mount", "id": "engine_port", "x_px": F, "y_px": F}`, replacing `{"kind": "nozzle", …}`. `Anchor` gains `id: str = ""`.

The Mockingbird's drums are still baked into her hull here. This task only *names* the anchors, so the geometry contract lands before anything depends on it.

- [ ] **Step 1: Write the failing artspike test**

In `tools/artspike/test_composer.py`, replace the nozzle assertion in `test_mockingbird_is_hull_with_heights` (line 23) with:

```python
    mounts = {a.id for a in hull.anchors if a.kind == "mount"}
    assert mounts == {"engine_port", "engine_center", "engine_stbd"}
```

and in `test_longhorn_foil_is_flat_plate` (line 34) with:

```python
    assert len([a for a in hull.anchors if a.kind == "mount"]) == 2
```

Add a new test:

```python
def test_mount_anchors_are_ordered_port_to_starboard():
    """Ids are the contract, but a reader should still be able to trust the
    left-to-right order in the file."""
    from manufacturers import ship_mockingbird
    ids = [a.id for a in ship_mockingbird().anchors if a.kind == "mount"]
    assert ids == ["engine_port", "engine_center", "engine_stbd"]
```

- [ ] **Step 2: Run to verify it fails**

Run: `python -m pytest tools/artspike -q`
Expected: FAIL — `Anchor` has no attribute `id`.

- [ ] **Step 3: Give `Anchor` an id**

In `composer.py`:

```python
@dataclass(frozen=True)
class Anchor:
    kind: str            # "mount" (a hull hardpoint) | "berth" (a station slot)
    x: float             # model units
    y: float
    id: str = ""         # mount anchors only: the hull document's mount id.
                         # NAMED, not indexed — reordering a build loop must
                         # never silently swap two engines.
```

and in `export_ship`'s meta emission, carry the id through:

```python
        "anchors": [{"kind": a.kind, "id": a.id,
                     "x_px": (a.x - frame[0]) * px_per_unit,
                     "y_px": (a.y - frame[1]) * px_per_unit}
                    for a in hull.anchors],
```

- [ ] **Step 4: Name the Mockingbird's three**

In `manufacturers.py::mb_drums`, replace the loop head and the anchor append:

```python
    y, r, ln = MB_Y, MB_R, MB_LN
    layers, anchors = [], []
    for i, mount_id in ((-1, "engine_port"), (0, "engine_center"),
                        (1, "engine_stbd")):
        cx = i * MB_SP
```

…and at the end of the loop body:

```python
        anchors.append(Anchor("mount", cx, y + ln + 3.5, id=mount_id))
```

- [ ] **Step 5: Name the Longhorn's two**

In `ship_longhorn`, the loop runs `for sx in (-1, 1)`. Replace `A.append(Anchor("nozzle", sx * 40, 52))` with:

```python
        A.append(Anchor("mount", sx * 40, 52,
                        id="engine_port" if sx < 0 else "engine_stbd"))
```

The Longhorn is decorative parked traffic with no hull document, so these ids are documentation, not a contract — say so in a comment.

- [ ] **Step 6: Update the client's anchor reader**

`asset_library.gd::SpriteSet.anchors(kind)` (line 28) keeps working for `"berth"`. Add beside it:

```gdscript
	## Texture-pixel position of the mount anchor named `mount_id`, or
	## Vector2.INF when this sprite has none — a fitted mount with no anchor
	## is a data bug in one of two trees, so the caller push_errors rather
	## than guessing a position.
	func mount_anchor(mount_id: String) -> Vector2:
		for a: Variant in meta.get("anchors", []):
			if a is Dictionary and str(a.get("kind", "")) == "mount" \
					and str(a.get("id", "")) == mount_id:
				return Vector2(float(a["x_px"]), float(a["y_px"]))
		return Vector2.INF
```

- [ ] **Step 7: Re-export and verify the meta**

Run: `python tools/artspike/composer.py`
Then read `client/assets/ships/mockingbird/meta.json` and confirm three `{"kind":"mount","id":…}` entries with the same `x_px`/`y_px` the `nozzle` entries had.

- [ ] **Step 8: Write the cross-tree harness test**

Create `harness/test_m4_exterior.py`:

```python
"""Cross-tree consistency for M4 iteration 2c's exterior layering.

The server owns a mount's CAPABILITY (`{id, kind, size}`); the art meta owns
its GEOMETRY (a named anchor). Nothing compiles across that boundary, so
these tests are the whole defence against a mount id typo'd in one tree —
which renders as a part that silently does not draw.
"""
import json
import pathlib

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SHIPCLASSES = ROOT / "server" / "shipclasses"
SHIP_ART = ROOT / "client" / "assets" / "ships"


def _hulls_with_art():
    for path in sorted(SHIPCLASSES.glob("*.json")):
        doc = json.loads(path.read_text(encoding="utf-8"))
        sprite = doc.get("sprite", doc["id"])
        meta = SHIP_ART / sprite / "meta.json"
        if meta.exists():
            yield doc["id"], doc, json.loads(meta.read_text(encoding="utf-8"))


def test_every_shipped_hull_has_art():
    ids = {h for h, _, _ in _hulls_with_art()}
    assert ids == {"mockingbird", "sparrow", "goldfinch"}


@pytest.mark.parametrize("hull_id", ["mockingbird", "sparrow", "goldfinch"])
def test_mount_ids_match_anchor_ids(hull_id):
    hulls = {h: (doc, meta) for h, doc, meta in _hulls_with_art()}
    doc, meta = hulls[hull_id]
    declared = {m["id"] for m in doc.get("mounts", [])}
    drawn = {a["id"] for a in meta.get("anchors", []) if a.get("kind") == "mount"}
    assert declared == drawn, (
        f"{hull_id}: hull document declares {sorted(declared)}, "
        f"sprite meta draws {sorted(drawn)}")
```

`test_every_shipped_hull_has_art` and the `sparrow`/`goldfinch` parametrisations **will fail until Tasks 12 and 13** land their art. Mark them so the suite stays green in between:

```python
pytestmark = pytest.mark.xfail(
    not (SHIP_ART / "sparrow").exists(),
    reason="Sparrow and Goldfinch exterior art land in tasks 12-13",
    strict=False)
```

Remove that `pytestmark` in Task 13's final step.

- [ ] **Step 9: Run both suites**

Run: `python -m pytest tools/artspike -q` — Expected: PASS.
Run: `cd harness; python -m pytest -q` — Expected: PASS (Sparrow/Goldfinch xfail).

- [ ] **Step 10: Commit**

```bash
git add tools/artspike client/assets/ships client/scripts/asset_library.gd harness/test_m4_exterior.py
git commit -m "feat(artspike): mount anchors are named, not indexed (#M4)"
```

---

### Task 6: Part sprites export through the same pipeline

**Files:**
- Modify: `tools/artspike/composer.py:207-273` (`ExportSpec`, `SHIP_EXPORTS`), `:306-351` (`export_ship`), `:446-457` (`main`)
- Modify: `tools/artspike/manufacturers.py` (add `part_engine_rijay`)
- Modify: `tools/artspike/test_composer.py`
- Create: `client/assets/parts/engine_rijay/{albedo,normal,mask}.png`, `meta.json` (generated)

**Interfaces:**
- Consumes: `Anchor` with `id` (Task 5).
- Produces:
  - `PartSpec(name, build, classic_px, model_units, c1, c2, palette, c1_base, c2_base)` and `PART_EXPORTS` in `composer.py`.
  - `export_part(spec, out_root) -> dict` writing `client/assets/parts/<name>/`.
  - Part `meta.json` carries `px_w`, `px_h`, `px_per_unit`, `c1_base`, `c2_base`, and `attach_px: [x, y]` — the point that lands on the hull's mount anchor.
  - `manufacturers.part_engine_rijay() -> Hull` — the drum with its dorsal ridge, carrying one `Anchor("attach", …)`.

- [ ] **Step 1: Write the failing test**

Append to `tools/artspike/test_composer.py`:

```python
def test_rijay_engine_part_has_one_attach_anchor():
    from manufacturers import part_engine_rijay
    part = part_engine_rijay()
    attach = [a for a in part.anchors if a.kind == "attach"]
    assert len(attach) == 1, "a part attaches at exactly one point"
    assert any(l.height is not None for l in part.layers), "authored relief"


def test_parts_and_hulls_share_one_base_px_per_unit():
    """The scale canon: a part drawn on a hull must not need rescaling. The
    2x `*_interior` renders double classic_px AND px_scale, so it is the BASE
    ratio (classic_px / model_units / px_scale) that must be universal —
    exactly the quantity export_ship calls base_ppu."""
    from composer import PART_EXPORTS, SHIP_EXPORTS

    def base(s):
        return s.classic_px / s.model_units / s.px_scale

    ratios = {base(s) for s in SHIP_EXPORTS} | {base(p) for p in PART_EXPORTS}
    assert len(ratios) == 1, f"multiple scales in play: {ratios}"
```

- [ ] **Step 2: Run to verify it fails**

Run: `python -m pytest tools/artspike -q`
Expected: FAIL — `cannot import name 'part_engine_rijay'`.

- [ ] **Step 3: Author the Rijay drum as a part**

In `manufacturers.py`, add above `ship_mockingbird`. This is `mb_drums`' single-drum body re-centred on the origin, **plus the dorsal ridge**, which is a drum fairing (the atmo-landing package) and travels with the engine:

```python
def part_engine_rijay():
    """The Rijay drum — Stork 240-C2. Authored at the ORIGIN with its attach
    point at the drum's fore face, so the composer can place it against any
    hull's mount anchor. The dorsal ridge comes with it: the MB_FL fin is a
    drum fairing, not ship structure, which is why a Consol nacelle reads as
    visibly aftermarket with no extra art."""
    r, ln, fl = MB_R, MB_LN, MB_FL
    layers = [
        Layer(rrect(-r, 0, 2 * r, ln, r * .95, RIJ_BLUE, sw=2.2),
              cyl_x(0.40, 0.78)),
        Layer(rrect(-r * .72, ln - 2.5, r * 1.44, 5.5, 2.2, RIJ_BLUE_D,
                    sw=1.6), cyl_x(0.38, 0.60)),
        # dorsal ridge: thin from above, runs the drum and overhangs aft
        Layer(poly([(0, 3), (1.9, 8), (1.9, ln - 2), (1.2, ln + 7 * fl),
                    (0, ln + 9 * fl), (-1.2, ln + 7 * fl), (-1.9, ln - 2),
                    (-1.9, 8)], RIJ_WHITE, stroke=INK, sw=1.0), flat(0.82)),
        Layer(f'<ellipse cx="0" cy="{ln + 8:.1f}" rx="{r * .85:.1f}" '
              f'ry="10" fill="url(#glow)"/>', role="glow"),
        Layer(f'<ellipse cx="0" cy="{ln + 3.5:.1f}" rx="{r * .5:.1f}" '
              f'ry="5.5" fill="{GLOW_CORE}" stroke="none"/>', role="glow"),
    ]
    # The attach point is the drum's fore face on its centreline — it lands
    # on the hull's mount anchor.
    return Hull(layers=layers, anchors=[Anchor("attach", 0.0, 0.0)])
```

- [ ] **Step 4: Add `PartSpec` and `export_part`**

In `composer.py`, after `ExportSpec`:

```python
@dataclass(frozen=True)
class PartSpec:
    """An exterior part exported on its own, to be layered onto a hull at a
    named mount anchor. Shares the hulls' px_per_unit so the client needs no
    per-part scale correction — see the scale canon on ExportSpec.

    px_scale mirrors ExportSpec's: a hull's `*_interior` render is 2x, and a
    part layered onto it must be too, so every part ships a 1x twin for space
    and a 2x `<name>_interior` twin for the walk-mode backdrop."""
    name: str                     # the part document's `sprite` key
    build: object                 # () -> Hull, carrying one "attach" Anchor
    classic_px: int
    model_units: int
    c1: tuple
    c2: tuple
    palette: tuple
    c1_base: tuple
    c2_base: tuple
    px_scale: int = 1


def _rijay_part(name, fn_name, px_scale=1):
    return PartSpec(name, lambda: _part(fn_name), 45 * px_scale, 195,
                    ((59, 141, 224),), ((238, 242, 246),),
                    tuple(RIJAY_PALETTE), RIJ_C1, RIJ_C2, px_scale=px_scale)


PART_EXPORTS = [
    _rijay_part("engine_rijay", "part_engine_rijay"),
    _rijay_part("engine_rijay_interior", "part_engine_rijay", px_scale=2),
]


def _part(fn_name):
    import manufacturers
    return getattr(manufacturers, fn_name)()
```

and after `export_ship`:

```python
def export_part(spec, out_root, z_scale=6.5):
    """Same compose/downsample/normal recipe as export_ship, but the meta
    carries an ATTACH point instead of anchors and an interior fit: the part
    is positioned so this pixel lands on its hull's mount anchor."""
    c = compose_ship(spec)
    frame, hull = c["frame"], c["hull"]
    px_per_unit = spec.classic_px / spec.model_units
    # Same rounding contract as export_ship: dims round at the BASE scale then
    # multiply, so a 2x twin is exactly double its 1x and the attach point
    # cannot drift a pixel.
    base_ppu = px_per_unit / spec.px_scale
    pw = max(1, round(frame[2] * base_ppu)) * spec.px_scale
    ph = max(1, round(frame[3] * base_ppu)) * spec.px_scale
    albedo_g = _downsample(c["albedo"], (pw, ph), "rgba")
    height_g = _downsample(c["height"], (pw, ph), "f")
    solid_g = _downsample(c["solid"].astype(np.float64), (pw, ph), "f") > 0.5
    normals = height_to_normals(height_g, z_scale=z_scale / SS)
    normals[~solid_g] = [0.0, 0.0, 1.0]
    mask_g = np.dstack([_downsample(c["masks"][..., i], (pw, ph), "f")
                        for i in (0, 1)] + [np.zeros((ph, pw))])
    out = pathlib.Path(out_root) / spec.name
    out.mkdir(parents=True, exist_ok=True)
    Image.fromarray((np.clip(albedo_g, 0, 1) * 255).astype(np.uint8),
                    "RGBA").save(out / "albedo.png")
    n = normals.copy()
    n[..., 1] *= -1.0
    Image.fromarray(np.round((n + 1) / 2 * 255).astype(np.uint8), "RGB").save(
        out / "normal.png")
    Image.fromarray((np.clip(mask_g, 0, 1) * 255).astype(np.uint8),
                    "RGB").save(out / "mask.png")
    attach = [a for a in hull.anchors if a.kind == "attach"]
    if len(attach) != 1:
        raise ValueError(f"{spec.name}: expected exactly one attach anchor, "
                         f"got {len(attach)}")
    a = attach[0]
    meta = {
        "name": spec.name, "px_w": pw, "px_h": ph,
        "px_per_unit": px_per_unit, "frame": list(frame),
        "classic_px": spec.classic_px,
        "c1_base": list(spec.c1_base), "c2_base": list(spec.c2_base),
        "attach_px": [(a.x - frame[0]) * px_per_unit,
                      (a.y - frame[1]) * px_per_unit],
    }
    (out / "meta.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")
    return meta
```

`compose_ship` reads only `spec.build`, `spec.c1`, `spec.c2` and `spec.palette`, so it works on a `PartSpec` unchanged. Add a one-line comment on `compose_ship` saying so.

- [ ] **Step 5: Export parts from `main()`**

```python
def main():
    root = pathlib.Path(__file__).parents[2]
    out_root = root / "client" / "assets" / "ships"
    for spec in SHIP_EXPORTS:
        meta = export_ship(spec, out_root)
        print(f"exported {spec.name}: {meta['px_w']}x{meta['px_h']} px, "
              f"{len(meta['anchors'])} anchors")
    part_root = root / "client" / "assets" / "parts"
    for spec in PART_EXPORTS:
        meta = export_part(spec, part_root)
        print(f"exported part {spec.name}: {meta['px_w']}x{meta['px_h']} px, "
              f"attach {meta['attach_px']}")
    build_debug_sheet(pathlib.Path(__file__).parent / "sheet_composer.png")
```

- [ ] **Step 6: Run the export and the tests**

Run: `python tools/artspike/composer.py`
Then: `python -m pytest tools/artspike -q`
Expected: PASS. `client/assets/parts/engine_rijay/` now holds four files.

- [ ] **Step 7: Add a harness check that every part document's sprite resolves**

Append to `harness/test_m4_exterior.py`:

```python
PARTS = ROOT / "server" / "parts"
PART_ART = ROOT / "client" / "assets" / "parts"


def test_every_part_sprite_key_has_art():
    """A part document's `sprite` is what rides the wire; if the directory is
    missing the client draws nothing and the mount looks unfitted."""
    missing = []
    for path in sorted(PARTS.glob("*.json")):
        doc = json.loads(path.read_text(encoding="utf-8"))
        sprite = doc.get("sprite")
        if sprite is None:
            continue
        art = PART_ART / sprite
        for f in ("albedo.png", "normal.png", "mask.png", "meta.json"):
            if not (art / f).exists():
                missing.append(f"{doc['id']} -> {sprite}/{f}")
    assert not missing, "part art missing: " + ", ".join(missing)
```

This fails until Task 7 (`engine_consol`) and Task 11 (`engine_rijay_small`). Guard just this one test until then, and drop the decorator in Task 11:

```python
@pytest.mark.xfail(
    not (PART_ART / "engine_rijay_small").exists(),
    reason="engine_consol lands in task 7, engine_rijay_small in task 11",
    strict=False)
def test_every_part_sprite_key_has_art():
```

Note the module-level `pytestmark` from Step 8 of Task 5 also applies to this test; that is fine — both guards lift before the branch merges.

- [ ] **Step 8: Commit**

```bash
git add tools/artspike client/assets/parts harness/test_m4_exterior.py
git commit -m "feat(artspike): exterior parts export as standalone sprites (#M4)"
```

---

### Task 7: The Mockingbird's stern re-cut

**Files:**
- Modify: `tools/artspike/manufacturers.py:275-296` (`mb_drums` → deleted), `:298-326` (fins), `:355-394` (`ship_mockingbird`), `:488+` (`build_sheet` slots)
- Modify: `tools/artspike/composer.py:248-273` (`MB_INTERIOR` comment, `SHIP_EXPORTS`, `PART_EXPORTS`)
- Modify: `tools/artspike/test_composer.py`
- Delete: `client/assets/ships/mockingbird_stock/`
- Regenerate: `tools/artspike/sheet_mfr.svg`, `sheet_mfr.png`, `sheet_composer.png`, `client/assets/ships/mockingbird*/`

**Interfaces:**
- Consumes: `PartSpec`/`export_part` (Task 6).
- Produces: `manufacturers.part_engine_consol() -> Hull`; a Mockingbird hull with no drums, three blanking plates, and three named mount anchors; `mockingbird_stock` gone.

**This is the silhouette change.** Read the spec's "The Mockingbird's stern" section before starting.

- [ ] **Step 1: Write the failing tests**

In `tools/artspike/test_composer.py`, add:

```python
def test_mockingbird_hull_no_longer_draws_her_drums():
    """The drums are a PART now. What stays on the hull is a blanking plate
    per mount, which a fitted part covers."""
    from manufacturers import ship_mockingbird
    hull = ship_mockingbird()
    # The drums were the only cyl_x layers on the hull.
    assert not [l for l in hull.layers if l.height and l.height.kind == "cyl_x"]
    assert not [l for l in hull.layers if l.role == "glow"], \
        "engine glow belongs to the engine part"
    mounts = {a.id for a in hull.anchors if a.kind == "mount"}
    assert mounts == {"engine_port", "engine_center", "engine_stbd"}


def test_consol_engine_has_no_dorsal_ridge():
    """The lore default renders as visibly aftermarket for free: the ridge is
    a Rijay drum fairing, so the Consol nacelle simply lacks one."""
    from manufacturers import part_engine_consol, part_engine_rijay
    consol = len([l for l in part_engine_consol().layers
                  if l.height and l.height.kind == "flat"])
    rijay = len([l for l in part_engine_rijay().layers
                 if l.height and l.height.kind == "flat"])
    assert rijay > consol
```

- [ ] **Step 2: Run to verify it fails**

Run: `python -m pytest tools/artspike -q`
Expected: FAIL on both.

- [ ] **Step 3: Delete `mb_drums`, add blanking plates**

Remove `mb_drums` entirely. Add in its place:

```python
def mb_mount_plates():
    """-> (layers, mount anchors). Structure stays with the hull, equipment
    goes on the part: each hardpoint is a faired-over plate on the transom
    that a fitted engine covers, so an EMPTY mount still reads deliberate.
    The Sparrow needs this immediately — she ships engine_center bare."""
    y, r = MB_Y, MB_R
    layers, anchors = [], []
    for i, mount_id in ((-1, "engine_port"), (0, "engine_center"),
                        (1, "engine_stbd")):
        cx = i * MB_SP
        layers.append(Layer(rrect(cx - r * .82, y - 1.5, r * 1.64, 6.0, 2.0,
                                  RIJ_BLUE_D, sw=1.6), flat(0.30)))
        for by in (y + 0.6, y + 3.4):   # bolt ring
            layers.append(Layer(circle(cx - r * .5, by, .7, INK,
                                       stroke="none")))
            layers.append(Layer(circle(cx + r * .5, by, .7, INK,
                                       stroke="none")))
        anchors.append(Anchor("mount", cx, y, id=mount_id))
    return layers, anchors
```

Note the anchor y moves from `y + ln + 3.5` (the old nozzle mouth, deep in the drum) to `y` (the transom face) — that is the point a part's `attach` lands on, and `part_engine_rijay` is authored with its attach at the drum's fore face for exactly this reason.

- [ ] **Step 4: Re-root the outboard fin on the hull's flare**

In `mb_outboard_fins`, the wing is currently rooted at the drum centre and spans `y+16 → y+ln`, past the hull's stern at `y=62`. It is a wing, not a drive fairing, and only the outer two drums ever carried one — so it stays hull and moves inboard:

```python
def mb_outboard_fins():
    y, r, fl = MB_Y, MB_R, MB_FL
    layers = []
    for sx in (-1, 1):  # rooted on the stern flare, inside the transom
        root = sx * MB_SP
        tips = [(root + sx * (r + 8.5 * fl), y + 7),
                (root + sx * (r + 9.5 * fl), y + 17),
                (root + sx * (r + 5.5 * fl), y + 19)]
        layers.append(Layer(poly([(root, y - 6)] + tips + [(root, y + 19)],
                                 RIJ_BLUE, sw=1.8), flat(0.33)))
        edge = " L ".join(f"{x - sx * 2.2:.1f},{yy + .8:.1f}" for x, yy in tips)
        layers.append(Layer(
            f'<path d="{edge and "M " + edge}" fill="none" stroke="{RIJ_WHITE}" '
            f'stroke-width="2" stroke-linecap="round" '
            f'stroke-linejoin="round" opacity=".95"/>'))
    return layers
```

Delete `mb_dorsal_fins` — the ridge lives on `part_engine_rijay` now.

- [ ] **Step 5: Rewire `ship_mockingbird`**

```python
def ship_mockingbird():
    """Rijay's flagship and the game's starter ship. See canon block above.
    Returns a Hull: ordered lit-pipeline layers with authored heights. Her
    ENGINES are not here — they are parts, layered at her mount anchors by
    the client (M4 iteration 2c). `stock` is gone with them: finned vs
    finless is a part distinction now."""
    layers = mb_outboard_fins()
```

…keep the body/stripe/port/canopy layers exactly as they are, then replace the drum block at the end with:

```python
    plate_layers, anchors = mb_mount_plates()
    layers += plate_layers
    layers += mb_ports()
    layers += mb_canopy()
    return Hull(layers=layers, anchors=anchors)
```

Drop the `stock` parameter and every `if stock:` branch. Update the canon comment block above `MB_Y` — delete the "stock=True renders the workaday finless bird" sentence and the fin-count sentence, and say the drums are a part.

- [ ] **Step 6: Author the Consol engine**

```python
def part_engine_consol():
    """Consolidated CO-17F Block 2 — the aftermarket nacelle in the starter
    Mockingbird's centre mount. Consol grey-orange, squarer than a Rijay drum,
    and NO dorsal ridge: that ridge is a Rijay fairing, so a mixed fit reads
    as mixed on sight. Keeps its maker's colours rather than taking the
    ship's livery."""
    w, ln = MB_R * 1.75, MB_LN * 0.92
    layers = [
        Layer(rrect(-w / 2, 0, w, ln, 2.5, PHE_POD, sw=2.2), cyl_x(0.36, 0.70)),
        Layer(rrect(-w / 2 + 3, 3, w - 6, ln * .26, 1.5, PHE_POD_D,
                    stroke="none")),
        Layer(poly([(-w * .3, ln), (w * .3, ln), (w * .38, ln + 7),
                    (-w * .38, ln + 7)], PHE_GRAY_D, sw=1.8), flat(0.34)),
        Layer(f'<ellipse cx="0" cy="{ln + 9:.1f}" rx="{w * .42:.1f}" '
              f'ry="9" fill="url(#glow)"/>', role="glow"),
        Layer(f'<ellipse cx="0" cy="{ln + 5:.1f}" rx="{w * .26:.1f}" '
              f'ry="5" fill="{GLOW_CORE}" stroke="none"/>', role="glow"),
    ]
    return Hull(layers=layers, anchors=[Anchor("attach", 0.0, 0.0)])
```

Add a Consol-livery helper beside `_rijay_part` in `composer.py`, and both twins to `PART_EXPORTS`:

```python
def _consol_part(name, fn_name, px_scale=1):
    return PartSpec(name, lambda: _part(fn_name), 45 * px_scale, 195,
                    ((217, 122, 40), (168, 90, 30)),
                    ((138, 143, 151), (223, 227, 230)),
                    tuple(PHE_PALETTE), PHE_C1, (138, 143, 151),
                    px_scale=px_scale)
```

```python
    _consol_part("engine_consol", "part_engine_consol"),
    _consol_part("engine_consol_interior", "part_engine_consol", px_scale=2),
```

The Consol keeps its maker's colours rather than taking the ship's livery — that is the whole point of the mixed fit reading as mixed.

- [ ] **Step 7: Drop `mockingbird_stock` and fix the stale comment**

In `composer.py`:
- Delete the `ExportSpec("mockingbird_stock", …)` entry.
- Change `_mb(stock)` to a no-arg `_mb()` and the two remaining specs' `build` lambdas to match.
- Fix `MB_INTERIOR`'s comment: it says "The deckplan grid (14x20)", stale since the 2a carve. She is **14 × 23** walkable in a 30-tile-long sprite.

Then `git rm -r client/assets/ships/mockingbird_stock`.

- [ ] **Step 8: Re-export everything and regenerate the sheet canon**

```powershell
python tools/artspike/composer.py
python -c "import sys; sys.path.insert(0,'tools/artspike'); import manufacturers, pathlib; pathlib.Path('tools/artspike/sheet_mfr.svg').write_text(manufacturers.build_sheet(), encoding='utf-8')"
```

`test_sheet_mfr_render_identical` locks `sheet_mfr.svg` byte-for-byte to protect the locked Mockingbird through *refactors*. This is a deliberate art change, so the canon is regenerated on purpose — note that in the commit message. Re-render `sheet_mfr.png` with whatever `manufacturers.py`'s `__main__` block already does.

- [ ] **Step 9: Run the tests**

Run: `python -m pytest tools/artspike -q`
Expected: PASS.
Run: `cd harness; python -m pytest -q`
Expected: PASS — `test_mount_ids_match_anchor_ids[mockingbird]` now exercises the plates' anchors.

- [ ] **Step 10: Eyeball the sheet**

Open `tools/artspike/sheet_mfr.png` and `sheet_composer.png`. Confirm: the Mockingbird's transom carries three plates and no drums; the outboard wings sit inside the stern instead of overhanging it; `part_engine_rijay` reads as a drum with a ridge; `part_engine_consol` reads as a squarer orange-grey nacelle with none. **She will look wrong without her engines — that is expected until Task 8 layers them back on.**

- [ ] **Step 11: Commit**

```bash
git add tools/artspike client/assets
git commit -m "refactor(art): the mockingbird's drums become a part, ridge and all (#M4)"
```

---

### Task 8: The client layers parts onto hulls

**Files:**
- Modify: `client/scripts/asset_library.gd` (parts loading, `attach_px`)
- Modify: `client/scripts/world_view.gd` (`_dress_hull`, both call sites)
- Modify: `client/scripts/interior_view.gd:87-106` (`Backdrop`), `:183-224` (`_update_backdrops`)
- Modify: `client/scripts/main.gd:560-583`

**Interfaces:**
- Consumes: `ShipState.mounts` (Task 4); `SpriteSet.mount_anchor(id)` (Task 5); part assets (Tasks 6–7).
- Produces: `WorldView._dress_hull(hull_sprite: Sprite2D, hull_key: String, mounts: Dictionary) -> void` — the single place layering happens.

- [ ] **Step 1: Load parts in the AssetLibrary**

Add `var _parts: Dictionary = {}`, and in `load_all` beside the ships loop:

```gdscript
	var parts_dir := root + "/parts"
	if DirAccess.dir_exists_absolute(parts_dir):
		for key: String in DirAccess.get_directories_at(parts_dir):
			lib._parts[key] = lib._load_set(parts_dir + "/" + key)
```

and an accessor beside `ship()`:

```gdscript
## An exterior part's SpriteSet by its `sprite` key (the wire's mount value).
func part(sprite_key: String) -> SpriteSet:
	return _parts.get(sprite_key)
```

Add to `SpriteSet`:

```gdscript
	## Texture-px point on a PART sprite that lands on its hull's mount
	## anchor. Zero for hull sprites, which carry no attach point.
	func attach_px() -> Vector2:
		var a: Array = meta.get("attach_px", [0.0, 0.0])
		return Vector2(float(a[0]), float(a[1]))
```

- [ ] **Step 2: Write `_dress_hull`**

In `world_view.gd`, beside `_park_sprite`:

```gdscript
## Layer a ship's fitted exterior parts onto her hull sprite (M4 it. 2c).
## Children live in HULL-TEXTURE px — the same frame `_update_parked_ships`
## uses for ships parked at berths — so a part needs no scale of its own:
## every export shares one px_per_unit. Drawn OVER the hull, covering the
## blanking plate the hull draws at each hardpoint.
##
## `mounts` is the snapshot's mount id -> part sprite key. A fitted mount
## with no anchor in the hull's meta is a data bug in one of two trees
## (server capability vs art geometry), so it is reported, not guessed at.
func _dress_hull(hull_sprite: Sprite2D, hull_key: String,
		mounts: Dictionary) -> void:
	var hset := _lib.ship(hull_key)
	if hset == null:
		return
	var half := Vector2(hset.px_size()) * 0.5
	var used := {}
	for mount_id: String in mounts:
		var pset := _lib.part(str(mounts[mount_id]))
		if pset == null:
			continue  # no art for this part yet
		var anchor := hset.mount_anchor(mount_id)
		if anchor == Vector2.INF:
			push_error("[art] %s has no anchor for mount %s" % [hull_key, mount_id])
			continue
		var key := "part_" + mount_id
		used[key] = true
		var s: Sprite2D = hull_sprite.get_node_or_null(NodePath(key))
		if s == null:
			s = Sprite2D.new()
			s.name = key
			s.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			s.light_mask = 1  # pipeline art: sun-lit
			hull_sprite.add_child(s)
		s.texture = pset.texture
		s.material = pset.material
		s.visible = true
		# Sprite2D is centred, so offset from the attach point to the part's
		# own centre, then from the hull's centre to the anchor.
		s.position = anchor - half + (Vector2(pset.px_size()) * 0.5 - pset.attach_px())
	for child in hull_sprite.get_children():
		var name := String(child.name)
		if name.begins_with("part_") and not used.has(name):
			child.visible = false
```

- [ ] **Step 3: Call it from the flying path**

At the end of `_update_ship_sprites`' per-ship body, after `s.scale = …`:

```gdscript
		_dress_hull(s, ship.hull_sprite, ship.mounts)
```

- [ ] **Step 4: Call it from the moored path**

Give `_park_sprite` a `mounts: Dictionary = {}` parameter, and end its body with `_dress_hull(s, kind, mounts)`. Pass `ship.mounts` from the real-ship call in `_update_parked_ships`; the decorative Longhorn call passes nothing (her engines are still baked in).

Note the parked case already scales the child by `SHIP_WORLD_UNITS_PER_PX / station_units_per_px`; part children inherit that from their parent, which is correct.

- [ ] **Step 5: Carry fittings onto the interior backdrop**

In `interior_view.gd`, add to `Backdrop`:

```gdscript
	var mounts: Dictionary = {}   ## mount id -> part sprite key
```

and a fifth optional parameter on `make(...)`:

```gdscript
	static func make(p_kind: String, p_asset: String, p_tile_origin: Vector2,
			p_rotated: bool = false, p_mounts: Dictionary = {}) -> Backdrop:
```

setting `b.mounts = p_mounts`.

In `_update_backdrops`, after `s.scale = Vector2.ONE * px_scale`, layer the parts. The backdrop uses the `*_interior` 2× render, whose anchors are in that sprite's own px, so the same helper logic applies — but it lives in `WorldView`. Duplicate the *minimum*: add a small private method here that reuses `sset.mount_anchor` and `_lib.part`, and set `light_mask = 2` on the children (never sun-lit through THE WINDOW) and `show_behind_parent = true` so they stay under the tiles:

```gdscript
		_dress_backdrop(s, sset, spec.mounts)
```

```gdscript
## Layer fitted parts onto a backdrop hull. Same geometry as WorldView's
## _dress_hull, but backdrop children take light_mask 2 and draw behind the
## parent — a backdrop is scenery under the tiles, not sun-lit space art.
func _dress_backdrop(hull_sprite: Sprite2D, hset: AssetLibrary.SpriteSet,
		mounts: Dictionary) -> void:
	var half := Vector2(hset.px_size()) * 0.5
	var used := {}
	for mount_id: String in mounts:
		# The backdrop is the 2x `*_interior` render, so prefer the doubled
		# part twin; fall back to the 1x set if a part has no twin yet.
		var pset := _lib.part(str(mounts[mount_id]) + "_interior")
		if pset == null:
			pset = _lib.part(str(mounts[mount_id]))
		if pset == null:
			continue
		var anchor := hset.mount_anchor(mount_id)
		if anchor == Vector2.INF:
			continue  # WorldView already push_errors this pair
		var key := "part_" + mount_id
		used[key] = true
		var s: Sprite2D = hull_sprite.get_node_or_null(NodePath(key))
		if s == null:
			s = Sprite2D.new()
			s.name = key
			s.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			s.light_mask = 2
			s.show_behind_parent = true
			hull_sprite.add_child(s)
		s.texture = pset.texture
		s.material = pset.material
		s.visible = true
		s.position = anchor - half + (Vector2(pset.px_size()) * 0.5 - pset.attach_px())
	for child in hull_sprite.get_children():
		var name := String(child.name)
		if name.begins_with("part_") and not used.has(name):
			child.visible = false
```

**The 2× render.** A backdrop uses the hull's `*_interior` export (`px_scale=2`), so its mount anchors are in doubled px. Task 6 already ships a matching 2× twin for every part (`engine_rijay_interior`), so the backdrop must look up the doubled part, not the space one. In `_dress_backdrop`, resolve it as:

```gdscript
		var pset := _lib.part(str(mounts[mount_id]) + "_interior")
		if pset == null:
			pset = _lib.part(str(mounts[mount_id]))  # 1x fallback
		if pset == null:
			continue  # no art for this part yet
```

Everything else — anchor lookup, centring maths, pooling — is identical to `_dress_hull`, because both frames are "this sprite's own texture px".

- [ ] **Step 6: Pass the mounts from main.gd**

In `_interior_backdrops`, add a mounts lookup beside `_interior_asset_for`:

```gdscript
## The fitted mounts of a ship id, for layering onto her backdrop.
func _mounts_for(ship_id: int) -> Dictionary:
	for ship in _ships:
		if ship.id == ship_id:
			return ship.mounts
	return {}
```

and pass `_mounts_for(...)` as `make(...)`'s fifth argument in all three branches.

- [ ] **Step 7: Launch and look**

```powershell
$env:Path = "$env:USERPROFILE\scoop\shims;$env:Path"
cd server; gleam run
godot --path client -- --username=<you> --password=dev
```

Confirm by eye:
- The flying Mockingbird has three engines again, and the centre one is the squarer orange Consol while the outers are blue Rijay drums with ridges. **The lore is now visible in the sprite.**
- She looks right parked at a berth.
- The walk-mode backdrop shows the same engines past her docking corridor.

- [ ] **Step 8: Prove a swap shows**

With the client running, refit the centre mount to a Rijay Stork through the existing `refit` message (use `harness/automation.py`, or add a temporary throwaway harness script — do not commit it). The centre nacelle must change from orange Consol to blue ridged Rijay **without a reconnect**, since appearance rides the snapshot.

- [ ] **Step 9: Commit**

```bash
git add client/scripts tools/artspike client/assets/parts
git commit -m "feat(client): fitted parts layer onto hulls at their mount anchors (#M4)"
```

---

### Task 9: The plume burns from the fitted engines

**Files:**
- Modify: `client/scripts/world_view.gd:465-492` (`_emit_plume_trail`), its call site at `:430`

**Interfaces:**
- Consumes: `SpriteSet.mount_anchor` (Task 5), `ShipState.mounts` (Task 4).
- Produces: exhaust emitted per fitted engine mount instead of from one tail point.

- [ ] **Step 1: Emit from each fitted mount**

Replace the `tail` computation in `_emit_plume_trail`. The mount anchor is in hull-texture px with +y down and the sprite drawn nose-up; the world offset is that anchor relative to the sprite centre, rotated into the ship's heading:

```gdscript
	# #12 / M4 it. 2c — one plume per FITTED engine mount, so a hull with an
	# empty mount visibly burns on fewer engines. Falls back to a single
	# centreline tail when we have no art or no fit for her.
	var aft := -Vector2(cos(heading), sin(heading))
	var lateral := Vector2(-aft.y, aft.x)
	var origins: Array[Vector2] = []
	var hset := _lib.ship(ship.hull_sprite)
	if hset != null and not ship.mounts.is_empty():
		var half := Vector2(hset.px_size()) * 0.5
		var units_per_px := SHIP_WORLD_UNITS_PER_PX * SHIP_RENDER_SCALE
		for mount_id: String in ship.mounts:
			var a := hset.mount_anchor(mount_id)
			if a == Vector2.INF:
				continue
			# sprite px (nose-up, +y down) -> ship-local world offset
			var local := (a - half) * units_per_px
			origins.append(ship.position() + aft * local.y
				+ lateral * -local.x)
	if origins.is_empty():
		origins.append(ship.position() + aft * (PLUME_MOTE_WORLD * 1.5))
```

Then emit `n` motes spread across `origins`:

```gdscript
	var motes: Array = _plume_trails.get_or_add(ship.id, [])
	for i in n:
		var origin: Vector2 = origins[i % origins.size()]
		var kick := aft * PLUME_EXHAUST_SPEED \
			+ lateral * randf_range(-PLUME_SPREAD, PLUME_SPREAD)
		motes.append({"p": origin, "v": ship.velocity() + kick,
			"age": 0.0, "level": level})
```

- [ ] **Step 2: Launch and look**

Fly the Mockingbird at full throttle. Expected: three distinct plumes from three drums, not one from her centreline. Turn hard — the world-space trails still curve (that behaviour is unchanged).

- [ ] **Step 3: Commit**

```bash
git add client/scripts/world_view.gd
git commit -m "feat(client): exhaust burns from each fitted engine mount (#M4)"
```

---

### Task 10: Half 1 documentation

**Files:**
- Modify: `docs/modules.md:110-115`, `:302-311`, `:465-472`, `:652-654`, `:673-676`
- Modify: `DESIGN.md` (the "Exterior composition at runtime" open question)

- [ ] **Step 1: Update `docs/modules.md`**

- Line 110–115: mounts are still `{id, kind, size}`, but geometry has **arrived** — as a named anchor in the sprite's `meta.json`, not on the hull. Replace "it arrives with client-side part layering in iteration 2c" with what actually shipped, and say why the split held.
- Line 302–311: rewrite the "none of this has shipped yet" paragraph. A part's `sprite` **is** on the wire now, mounts carry geometry, and the client layers rather than drawing a whole-hull bake.
- Line 465–472: `sprite` is no longer "the client's key for iteration 2c's layering" — it is the key the snapshot carries.
- Line 652–654: replace the "Iteration 2c is…" paragraph with a done-summary in the style of the 2a/2b blocks.
- Line 673–676: the "Exterior composition at runtime" question is **closed** — client-side layering shipped; a bake stays available if the lighting pipeline ever demands one.

Document the wire shape (hull + mounts on each snapshot ship entry) and the sprite-keys-not-part-ids rule in the same pass.

- [ ] **Step 2: Close the DESIGN.md open question**

Find the "Exterior composition at runtime" entry and replace the open question with the shipped answer, cross-referencing `docs/modules.md`.

- [ ] **Step 3: Commit**

```bash
git add docs/modules.md DESIGN.md
git commit -m "docs(m4): exterior layering shipped; close the composition question (#M4)"
```

---

# HALF 2 — ART

---

### Task 11: The Wren, and the part-art check goes strict

**Files:**
- Modify: `tools/artspike/manufacturers.py` (add `part_engine_wren`)
- Modify: `tools/artspike/composer.py` (`PART_EXPORTS`)
- Modify: `harness/test_m4_exterior.py` (drop the parts guard)

**Interfaces:**
- Produces: `manufacturers.part_engine_wren() -> Hull`; the `engine_rijay_small` sprite (the `sprite` key on `server/parts/rijay_engine_wren_90b.json`).

- [ ] **Step 1: Write the failing test**

```python
def test_wren_is_a_smaller_rijay_drum():
    """Same design language, size `s`: a Wren must read as the family's
    little sister, not as a different manufacturer."""
    from composer import hull_frame
    from manufacturers import part_engine_rijay, part_engine_wren
    big = hull_frame(part_engine_rijay())
    small = hull_frame(part_engine_wren())
    assert small[3] < big[3], "the Wren is shorter than the Stork"
    assert small[2] < big[2], "and narrower"
```

- [ ] **Step 2: Run to verify it fails**

Run: `python -m pytest tools/artspike -q`
Expected: FAIL — no `part_engine_wren`.

- [ ] **Step 3: Author it**

```python
def part_engine_wren():
    """Rijay Wren 90-B — size `s`, the Sparrow's engine. The Stork's drum at
    two-thirds scale with a shorter ridge: same family, smaller sister."""
    r, ln, fl = MB_R * 0.68, MB_LN * 0.62, MB_FL * 0.7
    layers = [
        Layer(rrect(-r, 0, 2 * r, ln, r * .95, RIJ_BLUE, sw=2.0),
              cyl_x(0.34, 0.66)),
        Layer(rrect(-r * .72, ln - 2.0, r * 1.44, 4.0, 1.8, RIJ_BLUE_D,
                    sw=1.4), cyl_x(0.32, 0.52)),
        Layer(poly([(0, 2), (1.5, 6), (1.5, ln - 2), (1.0, ln + 5 * fl),
                    (0, ln + 6 * fl), (-1.0, ln + 5 * fl), (-1.5, ln - 2),
                    (-1.5, 6)], RIJ_WHITE, stroke=INK, sw=0.9), flat(0.72)),
        Layer(f'<ellipse cx="0" cy="{ln + 6:.1f}" rx="{r * .85:.1f}" '
              f'ry="7" fill="url(#glow)"/>', role="glow"),
        Layer(f'<ellipse cx="0" cy="{ln + 2.5:.1f}" rx="{r * .5:.1f}" '
              f'ry="4" fill="{GLOW_CORE}" stroke="none"/>', role="glow"),
    ]
    return Hull(layers=layers, anchors=[Anchor("attach", 0.0, 0.0)])
```

Add its `PartSpec` to `PART_EXPORTS` (Rijay livery, same as `engine_rijay`), plus its `_interior` 2× twin.

- [ ] **Step 4: Export, and make the parts check strict**

Run: `python tools/artspike/composer.py`
Then delete the parts-art guard added in Task 6 Step 7 from `harness/test_m4_exterior.py` — every part document's `sprite` now resolves.

- [ ] **Step 5: Run both suites**

Run: `python -m pytest tools/artspike -q` — Expected: PASS.
Run: `cd harness; python -m pytest -q` — Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add tools/artspike client/assets/parts harness/test_m4_exterior.py
git commit -m "feat(art): the Wren 90-B, and every part sprite key now has art (#M4)"
```

---

### Task 12: The Sparrow's exterior

**Files:**
- Modify: `tools/artspike/manufacturers.py` (add `ship_sparrow`, add her to `SHIPS`, widen the RIJAY row in `build_sheet`)
- Modify: `tools/artspike/composer.py` (`SHIP_EXPORTS`, a `SP_INTERIOR` fit block)
- Modify: `tools/artspike/test_composer.py`
- Regenerate: `sheet_mfr.svg`, `sheet_mfr.png`, `sheet_composer.png`, `client/assets/ships/sparrow{,_interior}/`

**Interfaces:**
- Consumes: mount ids `engine_port`, `engine_center`, `engine_stbd` from `server/shipclasses/sparrow.json`.
- Produces: `manufacturers.ship_sparrow() -> Hull`; `client/assets/ships/sparrow/` and `sparrow_interior/`.

**Her shape:** a 5 × 7 tile walkable Main deck — cockpit forward, a 3 × 2 pod bay aft of it, a fore bay flanking a centre corridor, dock ports on her sternmost interior row. She moors **side-on** (`dock_port_orientation: 90.0`). Her sprite runs longer than 7 tiles: she carries exterior-only structure aft for her three `s` mounts, exactly as the Mockingbird does. Read `server/shipclasses/sparrow.json` and run `python tools/slotmap.py server/shipclasses/sparrow.json` before drawing, so the silhouette matches the rooms.

- [ ] **Step 1: Write the failing test**

```python
def test_sparrow_is_a_rijay_hull_with_three_small_mounts():
    from manufacturers import ship_sparrow
    hull = ship_sparrow()
    mounts = {a.id for a in hull.anchors if a.kind == "mount"}
    assert mounts == {"engine_port", "engine_center", "engine_stbd"}
    assert any(l.height is not None for l in hull.layers), "authored relief"


def test_sparrow_interior_fit_covers_her_deck_grid():
    """The walk backdrop must reach every walkable tile: 5 wide x 7 long."""
    from composer import SHIP_EXPORTS, hull_frame
    spec = next(s for s in SHIP_EXPORTS if s.name == "sparrow")
    frame = hull_frame(spec.build())
    units_per_tile = spec.interior["units_per_tile"]
    assert frame[2] >= 5 * units_per_tile - 1e-6
    assert frame[3] >= 7 * units_per_tile - 1e-6
```

- [ ] **Step 2: Run to verify it fails**

Run: `python -m pytest tools/artspike -q`
Expected: FAIL — no `ship_sparrow`.

- [ ] **Step 3: Author her**

First factor the plate helper out of `mb_mount_plates`, since three hulls now need it:

```python
def rij_mount_plates(centres, y, r, size=1.0):
    """-> (layers, mount anchors). A faired-over hardpoint per mount: plate
    plus bolt ring, drawn by the HULL so an empty mount still reads
    deliberate. `centres` is [(x, mount_id), ...] on the transom at `y`;
    `size` scales the plate for an `s` vs `m` mount, which is a free
    readability win — you can see which hardpoint takes the big engine."""
    layers, anchors = [], []
    for cx, mount_id in centres:
        pr = r * size
        layers.append(Layer(rrect(cx - pr * .82, y - 1.5, pr * 1.64, 6.0, 2.0,
                                  RIJ_BLUE_D, sw=1.6), flat(0.30)))
        for by in (y + 0.6, y + 3.4):
            layers.append(Layer(circle(cx - pr * .5, by, .7, INK, stroke="none")))
            layers.append(Layer(circle(cx + pr * .5, by, .7, INK, stroke="none")))
        anchors.append(Anchor("mount", cx, y, id=mount_id))
    return layers, anchors
```

Rewrite `mb_mount_plates` as a one-line call to it, and confirm `python -m pytest tools/artspike -q` still passes before drawing anything new.

Then the Sparrow, in the Rijay vocabulary `ship_mockingbird` established — `mirrored_path` body with a `dome` height, `RIJ_BLUE`/`RIJ_WHITE` stripes, `mb_ports`-style dormers, `mb_canopy`-style nose glass — at packet-courier proportions:

```python
# The Sparrow: Rijay's packet courier. 5 x 7 walkable tiles (32.5 x 45.5
# model units at the 6.5-units-per-tile canon) plus an engine bay aft, so
# ~5 x 10 tiles of sprite. Short, blunt, all cockpit and cargo door — she
# moors side-on, so her port flank is what a station sees.
SP_W, SP_LEN, SP_STERN = 16.25, 45.5, 45.5   # half-width, walkable, transom y

def ship_sparrow():
    """Rijay's packet courier and the game's smallest hull. Engines are
    parts; the transom carries three `s` blanking plates."""
    layers = []
    segs = [...]   # bow -> waist -> transom, mirrored; author against the sheet
    layers.append(Layer(mirrored_path((0, 0), segs, RIJ_BLUE, sw=2.2),
                        dome(0.35, 0.60, blur=6.0)))
    # ... stripes, ports, canopy in the mb_* idiom ...
    plates, anchors = rij_mount_plates(
        [(-SP_W * .55, "engine_port"), (0, "engine_center"),
         (SP_W * .55, "engine_stbd")], SP_STERN, MB_R, size=0.7)
    layers += plates
    return Hull(layers=layers, anchors=anchors)
```

Hard constraints the tests enforce: her frame must be at least 5 × 7 tiles (32.5 × 45.5 units); her deck grid's tile (0,0) sits at the sprite frame's top-left, matching the Mockingbird's `origin_units: None` contract; and she carries exterior-only length aft of the walkable envelope for the engines.

The `segs` path and the detailing are authored art — iterate against the sheet render.

- [ ] **Step 4: Register her exports**

In `composer.py`:

```python
# Sparrow interior fit: same 1 m tile canon as the Mockingbird. Her deck grid
# is 5 x 7; the sprite runs longer, the extra being the engine bay aft.
SP_INTERIOR = {"units_per_tile": 6.5, "origin_units": None}
```

and two `ExportSpec`s — `"sparrow"` at `classic_px` scaled to her true length (she is 7 walkable + engine bay tiles against the Mockingbird's 30, so `classic_px = round(45 * her_tiles / 30)`; keep `model_units=195` so `px_per_unit` stays the canon) and `"sparrow_interior"` at double with `px_scale=2`.

- [ ] **Step 5: Put her on the design sheet**

Add her to `SHIPS` in `manufacturers.py` and widen `slot_x["RIJAY"]` from `[330, 610]` to `[330, 610, 880]`.

- [ ] **Step 6: Export and regenerate the canon**

```powershell
python tools/artspike/composer.py
python -c "import sys; sys.path.insert(0,'tools/artspike'); import manufacturers, pathlib; pathlib.Path('tools/artspike/sheet_mfr.svg').write_text(manufacturers.build_sheet(), encoding='utf-8')"
```

- [ ] **Step 7: Run the suites**

Run: `python -m pytest tools/artspike -q` — Expected: PASS.
Run: `cd harness; python -m pytest -q` — Expected: `test_mount_ids_match_anchor_ids[sparrow]` now passes for real.

- [ ] **Step 8: Walk her**

```powershell
$env:DH_SHIP_CLASS = "shipclasses/sparrow.json"
cd server; gleam run
godot --path client -- --username=<you> --password=dev
```

Confirm by eye: she flies wearing her own hull; two Wren drums burn and the **centre mount shows a bare blanking plate** — the first hull in the game with a visibly empty hardpoint; her walk backdrop is her own silhouette, not the Mockingbird's; her interior tiles land inside her hull skin.

- [ ] **Step 9: Commit**

```bash
git add tools/artspike client/assets/ships
git commit -m "feat(art): the Sparrow gets her own hull (#M4)"
```

---

### Task 13: The Goldfinch's exterior

**Files:**
- Modify: `tools/artspike/manufacturers.py` (add `ship_goldfinch`, `SHIPS`, sheet layout)
- Modify: `tools/artspike/composer.py` (`SHIP_EXPORTS`, `GF_INTERIOR`)
- Modify: `tools/artspike/test_composer.py`
- Modify: `harness/test_m4_exterior.py` (drop the hull-art guard)
- Regenerate: sheets and `client/assets/ships/goldfinch{,_interior}/`

**Interfaces:**
- Consumes: mount ids from `server/shipclasses/goldfinch.json` (`engine_port` s, `engine_center` m, `engine_stbd` s).
- Produces: `manufacturers.ship_goldfinch() -> Hull`; her two exports.

**Her shape:** 5 × 14 tiles walkable across **three** decks — Upper and Lower passenger decks of six cabins each plus a Mezzanine carrying her dock ports. The design read is the A380's two rows of windows: she should show **two banks of cabin ports** down her flank, which is what makes her a liner rather than a big Sparrow. Read `server/shipclasses/goldfinch.json` and run `tools/slotmap.py` on her first.

- [ ] **Step 1: Write the failing test**

```python
def test_goldfinch_has_two_banks_of_ports():
    """The A380 read: two rows of windows is what says 'liner'."""
    from manufacturers import ship_goldfinch
    hull = ship_goldfinch()
    glass = [l for l in hull.layers if GLASS in l.svg]
    assert len(glass) >= 8, "two banks of cabin ports down her flank"


def test_goldfinch_mounts_match_her_hull_document():
    from manufacturers import ship_goldfinch
    mounts = {a.id for a in ship_goldfinch().anchors if a.kind == "mount"}
    assert mounts == {"engine_port", "engine_center", "engine_stbd"}
```

- [ ] **Step 2: Run to verify it fails**

Run: `python -m pytest tools/artspike -q`
Expected: FAIL — no `ship_goldfinch`.

- [ ] **Step 3: Author her**

Rijay vocabulary again, liner proportions: long and narrow, two visible port banks, a mezzanine band at her waist where the dock ports sit. Her transom mixes plate sizes, which `rij_mount_plates` already supports:

```python
# The Goldfinch: Rijay's small liner. 5 x 14 walkable tiles (32.5 x 91 model
# units) over three decks, plus an engine bay aft. The A380 read: TWO banks
# of cabin ports down her flank is what says "liner" rather than "big
# Sparrow". Her mezzanine band at the waist is where her dock ports sit.
GF_W, GF_LEN, GF_STERN = 16.25, 91.0, 91.0

def ship_goldfinch():
    """Rijay's small passenger liner. Centre mount takes an `m`, flanks `s`,
    and the plates differ in size so you can see which is which."""
    layers = []
    segs = [...]   # long narrow body; author against the sheet
    layers.append(Layer(mirrored_path((0, 0), segs, RIJ_BLUE, sw=2.2),
                        dome(0.30, 0.55, blur=8.0)))
    for bank_y in (GF_LEN * .30, GF_LEN * .58):   # upper and lower decks
        layers += mb_ports(y=bank_y, edge=GF_W - 2.0)
    # ... mezzanine band, stripes, canopy ...
    plates, anchors = rij_mount_plates(
        [(-GF_W * .58, "engine_port")], GF_STERN, MB_R, size=0.7)
    centre, centre_anchors = rij_mount_plates(
        [(0, "engine_center")], GF_STERN, MB_R, size=1.0)
    stbd, stbd_anchors = rij_mount_plates(
        [(GF_W * .58, "engine_stbd")], GF_STERN, MB_R, size=0.7)
    layers += plates + centre + stbd
    return Hull(layers=layers,
                anchors=anchors + centre_anchors + stbd_anchors)
```

`mb_ports` currently hardcodes `y=27, edge=16`; it already takes both as keyword arguments, so the two-bank call above works unchanged.

- [ ] **Step 4: Register her exports and sheet slot**

`GF_INTERIOR = {"units_per_tile": 6.5, "origin_units": None}`, two `ExportSpec`s (`goldfinch`, `goldfinch_interior` at `px_scale=2`), `classic_px` scaled from her true tile length with `model_units=195`. Add her to `SHIPS`; the RIJAY row now needs a fourth slot — widen `slot_x["RIJAY"]` to `[330, 610, 880, 1050]` or move her to a second RIJAY row, whichever reads better on the sheet.

- [ ] **Step 5: Export and regenerate**

```powershell
python tools/artspike/composer.py
python -c "import sys; sys.path.insert(0,'tools/artspike'); import manufacturers, pathlib; pathlib.Path('tools/artspike/sheet_mfr.svg').write_text(manufacturers.build_sheet(), encoding='utf-8')"
```

- [ ] **Step 6: Make the hull-art check strict**

Delete the `pytestmark` guard from `harness/test_m4_exterior.py` (added in Task 5 Step 8). All three hulls have art now.

- [ ] **Step 7: Run everything**

Run: `python -m pytest tools/artspike -q` — Expected: PASS.
Run: `cd harness; python -m pytest -q` — Expected: PASS, no xfails.
Run: `cd server; gleam test` — Expected: PASS.

- [ ] **Step 8: Walk her, and park all three together**

```powershell
$env:DH_SHIP_CLASS = "shipclasses/goldfinch.json"
cd server; gleam run
godot --path client -- --username=<you> --password=dev
```

Confirm: her own hull in space and as a backdrop; her `m` centre mount wears a Stork and her `s` flanks Wrens; two port banks read as two decks.

**Then the size check the spec flagged as a risk:** get a Mockingbird and a Goldfinch moored at the same station and look at them side by side. She is 5 tiles across against the Mockingbird's 14. If she reads too small, **stop and report it** — a layout revision is a separate iteration, not a change of scope here.

- [ ] **Step 9: Commit**

```bash
git add tools/artspike client/assets/ships harness/test_m4_exterior.py
git commit -m "feat(art): the Goldfinch gets her own hull (#M4)"
```

---

### Task 14: Close out

**Files:**
- Modify: `docs/modules.md` (the 2c done-summary from Task 10, extended with the art)
- Modify: `client/assets/README` or `docs/visuals.md` if either lists ship assets

- [ ] **Step 1: Grep for stale references**

```bash
grep -rn "mockingbird_stock\|nozzle\|every hull is a Mockingbird\|until M4" \
  client/ server/ docs/ tools/ harness/ --include=*.gd --include=*.gleam \
  --include=*.md --include=*.py --include=*.json
```

Fix every hit. `nozzle` should survive only in prose about exhaust, never as an anchor kind.

- [ ] **Step 2: Full green run**

```powershell
$env:Path = "$env:USERPROFILE\scoop\shims;$env:Path"
cd server; gleam test
cd ../harness; python -m pytest -q
cd ..; python -m pytest tools/artspike -q
```

Expected: all three green. Record the counts in the PR body.

- [ ] **Step 3: Open the PR**

Write the body to a file first (it is long, and `--body` on one line mangles the markdown), then:

```bash
git push -u origin feat/m4-exterior-layering
gh pr create --title "M4 iteration 2c: exterior part layering (#M4)" \
  --body-file docs/superpowers/plans/.pr-body-2c.md
rm docs/superpowers/plans/.pr-body-2c.md
```

The body must cover, one short section each:

1. **The split that held** — mounts stay `{id, kind, size}`; geometry is a named anchor in the art meta; the harness test and the client `push_error` are what enforce agreement across two trees with no compiler between them.
2. **Appearance on the snapshot** — hull key + fitted mount sprite keys, sprite keys never part ids because the client has no parts catalog, and why it rides the snapshot instead of a push message.
3. **The stern re-cut** — drums out, dorsal ridge goes with them, outboard wing re-rooted on the flare, blanking plates in. Call out the payoff: the starter Mockingbird's lore default now *renders* as a Consol nacelle between two ridged Rijay drums.
4. **`mockingbird_stock` deleted** — finned vs finless is a part distinction now, and it was already dead art.
5. **Two new hulls**, with the Goldfinch size verdict from Task 13 Step 8 stated plainly either way.
6. **`sheet_mfr.svg` regenerated on purpose** — `test_sheet_mfr_render_identical` locks it to protect the Mockingbird through refactors; this was a deliberate art change, not a refactor.
7. **Test counts** from Step 2.

---

## Follow-ups this plan deliberately does not do

- **Mount rotation.** Turret aiming is a field to add with turrets.
- **A server-side composite bake.** Client layering shipped and works; the bake stays an option if the lighting pipeline ever demands one.
- **Player livery.** `c1_tint`/`c2_tint` still equal the bases.
- **The Goldfinch's proportions.** If Task 13 Step 8 says she reads too small, that is a layout revision with its own plan.
- **A `mockingbird_stock` replacement.** Finless is now a part choice; if a genuinely finless engine is wanted as content, it is a part document plus a sprite, not a hull variant.
