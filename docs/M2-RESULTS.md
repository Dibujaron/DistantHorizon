# M2 — The ship is a place: results

**Date:** 2026-07-14 · **Exit criterion met: two players aboard one ship, one flying
while the other walks** (proven continuously by
`harness/test_m2_interior.py::test_one_flies_one_walks`).

Design decisions (were open questions in DESIGN.md, resolved this milestone): interior
movement is **free movement** within walkable tiles, not tile-to-tile hops; ship-system
depth is **consoles only** — a functional helm console and an inert cargo console (M3
binds it). Full design: `docs/superpowers/specs/2026-07-14-m2-ship-interior-design.md`.

## What M2 built

- **Ship class doc** — ship classes are static config files
  (`server/classes/sparrow.json`, schema 1, path overridable via `DH_SHIP_CLASS`):
  tile grid + walkable rows, rooms (render labels), consoles (helm + cargo), spawn
  tile. Validated at boot; served whole to clients in `welcome` as `ship_class`. One
  class in M2 — every ship is a CV-7 Sparrow.
- **Walkable characters, server-authoritative** — each connection is a character aboard
  a ship, walking in ship-local tile coordinates (walk 3.0 tiles/s, radius 0.3,
  per-axis circle-vs-tile collision so you slide along walls), fully decoupled from
  exterior physics (artificial-gravity handwave). Login spawns your ship *and* your
  character **seated at its helm**, which is why every M1 flow works unchanged.
- **Consoles bind control** — `helm`/`dock`/`undock` only work seated at a helm-kind
  console (`dock_result` reason `"not_at_helm"` otherwise; `helm` silently ignored).
  Sit requires standing within 1.2 tiles of an unoccupied console; seated characters
  snap to the console tile and ignore move input.
- **Boarding & crew lifecycle** — `board {ship_id}` moves your character to another
  ship when both are docked at the same station (arrive standing at its spawn tile).
  A ship with zero characters aboard despawns; a crewed ship survives its pilot
  disconnecting mid-flight.
- **Interest-managed interiors** — exterior `snapshot` stays one shared 15 Hz
  broadcast; the new `interior` message is serialized once per crewed ship and sent
  only to the clients aboard it. Verified leak-free at the sim level
  (`server/test/sim_test.gleam`) and over the wire (`test_m2_interior.py`).
- **Godot client: the zoom is real** — INTERIOR view (deck plan, tinted rooms,
  consoles, crew circles, own character highlighted) ↔ SYSTEM view (the M1 flight
  view), switched by seat state with a ~0.6 s center-pivot zoom + crossfade. WASD
  walks (float move intents, sent on change), E sits/stands at the nearest console,
  B boards, SPACE docks as before. Crew positions interpolate from 15 Hz interiors
  like ships do from snapshots.
- **Harness + automation** — `dh_client.py` grew `move`/`sit`/`stand`/`board`/
  `next_interior`; five M2 integration tests including the exit criterion; automation
  state dump gained `view_mode`, `character {id,x,y,seat}`, `ship_id`. A live smoke
  (real server + real client via the automation socket) verified spawn-seated →
  stand → walk → reseat, with screenshots.

## Running it

```powershell
$env:Path = "$env:USERPROFILE\scoop\shims;$env:Path"   # gleam/erlang/godot shims

# terminal 1 — server
cd server; gleam run          # logs: loaded ship class "sparrow" (CV-7 Sparrow)

# terminals 2+3 — two clients aboard one ship
godot --path client -- --username=ada --password=lovelace
godot --path client -- --username=grace --password=hopper
# in grace's window: E to stand, then B to board ada's ship (both start docked at
# Meridian Highport), WASD to walk the deck while ada undocks (SPACE) and flies.

# protocol integration tests (manage their own server; port 8484 must be free)
cd harness; python -m pytest                     # 11 passed = M1 + M2
python -m pytest test_m2_interior.py -v          # just M2
```

## Protocol v1 additions (existing messages unchanged unless noted)

| dir | type | payload |
|---|---|---|
| → | `move` | `dx`, `dy` ∈ [−1,1] **as JSON floats** (decoder rejects bare ints); +y down; ignored while seated |
| → | `sit` | `console` (id) → `seat_result` |
| → | `stand` | — → `seat_result` |
| → | `board` | `ship_id` → `board_result` |
| ← | `seat_result` | `ok`, `reason` (`null`\|`unknown_console`\|`occupied`\|`too_far`\|`already_seated`\|`not_seated`), `seat` (console id \| `null`) |
| ← | `board_result` | `ok`, `reason` (`null`\|`unknown_ship`\|`not_docked_together`\|`same_ship`), `ship_id` (yours, post-attempt) |
| ← | `interior` | `tick`, `ship_id`, `characters: [{id, name, x, y, seat}]` — 15 Hz, only to clients aboard |

Changed: `welcome` + `character_id`, + `ship_class` (full class doc); `dock_result`
gains reason `"not_at_helm"`.

## Ship class doc schema (`schema: 1`)

```jsonc
{
  "schema": 1, "id": "sparrow", "name": "CV-7 Sparrow",
  "grid": {"width": 10, "height": 6},
  "walkable": ["..........", "....###...", ".########.", /* … one string per row */],
  "rooms":    [{"id": "helm", "name": "Helm", "x": 1, "y": 2, "w": 2, "h": 2}, …],
  "consoles": [{"id": "helm_main", "kind": "helm", "x": 1, "y": 2}, …],
  "spawn_tile": [5, 4]        // where boarders arrive; tile (x,y) center = (x+.5, y+.5)
}
```

## Known gaps (deliberate, tracked)

- **Cargo console is scenery** — sittable, does nothing until M3 binds it.
- **No door graph / pathfinding** — free movement + walkable grid only; rooms are
  render metadata.
- **Boarding requires co-docking** — no EVA, no boarding while undocked (M7+ topic).
- **Automation can't drive event-actions via `action`** — `Input.action_press` feeds
  polled input (helm, WASD) but not `_unhandled_input` events (E/B/SPACE); use the
  `key` command for those. Worth folding into the automation server someday.
- **One-frame cosmetic staleness around boarding** — the interior view renders the
  old crew list for ≤1 interior interval (~66 ms) after `board_result`; the
  automation dump's character can be null for a frame. Self-corrects on the next
  `interior`.
- M1 gaps unchanged (SHA-256 passwords, ships die with their crew's connections, no
  ship persistence).
