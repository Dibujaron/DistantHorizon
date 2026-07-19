//// Wire protocol (version 1). Every message is a JSON object with a `v`
//// version field and a `type` discriminator. The Godot client and the
//// Python test harness are both built against this format.
////
//// Client -> server:
////   {"v":1,"type":"login","username":"...","password":"..."}
////   {"v":1,"type":"helm","rotate":F,"thrust":F}
////   {"v":1,"type":"dock"}
////   {"v":1,"type":"undock"}
////   {"v":1,"type":"move","dx":F,"dy":F}
////   {"v":1,"type":"sit","console":"..."}
////   {"v":1,"type":"stand"}
////   {"v":1,"type":"buy","commodity":S,"quantity":N}
////   {"v":1,"type":"sell","commodity":S,"quantity":N}
////   {"v":1,"type":"get_market"}
////   {"v":1,"type":"get_stats"}
////
//// Server -> client:
////   {"v":1,"type":"welcome","account_id":N,"ship_id":N,"character_id":N,
////    "tick_rate":60,"dt":F,"world":{...},"ship_class":{...}}
////   {"v":1,"type":"error","code":"auth_failed"|"storage_error"|"no_market",
////    "message":S}
////   {"v":1,"type":"dock_result","ok":Bool,"reason":null|S} — reasons
////   include "transfer_in_progress"
////   {"v":1,"type":"seat_result","ok":Bool,"reason":null|S,"seat":null|S}
////   {"v":1,"type":"trade_result","ok":Bool,"reason":null|S,"commodity":S,
////    "quantity":N,"price":N} — reasons: not_at_broker | ship_not_docked |
////   no_crane | not_sold_here | insufficient_stock | invalid_quantity |
////   insufficient_hold | insufficient_funds | insufficient_cargo
////   {"v":1,"type":"market","station_id":S,
////    "stores":[{"commodity","name","price","quantity"}...]}
////   {"v":1,"type":"cargo","ship_id":N,"wallet":N,"capacity":N,
////    "hold":[{"commodity","quantity"}...],
////    "transfers":[{"commodity","direction","remaining"}...]}
////   {"v":1,"type":"snapshot","tick":N,
////    "ships":[{"id","x","y","vx","vy","heading","thrust","docked",
////              "berth"}...]} — "berth" is the claimed berth index while
////   docked (null while flying), so the client parks each moored hull at its
////   own berth anchor (the same berth the server releases it at on undock).
////   {"v":1,"type":"space","space":"station:<id>"|"ship:N","epoch":N,
////    "plan":{"decks":[{"name","grid":[rows]}...],"rooms":[...],
////            "consoles":[...],"spawn":{"deck":N,"tile":[x,y]}},
////    "moorings":[{"ship_id":N,"dx":N,"dy":N}...],
////    "concourse":null|{"dx":N,"dy":N},
////    "you":{"x":F,"y":F,"deck":N,"seat":null|S}} — the plan a client should
////   walking, with their own position/seat in its frame. Sent on login and
////   to every occupant of a space whose plan changed (dock/undock/despawn
////   rebuild). Ship spaces carry epoch 0 and moorings []. The client adopts
////   the plan, snaps to `you`, and resets prediction/interpolation.
////   {"v":1,"type":"walkers","tick":N,"space":S,"epoch":N,
////    "characters":[{"id","name","x","y","deck","seat"}...]} — sent at 15
////   Hz ("deck" is "lower"|"upper" — split-level rendering), one
////   per occupied space, only to that space's occupants (replaces M2/M3
////   `interior` + `concourse`). Clients drop walkers whose space/epoch
////   don't match their current `space` message.
////   {"v":1,"type":"stats",...}
////
//// dock_result reasons gain: "berths_full" | "no_berths" | "berth_blocked".
//// error codes gain: "station_full" (login refused: no free berth at the
//// spawn station).

import dh_server/character.{type Character}
import dh_server/composite
import dh_server/deckplan.{type DeckPlan}
import dh_server/glyphs
import dh_server/market
import dh_server/ship.{type Ship}
import dh_server/shipclass.{type ShipClass}
import dh_server/stats.{type StatsReply}
import dh_server/world.{type World}
import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub const version = 1

