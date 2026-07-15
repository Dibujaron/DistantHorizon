//// The simulation actor: owns the world (loaded once at startup), the ship
//// class every ship uses, and the lists of player ships and characters. It
//// drives the 60 Hz tick loop by sending itself `Tick` messages via
//// `process.send_after`, with drift correction (each tick is scheduled
//// against the loop's fixed start time, so per-tick timer error never
//// accumulates).
////
//// Every `snapshot_every` ticks (15 Hz) it serializes one exterior snapshot
//// and fans it out to every registered client subject, and separately
//// serializes one `interior` message per crewed ship, fanned out only to
//// the clients whose character is currently aboard that ship — the
//// interest-management boundary from DESIGN.md.
////
//// A WebSocket handler process joins the simulation by calling
//// `add_player`, which spawns it a ship docked at the world's spawn
//// station, a character seated at that ship's helm, and registers it for
//// snapshots in one call. `helm`/`dock`/`undock`/`move`/`sit`/`stand`/
//// `board` are all routed by character id; the sim resolves the
//// character's current ship itself, so a character's ship can change
//// (via `board`) without the caller needing to track it.
////
//// The sim monitors each handler process and, on exit (cleanly or by
//// crashing), removes its character and despawns any ship left with zero
//// characters aboard — so a pilot who disconnects mid-flight leaves a
//// walking crewmate on a still-flying ship, but the last character off a
//// ship despawns it.

import dh_server/character.{type Character}
import dh_server/clock
import dh_server/protocol
import dh_server/ship.{type Ship}
import dh_server/shipclass.{type ShipClass}
import dh_server/stats
import dh_server/world.{type World}
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
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
  /// spawn station, a character seated at that ship's helm, and register it
  /// for snapshots.
  AddPlayer(
    name: String,
    client: Subject(ClientMsg),
    reply: Subject(#(Int, Int)),
  )
  /// Set a character's helm input. Ignored unless the character is seated
  /// at a helm-kind console of a flying ship.
  SetControls(character_id: Int, rotate: Float, thrust: Float)
  /// Attempt to dock the character's ship at the nearest in-range station.
  RequestDock(character_id: Int, reply: Subject(Result(Nil, String)))
  /// Undock the character's ship.
  RequestUndock(character_id: Int, reply: Subject(Result(Nil, String)))
  /// Set a character's walk input. Ignored while seated.
  SetMove(character_id: Int, dx: Float, dy: Float)
  /// Attempt to sit a character at a console.
  RequestSit(
    character_id: Int,
    console: String,
    reply: Subject(protocol.SeatResult),
  )
  /// Stand a seated character up.
  RequestStand(character_id: Int, reply: Subject(protocol.SeatResult))
  /// Attempt to move a character to another ship docked at the same
  /// station as their own.
  RequestBoard(
    character_id: Int,
    ship_id: Int,
    reply: Subject(protocol.BoardResult),
  )
  /// A monitored client handler process exited (cleanly or by crashing).
  ClientDown(down: process.Down)
  /// Reply with current tick statistics.
  GetStats(reply: Subject(stats.StatsReply))
}

/// Messages the sim sends to connected client handler processes.
pub type ClientMsg {
  SendText(String)
}

/// Spawn a new ship docked at the world's spawn station, a character named
/// `name` seated at its helm, and register `client` to receive snapshots
/// and interior updates for as long as its owning process lives. Returns
/// `#(ship_id, character_id)`.
pub fn add_player(
  sim: Subject(Msg),
  name: String,
  client: Subject(ClientMsg),
  timeout_ms: Int,
) -> #(Int, Int) {
  process.call(sim, waiting: timeout_ms, sending: AddPlayer(name, client, _))
}

/// Set a character's helm input (cast). Clamped sim-side; silently ignored
/// unless the character is seated at a helm-kind console of a flying ship.
pub fn set_controls(
  sim: Subject(Msg),
  character_id: Int,
  rotate: Float,
  thrust: Float,
) -> Nil {
  process.send(sim, SetControls(character_id, rotate, thrust))
}

/// Attempt to dock the character's ship at the nearest in-range station
/// (blocking call). `Error("not_at_helm")` unless seated at the helm.
pub fn request_dock(
  sim: Subject(Msg),
  character_id: Int,
  timeout_ms: Int,
) -> Result(Nil, String) {
  process.call(sim, waiting: timeout_ms, sending: RequestDock(character_id, _))
}

/// Undock the character's ship (blocking call). `Error("not_at_helm")`
/// unless seated at the helm.
pub fn request_undock(
  sim: Subject(Msg),
  character_id: Int,
  timeout_ms: Int,
) -> Result(Nil, String) {
  process.call(sim, waiting: timeout_ms, sending: RequestUndock(character_id, _))
}

