//// HTTP/WebSocket front end (mist). One route: /ws upgrades to a WebSocket.
////
//// Each connection starts `PreLogin` and sends no snapshots until it sends
//// a valid `login`; the given `Authenticator` decides success/failure. On
//// success the connection's ship and character are spawned via
//// `sim.add_player` and it moves to `LoggedIn`, at which point
//// `helm`/`dock`/`undock`/`move`/`sit`/`stand`/`board`/`disembark`/`buy`/`sell`/`get_market` take effect.
//// `get_stats` works in both states. `LoggedIn.ship_id` tracks the
//// character's current ship and is updated after every `board` attempt
//// (even a failed one, to the character's unchanged current ship) so that
//// `helm`/`dock`/`undock` always resolve against a session-local ship id.
//// The sim pushes serialized snapshots/interiors as `SendText` messages,
//// which the handler forwards down the socket.

import dh_server/auth.{type Authenticator}
import dh_server/protocol
import dh_server/shipclass.{type ShipClass}
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
/// the sim uses to reach it), or logged in and owning a ship and character.
pub type Session {
  PreLogin(client: Subject(sim.ClientMsg))
  LoggedIn(client: Subject(sim.ClientMsg), ship_id: Int, character_id: Int)
}

pub fn start(
  sim_subject: Subject(sim.Msg),
  world: World,
  class: ShipClass,
  authenticator: Authenticator,
) -> Result(actor.Started(static_supervisor.Supervisor), actor.StartError) {
  mist.new(fn(req) { route(req, sim_subject, world, class, authenticator) })
  |> mist.port(port)
  |> mist.bind(bind_address)
  |> mist.start
}

fn route(
  req: Request(Connection),
  sim_subject: Subject(sim.Msg),
  world: World,
  class: ShipClass,
  authenticator: Authenticator,
) -> Response(ResponseData) {
  case request.path_segments(req) {
    ["ws"] ->
      mist.websocket(
        request: req,
        handler: fn(state, message, conn) {
          handle_ws(
            state,
            message,
            conn,
            sim_subject,
            world,
            class,
            authenticator,
          )
        },
        on_init: fn(_conn) { ws_init() },
        // No explicit unregister: the sim monitors this handler process and
        // drops the subscription (and character/ship) when it exits, clean
        // close or crash alike.
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
  class: ShipClass,
  authenticator: Authenticator,
) -> mist.Next(Session, sim.ClientMsg) {
  case message {
    // Snapshot/interior (or other outbound text) pushed by the sim actor.
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
        class,
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
  class: ShipClass,
  authenticator: Authenticator,
) -> Session {
  case protocol.parse_client_message(text) {
    // Unknown/malformed messages are ignored, never crash the connection.
    Error(Nil) -> session

    Ok(protocol.Login(username, password)) ->
      case session {
        // Login while already logged in is ignored.
        LoggedIn(_, _, _) -> session
        PreLogin(client) ->
          case authenticator(username, password) {
            Ok(account_id) -> {
              let #(ship_id, character_id) =
                sim.add_player(sim_subject, username, client, 1000)
              let _ =
                mist.send_text_frame(
                  conn,
                  protocol.encode_welcome(
                    account_id,
                    ship_id,
                    character_id,
                    world,
                    class,
                  ),
                )
              LoggedIn(client, ship_id, character_id)
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

    // Helm/dock/undock/move/sit/stand/board are ignored until logged in.
    Ok(protocol.Helm(rotate, thrust)) ->
      case session {
        PreLogin(_) -> session
        LoggedIn(_, _, character_id) -> {
          sim.set_controls(sim_subject, character_id, rotate, thrust)
          session
        }
      }

    Ok(protocol.Dock) ->
      case session {
        PreLogin(_) -> session
        LoggedIn(_, _, character_id) -> {
          let result = sim.request_dock(sim_subject, character_id, 1000)
          let _ =
            mist.send_text_frame(conn, protocol.encode_dock_result(result))
          session
        }
      }

    Ok(protocol.Undock) ->
      case session {
        PreLogin(_) -> session
        LoggedIn(_, _, character_id) -> {
          let result = sim.request_undock(sim_subject, character_id, 1000)
          let _ =
            mist.send_text_frame(conn, protocol.encode_dock_result(result))
          session
        }
      }

    Ok(protocol.Move(dx, dy)) ->
      case session {
        PreLogin(_) -> session
        LoggedIn(_, _, character_id) -> {
          sim.set_move(sim_subject, character_id, dx, dy)
          session
        }
      }

    Ok(protocol.Sit(console)) ->
      case session {
        PreLogin(_) -> session
        LoggedIn(_, _, character_id) -> {
          let result = sim.request_sit(sim_subject, character_id, console, 1000)
          let _ =
            mist.send_text_frame(conn, protocol.encode_seat_result(result))
          session
        }
      }

    Ok(protocol.Stand) ->
      case session {
        PreLogin(_) -> session
        LoggedIn(_, _, character_id) -> {
          let result = sim.request_stand(sim_subject, character_id, 1000)
          let _ =
            mist.send_text_frame(conn, protocol.encode_seat_result(result))
          session
        }
      }

    Ok(protocol.Board(target_ship_id)) ->
      case session {
        PreLogin(_) -> session
        LoggedIn(client, _, character_id) -> {
          let result =
            sim.request_board(sim_subject, character_id, target_ship_id, 1000)
          let _ =
            mist.send_text_frame(conn, protocol.encode_board_result(result))
          // `ship_id` is "your ship after the attempt": updated whether the
          // board succeeded or not (a failed attempt leaves it unchanged).
          LoggedIn(client, result.ship_id, character_id)
        }
      }

    Ok(protocol.Disembark) ->
      case session {
        PreLogin(_) -> session
        LoggedIn(_, _, character_id) -> {
          let result = sim.request_disembark(sim_subject, character_id, 1000)
          let _ =
            mist.send_text_frame(conn, protocol.encode_disembark_result(result))
          session
        }
      }

    Ok(protocol.Buy(commodity, quantity)) ->
      case session {
        PreLogin(_) -> session
        LoggedIn(_, _, character_id) -> {
          let result =
            sim.request_buy(
              sim_subject,
              character_id,
              commodity,
              quantity,
              1000,
            )
          let _ =
            mist.send_text_frame(conn, protocol.encode_trade_result(result))
          session
        }
      }

    Ok(protocol.Sell(commodity, quantity)) ->
      case session {
        PreLogin(_) -> session
        LoggedIn(_, _, character_id) -> {
          let result =
            sim.request_sell(
              sim_subject,
              character_id,
              commodity,
              quantity,
              1000,
            )
          let _ =
            mist.send_text_frame(conn, protocol.encode_trade_result(result))
          session
        }
      }

    Ok(protocol.GetMarket) ->
      case session {
        PreLogin(_) -> session
        LoggedIn(_, _, character_id) -> {
          let _ = case sim.request_market(sim_subject, character_id, 1000) {
            Ok(m) -> mist.send_text_frame(conn, protocol.encode_market(m))
            Error(_reason) ->
              mist.send_text_frame(
                conn,
                protocol.encode_error(
                  "no_market",
                  "no station market here (not ashore or docked)",
                ),
              )
          }
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