/// Messages a client may send to the server.
pub type ClientMessage {
  Login(username: String, password: String)
  Helm(rotate: Float, thrust: Float)
  Dock
  Undock
  Move(dx: Float, dy: Float)
  Sit(console: String)
  Stand
  Buy(commodity: String, quantity: Int)
  Sell(commodity: String, quantity: Int)
  GetMarket
  GetStats
}

/// Reply to `sit`/`stand`: whether it succeeded, why not, and the seat the
/// character is in after the attempt (unchanged on failure).
pub type SeatResult {
  SeatResult(ok: Bool, reason: Option(String), seat: Option(String))
}

/// Reply to `buy`/`sell`. `price` is the locked unit price on success,
/// 0 on failure; `commodity`/`quantity` echo the request.
pub type TradeResult {
  TradeResult(
    ok: Bool,
    reason: Option(String),
    commodity: String,
    quantity: Int,
    price: Int,
  )
}

/// Parse an incoming client text frame. Unknown or malformed messages are
/// an Error; the server ignores them.
pub fn parse_client_message(text: String) -> Result(ClientMessage, Nil) {
  case json.parse(text, client_message_decoder()) {
    Ok(Ok(msg)) -> Ok(msg)
    Ok(Error(Nil)) -> Error(Nil)
    Error(_) -> Error(Nil)
  }
}

fn client_message_decoder() -> decode.Decoder(Result(ClientMessage, Nil)) {
  use v <- decode.field("v", decode.int)
  use msg_type <- decode.field("type", decode.string)
  case v, msg_type {
    1, "login" -> {
      use username <- decode.field("username", decode.string)
      use password <- decode.field("password", decode.string)
      decode.success(Ok(Login(username: username, password: password)))
    }
    1, "helm" -> {
      use rotate <- decode.field("rotate", decode.float)
      use thrust <- decode.field("thrust", decode.float)
      decode.success(Ok(Helm(rotate: rotate, thrust: thrust)))
    }
    1, "dock" -> decode.success(Ok(Dock))
    1, "undock" -> decode.success(Ok(Undock))
    1, "move" -> {
      use dx <- decode.field("dx", decode.float)
      use dy <- decode.field("dy", decode.float)
      decode.success(Ok(Move(dx: dx, dy: dy)))
    }
    1, "sit" -> {
      use console <- decode.field("console", decode.string)
      decode.success(Ok(Sit(console: console)))
    }
    1, "stand" -> decode.success(Ok(Stand))
    1, "buy" -> {
      use commodity <- decode.field("commodity", decode.string)
      use quantity <- decode.field("quantity", decode.int)
      decode.success(Ok(Buy(commodity: commodity, quantity: quantity)))
    }
    1, "sell" -> {
      use commodity <- decode.field("commodity", decode.string)
      use quantity <- decode.field("quantity", decode.int)
      decode.success(Ok(Sell(commodity: commodity, quantity: quantity)))
    }
    1, "get_market" -> decode.success(Ok(GetMarket))
    1, "get_stats" -> decode.success(Ok(GetStats))
    _, _ -> decode.success(Error(Nil))
  }
}

/// Serialize the `welcome` message sent on successful login.
pub fn encode_welcome(
  account_id: Int,
  ship_id: Int,
  character_id: Int,
  world: World,
  class: ShipClass,
  registry: glyphs.Registry,
) -> String {
  json.object([
    #("v", json.int(version)),
    #("type", json.string("welcome")),
    #("account_id", json.int(account_id)),
    #("ship_id", json.int(ship_id)),
    #("character_id", json.int(character_id)),
    #("tick_rate", json.int(60)),
    #("dt", json.float(ship.dt)),
    #("world", world.encode(world)),
    #("ship_class", shipclass.encode(class)),
    #("glyphs", glyphs.encode(registry)),
  ])
  |> json.to_string
}

/// Serialize an `error` message. `code` is e.g. `"auth_failed"` or
/// `"storage_error"`.
pub fn encode_error(code: String, message: String) -> String {
  json.object([
    #("v", json.int(version)),
    #("type", json.string("error")),
    #("code", json.string(code)),
    #("message", json.string(message)),
  ])
  |> json.to_string
}

