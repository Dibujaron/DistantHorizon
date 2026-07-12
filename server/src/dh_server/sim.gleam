//// The simulation actor: owns the world (loaded once at startup) and the
//// list of player ships, and drives the 60 Hz tick loop by sending itself
//// `Tick` messages via `process.send_after`, with drift correction (each
//// tick is scheduled against the loop's fixed start time, so per-tick
//// timer error never accumulates).
////
//// Every `snapshot_every` ticks (15 Hz) it serializes one snapshot and
//// fans it out to all registered client subjects. A WebSocket handler
//// process joins the simulation by calling `add_ship`, which spawns it a
//// ship docked at the world's spawn station and registers it for
//// snapshots in one call. The sim monitors each handler process and drops
//// its ship and subscription when the process exits — cleanly or by
//// crashing — so there is no unregister to forget.

import dh_server/clock
import dh_server/protocol
import dh_server/ship.{type Ship}
import dh_server/stats
import dh_server/world.{type World}
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/otp/actor

pub const tick_rate = 60

/// Broadcast a snapshot every 4th tick: 60 / 4 = 15 Hz.
const snapshot_every = 4

/// Log tick health to stdout every 300 ticks = every 5 s.
const log_every = 300

const us_per_second = 1_000_000

pub opaque type Msg {
  /// Advance the simulation by one step (self-scheduled).
  Tick
  /// A WebSocket connection has logged in: spawn it a ship docked at the
  /// spawn station and register it for snapshots.
  AddShip(client: Subject(ClientMsg), reply: Subject(Int))
  /// Set a ship's helm input (ignored if the ship is docked or unknown).
  SetControls(ship_id: Int, rotate: Float, thrust: Float)
  /// Attempt to dock a ship at the nearest in-range station.
  RequestDock(ship_id: Int, reply: Subject(Result(Nil, String)))
  /// Undock a ship.
  RequestUndock(ship_id: Int, reply: Subject(Result(Nil, String)))
  /// A monitored client handler process exited (cleanly or by crashing).
  ClientDown(down: process.Down)
  /// Reply with current tick statistics.
  GetStats(reply: Subject(stats.StatsReply))
}

/// Messages the sim sends to connected client handler processes.
pub type ClientMsg {
  SendText(String)
}

/// Spawn a new ship docked at the world's spawn station and register
/// `client` to receive snapshots for as long as its owning process lives.
/// Returns the new ship's id.
pub fn add_ship(
  sim: Subject(Msg),
  client: Subject(ClientMsg),
  timeout_ms: Int,
) -> Int {
  process.call(sim, waiting: timeout_ms, sending: AddShip(client, _))
}

/// Set a ship's helm input (cast). Clamped sim-side; ignored while docked
/// or if the ship id is unknown.
pub fn set_controls(
  sim: Subject(Msg),
  ship_id: Int,
  rotate: Float,
  thrust: Float,
) -> Nil {
  process.send(sim, SetControls(ship_id, rotate, thrust))
}

/// Attempt to dock a ship at the nearest in-range station (blocking call).
pub fn request_dock(
  sim: Subject(Msg),
  ship_id: Int,
  timeout_ms: Int,
) -> Result(Nil, String) {
  process.call(sim, waiting: timeout_ms, sending: RequestDock(ship_id, _))
}

/// Undock a ship (blocking call).
pub fn request_undock(
  sim: Subject(Msg),
  ship_id: Int,
  timeout_ms: Int,
) -> Result(Nil, String) {
  process.call(sim, waiting: timeout_ms, sending: RequestUndock(ship_id, _))
}

/// Ask the sim for its current tick statistics (blocking call).
pub fn get_stats(sim: Subject(Msg), timeout_ms: Int) -> stats.StatsReply {
  process.call(sim, waiting: timeout_ms, sending: GetStats)
}

/// A registered snapshot listener: the subject to push to, the ship it
/// owns, and the monitor on its owning process that keys its removal.
type Client {
  Client(monitor: process.Monitor, subject: Subject(ClientMsg), ship_id: Int)
}

type State {
  State(
    self: Subject(Msg),
    world: World,
    ships: List(Ship),
    next_ship_id: Int,
    tick: Int,
    /// Monotonic time (us) when the tick loop started; scheduling anchor.
    start_us: Int,
    clients: List(Client),
    acc: stats.Accumulator,
  )
}

