//// HTTP/WebSocket front end (mist). One route: /ws upgrades to a WebSocket.
////
//// Each WebSocket connection registers a subject with the sim actor; the
//// sim pushes serialized snapshots as `SendText` messages, which the
//// handler forwards down the socket. Incoming text frames are parsed as
//// protocol messages (currently just `get_stats`).

import dh_server/protocol
import dh_server/sim
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

pub fn start() -> Result(
  #(actor.Started(static_supervisor.Supervisor), Subject(sim.Msg)),
  actor.StartError,
) {
  case sim.start() {
    Error(e) -> Error(e)
    Ok(sim_started) -> {
      let sim_subject = sim_started.data
      let result =
        mist.new(fn(req) { route(req, sim_subject) })
        |> mist.port(port)
        |> mist.bind(bind_address)
        |> mist.start
      case result {
        Ok(web_started) -> Ok(#(web_started, sim_subject))
        Error(e) -> Error(e)
      }
    }
  }
}

fn route(
  req: Request(Connection),
  sim: Subject(sim.Msg),
) -> Response(ResponseData) {
  case request.path_segments(req) {
    ["ws"] ->
      mist.websocket(
        request: req,
        handler: fn(state, message, conn) {
          handle_ws(state, message, conn, sim)
        },
        on_init: fn(_conn) { ws_init(sim) },
        // No explicit unregister: the sim monitors this handler process and
        // drops the subscription when it exits (clean close or crash alike).
        on_close: fn(_state) { Nil },
      )
    _ ->
      response.new(404)
      |> response.set_body(mist.Bytes(bytes_tree.from_string("not found")))
  }
}

/// The WebSocket handler's state is the subject the sim uses to reach it.
fn ws_init(
  sim: Subject(sim.Msg),
) -> #(Subject(sim.ClientMsg), option.Option(process.Selector(sim.ClientMsg))) {
  let subject = process.new_subject()
  sim.register(sim, subject)
  let selector = process.new_selector() |> process.select(subject)
  #(subject, Some(selector))
}

fn handle_ws(
  state: Subject(sim.ClientMsg),
  message: mist.WebsocketMessage(sim.ClientMsg),
  conn: mist.WebsocketConnection,
  sim: Subject(sim.Msg),
) -> mist.Next(Subject(sim.ClientMsg), sim.ClientMsg) {
  case message {
    // Snapshot (or other outbound text) pushed by the sim actor.
    mist.Custom(sim.SendText(text)) ->
      case mist.send_text_frame(conn, text) {
        Ok(_) -> mist.continue(state)
        Error(_) -> mist.stop()
      }

    // Inbound protocol message from the client.
    mist.Text(text) -> {
      case protocol.parse_client_message(text) {
        Ok(protocol.GetStats) -> {
          let reply = sim.get_stats(sim, 1000)
          let _ = mist.send_text_frame(conn, protocol.encode_stats(reply))
          Nil
        }
        // Ignore anything we don't understand.
        Error(Nil) -> Nil
      }
      mist.continue(state)
    }

    mist.Binary(_) -> mist.continue(state)
    mist.Closed | mist.Shutdown -> mist.stop()
  }
}