/// Serialize a `dock_result` reply to `dock`/`undock`. `reason` is null
/// when `ok`, otherwise the error code from `ship.try_dock`/`ship.undock`.
pub fn encode_dock_result(result: Result(Nil, String)) -> String {
  let #(ok, reason) = case result {
    Ok(Nil) -> #(True, None)
    Error(reason) -> #(False, Some(reason))
  }
  json.object([
    #("v", json.int(version)),
    #("type", json.string("dock_result")),
    #("ok", json.bool(ok)),
    #("reason", json.nullable(reason, json.string)),
  ])
  |> json.to_string
}

/// Serialize a `seat_result` reply to `sit`/`stand`.
pub fn encode_seat_result(result: SeatResult) -> String {
  json.object([
    #("v", json.int(version)),
    #("type", json.string("seat_result")),
    #("ok", json.bool(result.ok)),
    #("reason", json.nullable(result.reason, json.string)),
    #("seat", json.nullable(result.seat, json.string)),
  ])
  |> json.to_string
}

/// Serialize a `trade_result` reply to `buy`/`sell`.
pub fn encode_trade_result(result: TradeResult) -> String {
  json.object([
    #("v", json.int(version)),
    #("type", json.string("trade_result")),
    #("ok", json.bool(result.ok)),
    #("reason", json.nullable(result.reason, json.string)),
    #("commodity", json.string(result.commodity)),
    #("quantity", json.int(result.quantity)),
    #("price", json.int(result.price)),
  ])
  |> json.to_string
}

/// Serialize a station's market: current prices and stock. Sent as the
/// reply to `get_market` and pushed at 15 Hz to that station's concourse
/// occupants.
pub fn encode_market(m: market.Market) -> String {
  json.object([
    #("v", json.int(version)),
    #("type", json.string("market")),
    #("station_id", json.string(m.station_id)),
    #("stores", json.preprocessed_array(list.map(m.stores, encode_store))),
  ])
  |> json.to_string
}

fn encode_store(store: market.Store) -> Json {
  json.object([
    #("commodity", json.string(store.commodity)),
    #("name", json.string(store.name)),
    #("price", json.int(store.price)),
    #("quantity", json.int(store.quantity)),
  ])
}

/// Serialize one ship's cargo state (wallet, hold, running transfers).
/// Sent at 15 Hz to the ship's *crew* wherever their bodies are — a
/// quartermaster at a station broker still watches their ship fill up.
/// Hold entries are sorted by commodity for stable output.
pub fn encode_cargo(s: Ship, capacity: Int) -> String {
  let hold =
    dict.to_list(s.hold)
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    |> list.map(fn(entry) {
      json.object([
        #("commodity", json.string(entry.0)),
        #("quantity", json.int(entry.1)),
      ])
    })
  json.object([
    #("v", json.int(version)),
    #("type", json.string("cargo")),
    #("ship_id", json.int(s.id)),
    #("wallet", json.int(s.wallet)),
    #("capacity", json.int(capacity)),
    #("hold", json.preprocessed_array(hold)),
    #(
      "transfers",
      json.preprocessed_array(list.map(s.transfers, encode_transfer)),
    ),
  ])
  |> json.to_string
}

fn encode_transfer(transfer: ship.Transfer) -> Json {
  let direction = case transfer.direction {
    ship.ToShip -> "to_ship"
    ship.ToStation -> "to_station"
  }
  json.object([
    #("commodity", json.string(transfer.commodity)),
    #("direction", json.string(direction)),
    #("remaining", json.int(transfer.remaining)),
  ])
}

/// A walkable space: a flying ship's interior, or a station's composite
/// (concourse + docked-ship moorings).
pub type SpaceId {
  ShipSpace(ship_id: Int)
  StationSpace(station_id: String)
}

/// The wire id of a space: `"ship:3"` or `"station:meridian_highport"`.
pub fn space_id_string(space: SpaceId) -> String {
  case space {
    ShipSpace(ship_id) -> "ship:" <> int.to_string(ship_id)
    StationSpace(station_id) -> "station:" <> station_id
  }
}