pub fn start(
  world: World,
) -> Result(actor.Started(Subject(Msg)), actor.StartError) {
  actor.new_with_initialiser(1000, fn(subject) {
    let state =
      State(
        self: subject,
        world: world,
        ships: [],
        next_ship_id: 1,
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

    AddShip(client, reply) -> {
      case process.subject_owner(client) {
        Ok(pid) -> {
          let t = int.to_float(state.tick) *. ship.dt
          let new_ship = ship.spawn_docked(state.next_ship_id, state.world, t)
          let state =
            State(
              ..state,
              ships: [new_ship, ..state.ships],
              next_ship_id: state.next_ship_id + 1,
              clients: [
                Client(
                  monitor: process.monitor(pid),
                  subject: client,
                  ship_id: new_ship.id,
                ),
                ..state.clients
              ],
            )
          process.send(reply, new_ship.id)
          io.println(
            "client connected ("
            <> int.to_string(list.length(state.clients))
            <> ")",
          )
          actor.continue(state)
        }
        // A subject whose owner is already dead will never fire ClientDown,
        // so spawning a ship for it would leave an un-cleanable ghost in
        // every snapshot. Don't spawn; the reply can't be received anyway.
        Error(Nil) -> actor.continue(state)
      }
    }

    SetControls(ship_id, rotate, thrust) -> {
      let ships =
        list.map(state.ships, fn(s) {
          case s.id == ship_id, s.dock {
            True, ship.Flying -> ship.set_controls(s, rotate, thrust)
            _, _ -> s
          }
        })
      actor.continue(State(..state, ships: ships))
    }

    RequestDock(ship_id, reply) -> {
      let t = int.to_float(state.tick) *. ship.dt
      case find_ship(state.ships, ship_id) {
        Error(Nil) -> {
          process.send(reply, Error("not_docked"))
          actor.continue(state)
        }
        Ok(found) ->
          case ship.try_dock(found, state.world, t) {
            Ok(updated) -> {
              process.send(reply, Ok(Nil))
              actor.continue(
                State(..state, ships: replace_ship(state.ships, updated)),
              )
            }
            Error(reason) -> {
              process.send(reply, Error(reason))
              actor.continue(state)
            }
          }
      }
    }

    RequestUndock(ship_id, reply) -> {
      let t = int.to_float(state.tick) *. ship.dt
      case find_ship(state.ships, ship_id) {
        Error(Nil) -> {
          process.send(reply, Error("not_docked"))
          actor.continue(state)
        }
        Ok(found) ->
          case ship.undock(found, state.world, t) {
            Ok(updated) -> {
              process.send(reply, Ok(Nil))
              actor.continue(
                State(..state, ships: replace_ship(state.ships, updated)),
              )
            }
            Error(reason) -> {
              process.send(reply, Error(reason))
              actor.continue(state)
            }
          }
      }
    }

    ClientDown(process.ProcessDown(monitor: monitor, ..)) -> {
      let #(down, remaining) =
        list.partition(state.clients, fn(c) { c.monitor == monitor })
      let down_ship_ids = list.map(down, fn(c) { c.ship_id })
      let ships =
        list.filter(state.ships, fn(s) { !list.contains(down_ship_ids, s.id) })
      io.println(
        "client disconnected (" <> int.to_string(list.length(remaining)) <> ")",
      )
      actor.continue(State(..state, clients: remaining, ships: ships))
    }
    // We only monitor processes, never ports.
    ClientDown(process.PortDown(..)) -> actor.continue(state)

    GetStats(reply) -> {
      process.send(reply, stats_reply(state))
      actor.continue(state)
    }
  }
}

fn find_ship(ships: List(Ship), ship_id: Int) -> Result(Ship, Nil) {
  list.find(ships, fn(s) { s.id == ship_id })
}

fn replace_ship(ships: List(Ship), updated: Ship) -> List(Ship) {
  list.map(ships, fn(s) {
    case s.id == updated.id {
      True -> updated
      False -> s
    }
  })
}

fn run_tick(state: State) -> actor.Next(State, Msg) {
  let started_us = clock.now_us()

  // 1. Advance the world.
  let tick = state.tick + 1
  let t = int.to_float(tick) *. ship.dt
  let ships = list.map(state.ships, fn(s) { ship.step(s, state.world, t) })

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
