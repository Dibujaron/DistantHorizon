//// Distant Horizon server entry point.
////
//// M1 scope: one star system loaded from a world document, per-player
//// Newtonian ships flyable over WebSocket at ws://127.0.0.1:8484/ws. See
//// dh_server/protocol for the wire format.

import dh_server/auth
import dh_server/server
import dh_server/sim
import dh_server/world
import envoy
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/string

const default_world_path = "worlds/m1_system.json"

pub fn main() -> Nil {
  let world_path = case envoy.get("DH_WORLD") {
    Ok(path) -> path
    Error(Nil) -> default_world_path
  }
  let world = case world.load(world_path) {
    Ok(w) -> w
    Error(err) ->
      panic as { "failed to load world " <> world_path <> ": " <> err }
  }

  case sim.start(world) {
    Error(e) -> io.println("failed to start sim: " <> string.inspect(e))
    Ok(sim_started) -> {
      let sim_subject = sim_started.data
      case server.start(sim_subject, world, auth.accept_all()) {
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
        Error(e) -> io.println("failed to start: " <> string.inspect(e))
      }
    }
  }
}