/// Set a character's walk input (cast). Clamped sim-side; ignored while
/// seated.
pub fn set_move(
  sim: Subject(Msg),
  character_id: Int,
  dx: Float,
  dy: Float,
) -> Nil {
  process.send(sim, SetMove(character_id, dx, dy))
}

/// Attempt to sit a character at `console` (blocking call).
pub fn request_sit(
  sim: Subject(Msg),
  character_id: Int,
  console: String,
  timeout_ms: Int,
) -> protocol.SeatResult {
  process.call(sim, waiting: timeout_ms, sending: RequestSit(
    character_id,
    console,
    _,
  ))
}

/// Stand a seated character up (blocking call).
pub fn request_stand(
  sim: Subject(Msg),
  character_id: Int,
  timeout_ms: Int,
) -> protocol.SeatResult {
  process.call(sim, waiting: timeout_ms, sending: RequestStand(character_id, _))
}

/// Attempt to board `ship_id` (blocking call): allowed when the
/// character's current ship and the target ship are both docked at the
/// same station.
pub fn request_board(
  sim: Subject(Msg),
  character_id: Int,
  ship_id: Int,
  timeout_ms: Int,
) -> protocol.BoardResult {
  process.call(sim, waiting: timeout_ms, sending: RequestBoard(
    character_id,
    ship_id,
    _,
  ))
}

/// Ask the sim for its current tick statistics (blocking call).
pub fn get_stats(sim: Subject(Msg), timeout_ms: Int) -> stats.StatsReply {
  process.call(sim, waiting: timeout_ms, sending: GetStats)
}

/// A registered listener: the subject to push to, the character it owns,
/// and the monitor on its owning process that keys its removal.
type Client {
  Client(
    monitor: process.Monitor,
    subject: Subject(ClientMsg),
    character_id: Int,
  )
}

type State {
  State(
    self: Subject(Msg),
    world: World,
    class: ShipClass,
    ships: List(Ship),
    next_ship_id: Int,
    characters: List(Character),
    next_character_id: Int,
    tick: Int,
    /// Monotonic time (us) when the tick loop started; scheduling anchor.
    start_us: Int,
    clients: List(Client),
    acc: stats.Accumulator,
  )
}

