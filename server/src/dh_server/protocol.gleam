//// Wire protocol (version 1). Every message is a JSON object with a `v`
//// version field and a `type` discriminator. The Godot client and the Python
//// test harness are both built against this format.
////
//// Server -> client:
////   {"v":1,"type":"snapshot","tick":N,"ships":[{"id","x","y","vx","vy"}...]}
////   {"v":1,"type":"stats","ticks":N,"clients":N,
////    "tick_ms":{"p50":F,"p95":F,"p99":F,"max":F}}
//// Client -> server:
////   {"v":1,"type":"get_stats"}

import dh_server/ship.{type Ship}
import dh_server/stats.{type StatsReply}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list

pub const version = 1

/// Messages a client may send to the server.
pub type ClientMessage {
  GetStats
}

/// Parse an incoming client text frame. Unknown or malformed messages are
/// an Error; the server ignores them.
pub fn parse_client_message(text: String) -> Result(ClientMessage, Nil) {
  let decoder = {
    use v <- decode.field("v", decode.int)
    use msg_type <- decode.field("type", decode.string)
    decode.success(#(v, msg_type))
  }
  case json.parse(text, decoder) {
    Ok(#(1, "get_stats")) -> Ok(GetStats)
    _ -> Error(Nil)
  }
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
  ])
}

/// Serialize a stats response.
pub fn encode_stats(reply: StatsReply) -> String {
  json.object([
    #("v", json.int(version)),
    #("type", json.string("stats")),
    #("ticks", json.int(reply.ticks)),
    #("clients", json.int(reply.clients)),
    #("tick_ms", json.object([
      #("p50", json.float(reply.stats.p50_ms)),
      #("p95", json.float(reply.stats.p95_ms)),
      #("p99", json.float(reply.stats.p99_ms)),
      #("max", json.float(reply.stats.max_ms)),
    ])),
  ])
  |> json.to_string
}
