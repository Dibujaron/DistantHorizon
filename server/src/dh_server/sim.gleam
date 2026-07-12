//// The simulation actor: owns the world state and drives the 60 Hz tick
//// loop by sending itself `Tick` messages via `process.send_after`, with
//// drift correction (each tick is scheduled against the loop's fixed start
//// time, so per-tick timer error never accumulates).
////
//// Every `snapshot_every` ticks (15 Hz) it serializes one snapshot and
//// fans it out to all registered client subjects. WebSocket handler
//// processes register themselves with `register` and receive `SendText`
//// messages to forward down their socket. The sim monitors each handler
//// process and drops its subscription when the process exits — cleanly or
//// by crashing — so there is no unregister to forget.

import dh_server/clock
import dh_server/protocol
import dh_server/ship.{type Ship}
import dh_server/stats
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/otp/actor

pub const tick_rate = 60

pub const ship_count = 500

/// Broadcast a snapshot every 4th tick: 60 / 4 = 15 Hz.
const snapshot_every = 4

/// Log tick health to stdout every 300 ticks = every 5 s.
const log_every = 300

const us_per_second = 1_000_000

pub opaque type Msg {
  /// Advance the simulation by one step (self-scheduled).
  Tick
  /// A WebSocket connection wants to receive snapshots.
  Register(client: Subject(ClientMsg))
  /// A monitored client handler process exited (cleanly or by crashing).
  ClientDown(down: process.Down)
  /// Reply with current tick statistics.
  GetStats(reply: Subject(stats.StatsReply))
}

/// Messages the sim sends to connected client handler processes.
pub type ClientMsg {
  SendText(String)
}

/// Subscribe a client handler process for snapshots. The subscription lasts
/// as long as the process owning `client` is alive; cleanup is automatic.
pub fn register(sim: Subject(Msg), client: Subject(ClientMsg)) -> Nil {
  process.send(sim, Register(client))
}

/// Ask the sim for its current tick statistics (blocking call).
pub fn get_stats(sim: Subject(Msg), timeout_ms: Int) -> stats.StatsReply {
  process.call(sim, waiting: timeout_ms, sending: GetStats)
}

/// A registered snapshot listener: the subject to push to, and the monitor
/// on its owning process that keys its removal.
type Client {
  Client(monitor: process.Monitor, subject: Subject(ClientMsg))
}

type State {
  State(
    self: Subject(Msg),
    ships: List(Ship),
    tick: Int,
    /// Monotonic time (us) when the tick loop started; scheduling anchor.
    start_us: Int,
    clients: List(Client),
    acc: stats.Accumulator,
  )
}

pub fn start() -> Result(actor.Started(Subject(Msg)), actor.StartError) {
  actor.new_with_initialiser(1000, fn(subject) {
    let state =
      State(
        self: subject,
        ships: ship.init_fleet(ship_count),
        tick: 0,
        start_us: clock.now_us(),
        clients: [],
        acc: stats.new(),
      )
    process.send(subject, Tick)
    // Receive our own messages plus Down notifications for every monitor
    // this process sets up when registering clients.
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_monitors(ClientDown)
    Ok(
      actor.initialised(state)
      |> actor.selecting(selector)
      |> actor.returning(subject),
    )
  })
  |> actor.on_message(handle)
  |> actor.start
}

fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Tick -> run_tick(state)
    Register(client) ->
      case process.subject_owner(client) {
        Ok(pid) -> {
          let entry = Client(monitor: process.monitor(pid), subject: client)
          let state = State(..state, clients: [entry, ..state.clients])
          io.println(
            "client connected ("
            <> int.to_string(list.length(state.clients))
            <> ")",
          )
          actor.continue(state)
        }
        // A subject with no live owner can never receive anything; drop it.
        Error(Nil) -> actor.continue(state)
      }
    ClientDown(process.ProcessDown(monitor: monitor, ..)) -> {
      let clients = list.filter(state.clients, fn(c) { c.monitor != monitor })
      io.println(
        "client disconnected (" <> int.to_string(list.length(clients)) <> ")",
      )
      actor.continue(State(..state, clients: clients))
    }
    // We only monitor processes, never ports.
    ClientDown(process.PortDown(..)) -> actor.continue(state)
    GetStats(reply) -> {
      process.send(reply, stats_reply(state))
      actor.continue(state)
    }
  }
}

fn run_tick(state: State) -> actor.Next(State, Msg) {
  let started_us = clock.now_us()

  // 1. Advance the world.
  let ships = ship.advance_fleet(state.ships)
  let tick = state.tick + 1

  // 2. Broadcast a snapshot at 15 Hz (skip serialization with no listeners).
  case tick % snapshot_every == 0 && state.clients != [] {
    True -> {
      let snapshot = protocol.encode_snapshot(tick, ships)
      list.each(state.clients, fn(client) {
        process.send(client.subject, SendText(snapshot))
      })
    }
    False -> Nil
  }

  // 3. Record how long the work took.
  let acc = stats.record(state.acc, clock.now_us() - started_us)
  let state = State(..state, ships: ships, tick: tick, acc: acc)

  // 4. Periodic health log.
  case tick % log_every == 0 {
    True -> log_health(state)
    False -> Nil
  }

  // 5. Schedule the next tick against the fixed start time (drift-corrected).
  let next_due_us = state.start_us + { tick + 1 } * us_per_second / tick_rate
  let delay_ms = int.max(0, { next_due_us - clock.now_us() } / 1000)
  process.send_after(state.self, delay_ms, Tick)

  actor.continue(state)
}

fn stats_reply(state: State) -> stats.StatsReply {
  stats.StatsReply(
    ticks: state.tick,
    clients: list.length(state.clients),
    stats: stats.current(state.acc),
  )
}

fn log_health(state: State) -> Nil {
  let s = stats.current(state.acc)
  io.println(
    "tick="
    <> int.to_string(state.tick)
    <> " clients="
    <> int.to_string(list.length(state.clients))
    <> " tick_ms p50="
    <> fmt(s.p50_ms)
    <> " p95="
    <> fmt(s.p95_ms)
    <> " p99="
    <> fmt(s.p99_ms)
    <> " max="
    <> fmt(s.max_ms),
  )
}

fn fmt(ms: Float) -> String {
  ms
  |> float.to_precision(3)
  |> float.to_string
}
