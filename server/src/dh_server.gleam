//// Distant Horizon server entry point.
////
//// M1 scope: one star system loaded from a world document, per-player
//// Newtonian ships flyable over WebSocket at ws://127.0.0.1:8484/ws.
//// M2 adds walkable characters aboard a ship class loaded from a class
//// document. See dh_server/protocol for the wire format.

import dh_server/accounts
import dh_server/auth
import dh_server/server
import dh_server/shipclass
import dh_server/sim
import dh_server/world
import envoy
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/string

const default_world_path = "worlds/m1_system.json"

const default_ship_class_path = "classes/mockingbird.json"

const default_database_url = "postgres://postgres@127.0.0.1:5432/dh_dev"

/// Postgres-backed accounts when reachable; otherwise an accept-all stub so
/// the server still boots in dev without a database. Auth is not persistent
/// in that fallback mode: every login is accepted and no account state is
/// saved across restarts or between connections.
fn build_authenticator() -> auth.Authenticator {
  let database_url = case envoy.get("DATABASE_URL") {
    Ok(url) -> url
    Error(Nil) -> default_database_url
  }
  case accounts.connect(database_url) {
    Ok(db) -> {
      io.println("accounts: connected to postgres")
      accounts.authenticator(db)
    }
    Error(reason) -> {
      io.println(
        "WARNING: accounts: could not connect to postgres ("
        <> reason
        <> "); falling back to accept-all auth — logins will be accepted "
        <> "but NOT persisted",
      )
      auth.accept_all()
    }
  }
}

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

  let ship_class_path = case envoy.get("DH_SHIP_CLASS") {
    Ok(path) -> path
    Error(Nil) -> default_ship_class_path
  }
  let class = case shipclass.load(ship_class_path) {
    Ok(c) -> c
    Error(err) ->
      panic as {
        "failed to load ship class " <> ship_class_path <> ": " <> err
      }
  }
  io.println("loaded ship class \"" <> class.id <> "\" (" <> class.name <> ")")

  let authenticator = build_authenticator()

  case sim.start(world, class) {
    Error(e) -> io.println("failed to start sim: " <> string.inspect(e))
    Ok(sim_started) -> {
      let sim_subject = sim_started.data
      case server.start(sim_subject, world, class, authenticator) {
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
