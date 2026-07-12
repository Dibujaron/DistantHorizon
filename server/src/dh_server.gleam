//// Distant Horizon server entry point.
////
//// M0 spike scope: a 60 Hz simulation of 500 ships with 15 Hz JSON
//// snapshots over WebSocket at ws://127.0.0.1:8484/ws. See
//// dh_server/protocol for the wire format.

import dh_server/server
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/string

pub fn main() -> Nil {
  case server.start() {
    Ok(_) -> {
      io.println(
        "dh_server listening on ws://"
        <> server.bind_address
        <> ":"
        <> int.to_string(server.port)
        <> "/ws",
      )
      process.sleep_forever()
    }
    Error(e) -> {
      io.println("failed to start: " <> string.inspect(e))
      Nil
    }
  }
}
