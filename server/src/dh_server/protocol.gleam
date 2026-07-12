//// Wire protocol (version 1). Every message is a JSON object with a `v`
//// version field and a `type` discriminator. The Godot client and the
//// Python test harness are both built against this format.
////
//// Client -> server:
////   {"v":1,"type":"login","username":"...","password":"..."}
////   {"v":1,"type":"helm","rotate":F,"thrust":F}
////   {"v":1,"type":"dock"}
////   {"v":1,"type":"undock"}
////   {"v":1,"type":"get_stats"}
////
//// Server -> client:
////   {"v":1,"type":"welcome","account_id":N,"ship_id":N,"tick_rate":60,
////    "dt":F,"world":{...}}
////   {"v":1,"type":"error","code":"auth_failed"|"storage_error","message":S}
////   {"v":1,"type":"dock_result","ok":Bool,"reason":null|S}
////   {"v":1,"type":"snapshot","tick":N,
////    "ships":[{"id","x","y","vx","vy","heading","thrust","docked"}...]}
////   {"v":1,"type":"stats",...}

import dh_server/ship.{type Ship}
import dh_server/stats.{type StatsReply}
import dh_server/world.{type World}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/option.{None, Some}

pub const version = 1

/// Messages a client may send to the server.
pub type ClientMessage {
  Login(username: String, password: String)
  Helm(rotate: Float, thrust: Float)
  Dock
  Undock
  GetStats
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
    1, "get_stats" -> decode.success(Ok(GetStats))
    _, _ -> decode.success(Error(Nil))
  }
}

/// Serialize the `welcome` message sent on successful login.
pub fn encode_welcome(account_id: Int, ship_id: Int, world: World) -> String {
  json.object([
    #("v", json.int(version)),
    #("type", json.string("welcome")),
    #("account_id", json.int(account_id)),
    #("ship_id", json.int(ship_id)),
    #("tick_rate", json.int(60)),
    #("dt", json.float(ship.dt)),
    #("world", world.encode(world)),
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
    ship.Docked(station_id) -> json.string(station_id)
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
