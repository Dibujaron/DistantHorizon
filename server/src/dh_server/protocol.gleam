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
////   {"v":1,"type":"board","ship_id":N}
////   {"v":1,"type":"disembark"}
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
////   {"v":1,"type":"board_result","ok":Bool,"reason":null|S,"ship_id":N} —
////   reasons include "not_docked_here" and "not_at_airlock" (boarding from
////   a concourse requires standing at its airlock)
////   {"v":1,"type":"disembark_result","ok":Bool,
////    "reason":null|"not_aboard"|"not_docked"|"not_at_airlock"|"no_concourse",
////    "station_id":S|null}
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
////    "ships":[{"id","x","y","vx","vy","heading","thrust","docked"}...]}
////   {"v":1,"type":"interior","tick":N,"ship_id":N,
////    "characters":[{"id","name","x","y","seat"}...]} — sent at 15 Hz, only
////   to clients aboard `ship_id` (see sim.gleam's interior fan-out)
////   {"v":1,"type":"concourse","tick":N,"station_id":S,
////    "characters":[{"id","name","x","y","seat"}...]} — sent at 15 Hz, only
////   to clients standing in that station's concourse
////   {"v":1,"type":"stats",...}

import dh_server/character.{type Character}
import dh_server/market
import dh_server/ship.{type Ship}
import dh_server/shipclass.{type ShipClass}
import dh_server/stats.{type StatsReply}
import dh_server/world.{type World}
import gleam/dict
import gleam/dynamic/decode
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
  Board(ship_id: Int)
  Disembark
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

/// Reply to `board`: whether it succeeded, why not, and the character's
/// ship after the attempt (unchanged on failure).
pub type BoardResult {
  BoardResult(ok: Bool, reason: Option(String), ship_id: Int)
}

/// Reply to `disembark`: whether it succeeded, why not, and the station
/// whose concourse the character is now standing in.
pub type DisembarkResult {
  DisembarkResult(ok: Bool, reason: Option(String), station_id: Option(String))
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
    1, "board" -> {
      use ship_id <- decode.field("ship_id", decode.int)
      decode.success(Ok(Board(ship_id: ship_id)))
    }
    1, "disembark" -> decode.success(Ok(Disembark))
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

/// Serialize a `board_result` reply to `board`.
pub fn encode_board_result(result: BoardResult) -> String {
  json.object([
    #("v", json.int(version)),
    #("type", json.string("board_result")),
    #("ok", json.bool(result.ok)),
    #("reason", json.nullable(result.reason, json.string)),
    #("ship_id", json.int(result.ship_id)),
  ])
  |> json.to_string
}

/// Serialize a `disembark_result` reply to `disembark`.
pub fn encode_disembark_result(result: DisembarkResult) -> String {
  json.object([
    #("v", json.int(version)),
    #("type", json.string("disembark_result")),
    #("ok", json.bool(result.ok)),
    #("reason", json.nullable(result.reason, json.string)),
    #("station_id", json.nullable(result.station_id, json.string)),
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

/// Serialize a `concourse` message: the characters standing in one
/// station's concourse, sent only to that concourse's occupants — the same
/// interest-management shape as `interior`, keyed by station instead of
/// ship.
pub fn encode_concourse(
  tick: Int,
  station_id: String,
  characters: List(Character),
) -> String {
  json.object([
    #("v", json.int(version)),
    #("type", json.string("concourse")),
    #("tick", json.int(tick)),
    #("station_id", json.string(station_id)),
    #(
      "characters",
      json.preprocessed_array(list.map(characters, encode_character)),
    ),
  ])
  |> json.to_string
}

/// Serialize an `interior` message: the crew of one ship, sent only to
/// that ship's clients (see sim.gleam's interior fan-out).
pub fn encode_interior(
  tick: Int,
  ship_id: Int,
  characters: List(Character),
) -> String {
  json.object([
    #("v", json.int(version)),
    #("type", json.string("interior")),
    #("tick", json.int(tick)),
    #("ship_id", json.int(ship_id)),
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
  ])
}

fn encode_docked(dock: ship.DockState) -> Json {
  case dock {
    ship.Flying -> json.null()
    ship.Docked(station_id, _) -> json.string(station_id)
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