/// Serialize a `space` message: the plan a client should now be walking,
/// with their own position/seat in its frame. Personalized per client.
/// `concourse` is the station concourse's translation into the composite
/// frame (tile 0,0 of the authored concourse sits at composite dx,dy) —
/// the client anchors the station's exterior backdrop with it. None for
/// ship spaces, encoded as `"concourse": null`.
pub fn encode_space(
  space: SpaceId,
  epoch: Int,
  plan: DeckPlan,
  moorings: List(composite.Mooring),
  concourse: option.Option(#(Int, Int)),
  you: Character,
) -> String {
  json.object([
    #("v", json.int(version)),
    #("type", json.string("space")),
    #("space", json.string(space_id_string(space))),
    #("epoch", json.int(epoch)),
    #("plan", deckplan.encode(plan)),
    #("moorings", json.array(moorings, encode_mooring)),
    #("concourse", case concourse {
      option.None -> json.null()
      option.Some(#(dx, dy)) ->
        json.object([#("dx", json.int(dx)), #("dy", json.int(dy))])
    }),
    #(
      "you",
      json.object([
        #("x", json.float(you.x)),
        #("y", json.float(you.y)),
        #("deck", json.int(you.deck)),
        #("seat", json.nullable(you.seat, json.string)),
      ]),
    ),
  ])
  |> json.to_string
}

fn encode_mooring(mooring: composite.Mooring) -> Json {
  json.object([
    #("ship_id", json.int(mooring.ship_id)),
    #("dx", json.int(mooring.dx)),
    #("dy", json.int(mooring.dy)),
  ])
}

/// Serialize a `walkers` message: everyone in one space, 15 Hz, only to
/// that space's occupants (replaces M2 `interior` / M3 `concourse`).
pub fn encode_walkers(
  tick: Int,
  space: SpaceId,
  epoch: Int,
  characters: List(Character),
) -> String {
  json.object([
    #("v", json.int(version)),
    #("type", json.string("walkers")),
    #("tick", json.int(tick)),
    #("space", json.string(space_id_string(space))),
    #("epoch", json.int(epoch)),
    #(
      "characters",
      json.preprocessed_array(list.map(characters, encode_character)),
    ),
  ])
  |> json.to_string
}

fn encode_character(c: Character) -> Json {
  json.object([
    #("id", json.int(c.id)),
    #("name", json.string(c.name)),
    #("x", json.float(c.x)),
    #("y", json.float(c.y)),
    #("deck", json.int(c.deck)),
    #("seat", json.nullable(c.seat, json.string)),
  ])
}

/// Serialize a world snapshot.
pub fn encode_snapshot(tick: Int, ships: List(Ship)) -> String {
  json.object([
    #("v", json.int(version)),
    #("type", json.string("snapshot")),
    #("tick", json.int(tick)),
    #("ships", json.preprocessed_array(list.map(ships, encode_ship))),
  ])
  |> json.to_string
}

fn encode_ship(s: Ship) -> Json {
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
  ])
}

fn encode_docked(dock: ship.DockState) -> Json {
  case dock {
    ship.Flying -> json.null()
    ship.Docked(station_id, _) -> json.string(station_id)
  }
}

/// The claimed berth index of a docked ship (null while flying) — lets the
/// client park a moored hull at its own berth anchor, matching the berth the
/// server pins it to and releases it from (issues #13/#14).
fn encode_berth_index(dock: ship.DockState) -> Json {
  case dock {
    ship.Flying -> json.null()
    ship.Docked(_, berth) -> json.int(berth)
  }
}

/// Serialize a stats response.
pub fn encode_stats(reply: StatsReply) -> String {
  json.object([
    #("v", json.int(version)),
    #("type", json.string("stats")),
    #("ticks", json.int(reply.ticks)),
    #("clients", json.int(reply.clients)),
    #(
      "tick_ms",
      json.object([
        #("p50", json.float(reply.stats.p50_ms)),
        #("p95", json.float(reply.stats.p95_ms)),
        #("p99", json.float(reply.stats.p99_ms)),
        #("max", json.float(reply.stats.max_ms)),
      ]),
    ),
  ])
  |> json.to_string
}
