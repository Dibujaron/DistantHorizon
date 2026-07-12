//// HTTP/WebSocket front end (mist). One route: /ws upgrades to a WebSocket.
////
//// Each connection starts `PreLogin` and sends no snapshots until it sends
//// a valid `login`; the given `Authenticator` decides success/failure. On
//// success the connection's ship is spawned via `sim.add_ship` and it
//// moves to `LoggedIn`, at which point `helm`/`dock`/`undock` take effect.
//// `get_stats` works in both states. The sim pushes serialized snapshots
//// as `SendText` messages, which the handler forwards down the socket.

import dh_server/auth.{type Authenticator}
import dh_server/protocol
import dh_server/sim
import dh_server/world.{type World}
import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/option.{Some}
import gleam/otp/actor
import gleam/otp/static_supervisor
import mist.{type Connection, type ResponseData}

pub const port = 8484

pub const bind_address = "127.0.0.1"

/// A connection's session state: not yet logged in (holding the subject
/// the sim uses to reach it), or logged in and owning a ship.
pub type Session {
  PreLogin(client: Subject(sim.ClientMsg))
  LoggedIn(client: Subject(sim.ClientMsg), ship_id: Int)
}

pub fn start(
  sim_subject: Subject(sim.Msg),
  world: World,
  authenticator: Authenticator,
) -> Result(actor.Started(static_supervisor.Supervisor), actor.StartError) {
  mist.new(fn(req) { route(req, sim_subject, world, authenticator) })
  |> mist.port(port)
  |> mist.bind(bind_address)
  |> mist.start
}

fn route(
  req: Request(Connection),
  sim_subject: Subject(sim.Msg),
  world: World,
  authenticator: Authenticator,
) -> Response(ResponseData) {
  case request.path_segments(req) {
    ["ws"] ->
      mist.websocket(
        request: req,
        handler: fn(state, message, conn) {
          handle_ws(state, message, conn, sim_subject, world, authenticator)
        },
        on_init: fn(_conn) { ws_init() },
        // No explicit unregister: the sim monitors this handler process and
        // drops the subscription (and ship) when it exits, clean close or
        // crash alike.
        on_close: fn(_state) { Nil },
      )
    _ ->
      response.new(404)
      |> response.set_body(mist.Bytes(bytes_tree.from_string("not found")))
  }
}

/// The WebSocket handler's state is a session, starting `PreLogin` around
/// the subject the sim uses to reach it.
fn ws_init() -> #(Session, option.Option(process.Selector(sim.ClientMsg))) {
  let subject = process.new_subject()
  let selector = process.new_selector() |> process.select(subject)
  #(PreLogin(subject), Some(selector))
}

fn handle_ws(
  session: Session,
  message: mist.WebsocketMessage(sim.ClientMsg),
  conn: mist.WebsocketConnection,
  sim_subject: Subject(sim.Msg),
  world: World,
  authenticator: Authenticator,
) -> mist.Next(Session, sim.ClientMsg) {
  case message {
    // Snapshot (or other outbound text) pushed by the sim actor.
    mist.Custom(sim.SendText(text)) ->
      case mist.send_text_frame(conn, text) {
        Ok(_) -> mist.continue(session)
        Error(_) -> mist.stop()
      }

    // Inbound protocol message from the client.
    mist.Text(text) ->
      mist.continue(handle_client_text(
        session,
        text,
        conn,
        sim_subject,
        world,
        authenticator,
      ))

    mist.Binary(_) -> mist.continue(session)
    mist.Closed | mist.Shutdown -> mist.stop()
  }
}

fn handle_client_text(
  session: Session,
  text: String,
  conn: mist.WebsocketConnection,
  sim_subject: Subject(sim.Msg),
  world: World,
  authenticator: Authenticator,
) -> Session {
  case protocol.parse_client_message(text) {
    // Unknown/malformed messages are ignored, never crash the connection.
    Error(Nil) -> session

    Ok(protocol.Login(username, password)) ->
      case session {
        // Login while already logged in is ignored.
        LoggedIn(_, _) -> session
        PreLogin(client) ->
          case authenticator(username, password) {
            Ok(account_id) -> {
              let ship_id = sim.add_ship(sim_subject, client, 1000)
              let _ =
                mist.send_text_frame(
                  conn,
                  protocol.encode_welcome(account_id, ship_id, world),
                )
              LoggedIn(client, ship_id)
            }
            Error(auth.InvalidCredentials) -> {
              let _ =
                mist.send_text_frame(
                  conn,
                  protocol.encode_error(
                    "auth_failed",
                    "invalid username or password",
                  ),
                )
              session
            }
            Error(auth.StorageError(message)) -> {
              let _ =
                mist.send_text_frame(
                  conn,
                  protocol.encode_error("storage_error", message),
                )
              session
            }
          }
      }

    // Helm/dock/undock are ignored until logged in.
    Ok(protocol.Helm(rotate, thrust)) ->
      case session {
        PreLogin(_) -> session
        LoggedIn(_, ship_id) -> {
          sim.set_controls(sim_subject, ship_id, rotate, thrust)
          session
        }
      }

    Ok(protocol.Dock) ->
      case session {
        PreLogin(_) -> session
        LoggedIn(_, ship_id) -> {
          let result = sim.request_dock(sim_subject, ship_id, 1000)
          let _ =
            mist.send_text_frame(conn, protocol.encode_dock_result(result))
          session
        }
      }

    Ok(protocol.Undock) ->
      case session {
        PreLogin(_) -> session
        LoggedIn(_, ship_id) -> {
          let result = sim.request_undock(sim_subject, ship_id, 1000)
          let _ =
            mist.send_text_frame(conn, protocol.encode_dock_result(result))
          session
        }
      }

    // get_stats works in both states.
    Ok(protocol.GetStats) -> {
      let reply = sim.get_stats(sim_subject, 1000)
      let _ = mist.send_text_frame(conn, protocol.encode_stats(reply))
      session
    }
  }
}