pub fn start(
  world: World,
  class: ShipClass,
) -> Result(actor.Started(Subject(Msg)), actor.StartError) {
  actor.new_with_initialiser(1000, fn(subject) {
    let state =
      State(
        self: subject,
        world: world,
        class: class,
        ships: [],
        next_ship_id: 1,
        characters: [],
        next_character_id: 1,
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

    AddPlayer(name, client, reply) -> {
      case process.subject_owner(client) {
        Ok(pid) -> {
          let t = int.to_float(state.tick) *. ship.dt
          let new_ship = ship.spawn_docked(state.next_ship_id, state.world, t)
          let new_character =
            character.spawn_seated_at_helm(
              state.next_character_id,
              name,
              new_ship.id,
              state.class.plan,
            )
          let state =
            State(
              ..state,
              ships: [new_ship, ..state.ships],
              next_ship_id: state.next_ship_id + 1,
              characters: [new_character, ..state.characters],
              next_character_id: state.next_character_id + 1,
              clients: [
                Client(
                  monitor: process.monitor(pid),
                  subject: client,
                  character_id: new_character.id,
                ),
                ..state.clients
              ],
            )
          process.send(reply, #(new_ship.id, new_character.id))
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

    SetControls(character_id, rotate, thrust) -> {
      case find_character(state.characters, character_id) {
        Error(Nil) -> actor.continue(state)
        Ok(char) ->
          case character.is_at_helm(char, state.class.plan) {
            False -> actor.continue(state)
            True -> {
              let ships =
                list.map(state.ships, fn(s) {
                  case s.id == char.ship_id, s.dock {
                    True, ship.Flying -> ship.set_controls(s, rotate, thrust)
                    _, _ -> s
                  }
                })
              actor.continue(State(..state, ships: ships))
            }
          }
      }
    }

    RequestDock(character_id, reply) ->
      with_helm_ship(state, character_id, reply, fn(state, found) {
        let t = int.to_float(state.tick) *. ship.dt
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
      })

    RequestUndock(character_id, reply) ->
      with_helm_ship(state, character_id, reply, fn(state, found) {
        let t = int.to_float(state.tick) *. ship.dt
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
      })

    SetMove(character_id, dx, dy) -> {
      let characters =
        list.map(state.characters, fn(c) {
          case c.id == character_id {
            True -> character.set_move(c, dx, dy)
            False -> c
          }
        })
      actor.continue(State(..state, characters: characters))
    }

    RequestSit(character_id, console, reply) -> {
      case find_character(state.characters, character_id) {
        Error(Nil) -> {
          process.send(
            reply,
            protocol.SeatResult(
              ok: False,
              reason: Some("unknown_console"),
              seat: None,
            ),
          )
          actor.continue(state)
        }
        Ok(char) -> {
          let occupied =
            list.any(state.characters, fn(c) {
              c.ship_id == char.ship_id && c.seat == Some(console)
            })
          case character.try_sit(char, state.class.plan, console, occupied) {
            Ok(updated) -> {
              process.send(
                reply,
                protocol.SeatResult(ok: True, reason: None, seat: updated.seat),
              )
              actor.continue(
                State(
                  ..state,
                  characters: replace_character(state.characters, updated),
                ),
              )
            }
            Error(reason) -> {
              process.send(
                reply,
                protocol.SeatResult(
                  ok: False,
                  reason: Some(reason),
                  seat: char.seat,
                ),
              )
              actor.continue(state)
            }
          }
        }
      }
    }

    RequestStand(character_id, reply) -> {
      case find_character(state.characters, character_id) {
        Error(Nil) -> {
          process.send(
            reply,
            protocol.SeatResult(
              ok: False,
              reason: Some("not_seated"),
              seat: None,
            ),
          )
          actor.continue(state)
        }
        Ok(char) ->
          case character.stand(char) {
            Ok(updated) -> {
              process.send(
                reply,
                protocol.SeatResult(ok: True, reason: None, seat: updated.seat),
              )
              actor.continue(
                State(
                  ..state,
                  characters: replace_character(state.characters, updated),
                ),
              )
            }
            Error(reason) -> {
              process.send(
                reply,
                protocol.SeatResult(
                  ok: False,
                  reason: Some(reason),
                  seat: char.seat,
                ),
              )
              actor.continue(state)
            }
          }
      }
    }

    RequestBoard(character_id, target_ship_id, reply) -> {
      case find_character(state.characters, character_id) {
        Error(Nil) -> {
          process.send(
            reply,
            protocol.BoardResult(
              ok: False,
              reason: Some("unknown_ship"),
              ship_id: 0,
            ),
          )
          actor.continue(state)
        }
        Ok(char) -> handle_board(state, char, target_ship_id, reply)
      }
    }

    ClientDown(process.ProcessDown(monitor: monitor, ..)) -> {
      let #(down, remaining) =
        list.partition(state.clients, fn(c) { c.monitor == monitor })
      let down_character_ids = list.map(down, fn(c) { c.character_id })
      let characters =
        list.filter(state.characters, fn(c) {
          !list.contains(down_character_ids, c.id)
        })
      let crewed_ship_ids =
        list.map(characters, fn(c) { c.ship_id }) |> list.unique
      let ships =
        list.filter(state.ships, fn(s) { list.contains(crewed_ship_ids, s.id) })
      io.println(
        "client disconnected (" <> int.to_string(list.length(remaining)) <> ")",
      )
      actor.continue(
        State(..state, clients: remaining, ships: ships, characters: characters),
      )
    }
    // We only monitor processes, never ports.
    ClientDown(process.PortDown(..)) -> actor.continue(state)

    GetStats(reply) -> {
      process.send(reply, stats_reply(state))
      actor.continue(state)
    }
  }
}

/// Shared helm-seat gating for `RequestDock`/`RequestUndock`: resolve the
/// character, require it to be seated at a helm-kind console, resolve its
/// ship, then hand both to `next`. Replies `Error("not_at_helm")` /
/// `Error("not_docked")` and leaves state untouched on any resolution
/// failure.
fn with_helm_ship(
  state: State,
  character_id: Int,
  reply: Subject(Result(Nil, String)),
  next: fn(State, Ship) -> actor.Next(State, Msg),
) -> actor.Next(State, Msg) {
  case find_character(state.characters, character_id) {
    Error(Nil) -> {
      process.send(reply, Error("not_docked"))
      actor.continue(state)
    }
    Ok(char) ->
      case character.is_at_helm(char, state.class.plan) {
        False -> {
          process.send(reply, Error("not_at_helm"))
          actor.continue(state)
        }
        True ->
          case find_ship(state.ships, char.ship_id) {
            Error(Nil) -> {
              process.send(reply, Error("not_docked"))
              actor.continue(state)
            }
            Ok(found) -> next(state, found)
          }
      }
  }
}

fn handle_board(
  state: State,
  char: Character,
  target_ship_id: Int,
  reply: Subject(protocol.BoardResult),
) -> actor.Next(State, Msg) {
  case char.ship_id == target_ship_id {
    True -> {
      process.send(
        reply,
        protocol.BoardResult(
          ok: False,
          reason: Some("same_ship"),
          ship_id: char.ship_id,
        ),
      )
      actor.continue(state)
    }
    False ->
      case find_ship(state.ships, target_ship_id) {
        Error(Nil) -> {
          process.send(
            reply,
            protocol.BoardResult(
              ok: False,
              reason: Some("unknown_ship"),
              ship_id: char.ship_id,
            ),
          )
          actor.continue(state)
        }
        Ok(target) -> {
          let assert Ok(current) = find_ship(state.ships, char.ship_id)
          case docked_at_same_station(current, target) {
            False -> {
              process.send(
                reply,
                protocol.BoardResult(
                  ok: False,
                  reason: Some("not_docked_together"),
                  ship_id: char.ship_id,
                ),
              )
              actor.continue(state)
            }
            True -> {
              let old_ship_id = char.ship_id
              let #(sx, sy) = character.spawn_position(state.class.plan)
              // Move input is cleared, not just the seat (mirroring
              // character.gleam's try_sit/stand): input held at the moment
              // of boarding was buffered against the old ship's deck, and
              // without the reset it would resume walking the character
              // away from the new ship's spawn tile on the very next tick.
              let boarded =
                character.Character(
                  ..char,
                  ship_id: target.id,
                  x: sx,
                  y: sy,
                  seat: None,
                  move_dx: 0.0,
                  move_dy: 0.0,
                )
              let characters = replace_character(state.characters, boarded)
              // A ship left with zero characters aboard despawns
              // immediately.
              let old_ship_still_crewed =
                list.any(characters, fn(c) { c.ship_id == old_ship_id })
              let ships = case old_ship_still_crewed {
                True -> state.ships
                False -> list.filter(state.ships, fn(s) { s.id != old_ship_id })
              }
              process.send(
                reply,
                protocol.BoardResult(ok: True, reason: None, ship_id: target.id),
              )
              actor.continue(
                State(..state, characters: characters, ships: ships),
              )
            }
          }
        }
      }
  }
}

fn docked_at_same_station(a: Ship, b: Ship) -> Bool {
  case a.dock, b.dock {
    ship.Docked(station_a), ship.Docked(station_b) -> station_a == station_b
    _, _ -> False
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

fn find_character(
  characters: List(Character),
  character_id: Int,
) -> Result(Character, Nil) {
  list.find(characters, fn(c) { c.id == character_id })
}

fn replace_character(
  characters: List(Character),
  updated: Character,
) -> List(Character) {
  list.map(characters, fn(c) {
    case c.id == updated.id {
      True -> updated
      False -> c
    }
  })
}

fn run_tick(state: State) -> actor.Next(State, Msg) {
  let started_us = clock.now_us()

  // 1. Advance the world and every character.
  let tick = state.tick + 1
  let t = int.to_float(tick) *. ship.dt
  let ships = list.map(state.ships, fn(s) { ship.step(s, state.world, t) })
  let characters =
    list.map(state.characters, fn(c) { character.step(c, state.class.plan) })

  // 2. Broadcast at 15 Hz (skip serialization with no listeners): one
  // shared exterior snapshot to everyone, plus one interior message per
  // crewed ship fanned out only to that ship's crew.
  case tick % snapshot_every == 0 && state.clients != [] {
    True -> {
      let snapshot = protocol.encode_snapshot(tick, ships)
      list.each(state.clients, fn(client) {
        process.send(client.subject, SendText(snapshot))
      })
      broadcast_interiors(state.clients, characters, tick)
    }
    False -> Nil
  }

  // 3. Record how long the work took.
  let acc = stats.record(state.acc, clock.now_us() - started_us)
  let state =
    State(..state, ships: ships, characters: characters, tick: tick, acc: acc)

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

/// Serialize one `interior` message per crewed ship and send it only to
/// the clients whose character is currently aboard that ship.
fn broadcast_interiors(
  clients: List(Client),
  characters: List(Character),
  tick: Int,
) -> Nil {
  let crewed_ship_ids = list.map(characters, fn(c) { c.ship_id }) |> list.unique
  let texts =
    list.map(crewed_ship_ids, fn(ship_id) {
      let crew = list.filter(characters, fn(c) { c.ship_id == ship_id })
      #(ship_id, protocol.encode_interior(tick, ship_id, crew))
    })
  list.each(clients, fn(client) {
    case find_character(characters, client.character_id) {
      Error(Nil) -> Nil
      Ok(char) ->
        case list.find(texts, fn(t) { t.0 == char.ship_id }) {
          Error(Nil) -> Nil
          Ok(#(_, text)) -> process.send(client.subject, SendText(text))
        }
    }
  })
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
