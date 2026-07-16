# M3 — Trade on foot: results

**Date:** 2026-07-15 · **Exit criterion met: one crew member trades ashore at the
broker while the pilot holds the helm** (proven continuously by
`harness/test_m3_trade.py::test_pilot_holds_helm_while_quartermaster_trades`) — undock
is blocked mid-transfer and released once the transfer completes.

## What M3 built

- **Station concourses** — walkable deck plans embedded straight in the world doc
  (schema 2), reusing M2's interior tech wholesale: same tile grid + walkable rows,
  rooms, and consoles shape, just keyed under a station instead of a ship class.
- **Character place model** — a character's `ship_id` is now crew membership, not
  location; a new `place` (body-side location) tracks where the character actually
  is. A ship survives with its crew ashore, same as it survives a disconnect.
- **Disembark / board-back flow** — `X` walks a standing character out the airlock
  onto the docked station's concourse; `X` again (or boarding prompts) returns them
  to the ship. Requires the ship to be docked at that station.
- **Broker trading** — buy/sell seated at a broker console. Wallet and cargo hold
  live on the *ship* (crew-shared), not the character: hold capacity 40, starting
  wallet 2000.
- **Timed cargo transfers** — robot stevedores move 1 unit/s and work anywhere;
  container cranes move 5 unit/s but only at stations that declare a crane, and
  container-hulled ships refuse to trade at crane-less stations. Undocking is
  blocked while a transfer is in progress (`dock_result` reason
  `"transfer_in_progress"`).
- **Classic's noise-walk dynamic prices** — `price = max(1, base + noise*elasticity)`,
  re-rolled on a 60 s epoch; stock regenerates every 5 s. Both are pure functions of
  the world seed — no hidden mutable RNG state to desync or need saving.
- **New interest-managed channels** — `concourse` (per station, to everyone standing
  there), `cargo` (per ship, to its crew wherever they stand), and `market` (to
  concourse occupants), joining M2's `interior` as the fan-outs beyond the shared
  exterior `snapshot`.
- **Client trade panel** — opens when seated at a broker: W/S move the commodity
  selection, D buys, A sells, Shift held ×10s the quantity. A read-only cargo
  manifest is also viewable from the ship's own cargo console (trading itself stays
  ashore, by design).
- **Harness + automation** — `dh_client.py` grew trade verbs; six new integration
  tests including the exit criterion; automation state dump gained trade/cargo
  fields and a smoke test walking a character ashore and screenshotting the result.

## Running it

```powershell
$env:Path = "$env:USERPROFILE\scoop\shims;$env:Path"   # gleam/erlang/godot shims

# terminal 1 — server
cd server; gleam run

# terminals 2+3 — two clients aboard one ship
godot --path client -- --username=ada --password=lovelace
godot --path client -- --username=grace --password=hopper
# grace: E to stand, X to disembark onto the concourse, E to sit at a broker,
# D to buy / A to sell (hold Shift for x10), X to walk back and reboard.
# meanwhile ada stays seated at the helm and can undock/fly at will — until grace
# has cargo mid-transfer, at which point SPACE (undock) is refused.

# protocol integration tests (manage their own server; port 8484 must be free)
cd harness; python -m pytest -v                  # 17 passed = M1 + M2 + M3
python -m pytest test_m3_trade.py -v             # just M3
```

## Protocol v1 additions (existing messages unchanged unless noted)

| dir | type | payload |
|---|---|---|
| → | `disembark` | — → `disembark_result` |
| → | `buy` | `commodity` (string), `quantity` (**JSON int** — decoder rejects floats) |
| → | `sell` | `commodity` (string), `quantity` (**JSON int**) |
| → | `get_market` | — → `market` |
| ← | `disembark_result` | `ok`, `reason` (`null`\|`not_aboard`\|`not_docked`\|`no_concourse`), `station_id` (string \| `null`) |
| ← | `trade_result` | `ok`, `reason` (`null`\|`not_at_broker`\|`ship_not_docked`\|`no_crane`\|`not_sold_here`\|`insufficient_stock`\|`invalid_quantity`\|`insufficient_hold`\|`insufficient_funds`\|`insufficient_cargo`), `commodity`, `quantity`, `price` (locked unit price, `0` on failure) |
| ← | `market` | `station_id`, `stores: [{commodity, name, price, quantity}]` |
| ← | `cargo` | `ship_id`, `wallet`, `capacity`, `hold: [{commodity, quantity}]` (sorted by commodity), `transfers: [{commodity, direction: "to_ship"\|"to_station", remaining}]` |
| ← | `concourse` | `tick`, `station_id`, `characters: [{id, name, x, y, seat}]` — same shape as `interior` |

Changed: `board_result` gains reason `"not_docked_here"`; `dock_result` gains reason
`"transfer_in_progress"` (both new strings through existing plumbing — no encoder
change). `get_market` with no reachable station market replies with an `error`
frame, `code: "no_market"`, rather than a `trade_result` reason.

## World doc schema (`schema: 2`) additions

```jsonc
{
  "schema": 2,
  "commodities": [
    {"id": "water", "name": "Water"}
    // …
  ],
  "stations": [
    {
      "id": "meridian_highport", "name": "Meridian Highport", "parent": "meridian",
      "orbit": { /* … */ }, "dock_radius": 150.0,
      "crane": true,                          // false = break-bulk only (robots)
      "concourse": {
        "grid": {"width": 10, "height": 6},
        "walkable": ["..........", ".########.", /* … */],
        "rooms":    [{"id": "concourse", "name": "Concourse", "x": 1, "y": 1, "w": 8, "h": 3}, …],
        "consoles": [{"id": "broker_main", "kind": "broker", "x": 4, "y": 3}, …],
        "spawn_tile": [4, 4]
      },
      "market": [
        {"commodity": "water", "initial": 120, "price": 4, "elasticity": 1}
        // … one entry per traded commodity at this station
      ]
    }
  ]
}
```

Ship class doc (`schema: 2`) gains a `cargo` block:

```jsonc
{
  "schema": 2, "id": "sparrow", "name": "CV-7 Sparrow",
  // … grid/walkable/rooms/consoles/spawn_tile unchanged from M2 …
  "cargo": {"capacity": 40, "handling": "breakbulk"}   // or "container" (needs a crane)
}
```

## Known gaps (deliberate, tracked)

- **Prices are a noise walk, not supply/demand** — buying/selling doesn't itself move
  the market; M6's NPC traders are what's meant to actually push prices.
- **No persistence of wallet/cargo** — in-memory like ships, lost on server restart;
  fixed by M4's run/universe persistence.
- **No per-broker identity or factions** — every broker at a station shares one
  market; faction-affiliated brokers with differing prices/relationships are M6.
- **Container hulls exist only as test fixtures** — no real container-hulled ship
  class is authored yet; the crane/no-crane refusal path is exercised by tests only.
- **No berth capacity or congestion model** — docking is still first-come, unlimited,
  same as M1/M2; anchorage/lightering per DESIGN.md is M5+.
- **Cargo console is a read-only manifest** — by design; the trading loop lives at
  concourse brokers, not back aboard the ship.

Test evidence: 165 server (`gleam test`) tests, 17 protocol harness tests (6 M1 + 5 M2
+ 6 M3), 2 automation smoke tests, and a live end-to-end buy verified on-screen
2026-07-15 (wallet 2000 → 1996 buying 1 unit of water at 4 credits, hold `{}` →
`{water: 1}`, transfer count 0 → 1 → 0).
