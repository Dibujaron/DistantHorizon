//// The simulation actor: owns the world (loaded once at startup), the content
//// registries (hulls, modules, parts) and the lists of player ships and
//// characters. Since M4 a hull is PER-SHIP data: every ship carries its own
//// resolved `loadout.Fit` in `fits`, keyed by ship id, and every consumer of
//// what used to be one world-wide `ShipClass` looks its ship's fit up through
//// `fit_for`. A ship whose fit is missing is skipped, never crashed on. It
//// drives the 60 Hz tick loop by sending itself `Tick` messages via
//// `process.send_after`, with drift correction (each tick is scheduled
//// against the loop's fixed start time, so per-tick timer error never
//// accumulates).
////
//// Every `snapshot_every` ticks (15 Hz) it serializes one exterior snapshot
//// and fans it out to every registered client subject, and separately
//// serializes per-scope messages fanned out only to the clients they
//// concern — the interest-management boundary from DESIGN.md: `walkers` per
//// occupied space (a flying ship's interior, or a station's stitched
//// composite) to the bodies currently in it, `cargo` per crewed ship to its
//// whole crew (by membership, wherever their bodies are), and `market` per
//// occupied station's market to that station's occupants.
////
//// Stitched interiors (M3.1): each concourse keeps one `StationSpace` — its
//// composite plan (concourse + every docked ship moored at a berth) and a
//// monotonically increasing epoch, rebuilt on every dock/undock/despawn. A
//// body's place is `Aboard` (in a *flying* ship's frame) or `OnStation`
//// (in a station's composite frame, which covers standing aboard a *docked*
//// ship). Crew membership (`ship_id`) transfers only at the undock split:
//// bodies standing on ship X's moored tiles leave with X.
////
//// A WebSocket handler process joins the simulation by calling
//// `add_player`, which claims a free berth at the spawn station (refusing
//// with `Error("station_full")` when none is free), spawns it a ship docked
//// there, a character seated at that ship's namespaced helm in the station
//// composite, and registers it for snapshots in one call.
//// `helm`/`dock`/`undock`/`move`/`sit`/`stand`/`buy`/`sell`/`refit` are all
//// routed by character id. Helm control (`SetControls`, dock) additionally
//// requires the body to be aboard (flying); undock requires being seated at
//// a docked ship's namespaced helm in the station composite; `refit` requires
//// only that the character's ship is docked, and re-resolves her fit in place.
////
//// The sim monitors each handler process and, on exit (cleanly or by
//// crashing), removes its character and despawns any ship left with zero
//// *crew* — characters whose `ship_id` still references it, regardless of
//// whether their bodies are aboard or ashore — so a pilot who disconnects
//// mid-flight leaves a walking crewmate on a still-flying ship, a ship
//// whose whole crew has gone ashore stays alive, and the last crew member
//// leaving despawns it and rebuilds the station space without its mooring.

import dh_server/cargo
import dh_server/character.{type Character}
import dh_server/clock
import dh_server/composite
import dh_server/deckplan
import dh_server/glyphs
import dh_server/hull
import dh_server/loadout
import dh_server/market
import dh_server/module
import dh_server/noise
import dh_server/part
import dh_server/protocol
import dh_server/ship.{type Ship}
import dh_server/shipclass.{type ShipClass}
import dh_server/stats
import dh_server/world.{type World}
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result

pub const tick_rate = 60

/// Broadcast a snapshot every 4th tick: 60 / 4 = 15 Hz.
const snapshot_every = 4

/// Log tick health to stderr every 300 ticks = every 5 s.
const log_every = 300

const us_per_second = 1_000_000

pub opaque type Msg {
  /// Advance the simulation by one step (self-scheduled).
  Tick
  /// A WebSocket connection has logged in: claim a free berth at the spawn
  /// station (or refuse with `Error("station_full")`), resolve the spawn
  /// hull's default loadout (or refuse with `loadout.resolve`'s own reason),
  /// spawn it a ship docked there, a character seated at that ship's
  /// namespaced helm, and register it for snapshots.
  AddPlayer(
    name: String,
    client: Subject(ClientMsg),
    reply: Subject(Result(#(Int, Int), String)),
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
  /// A monitored client handler process exited (cleanly or by crashing).
  ClientDown(down: process.Down)
  /// Reply with current tick statistics.
  GetStats(reply: Subject(stats.StatsReply))
  /// Buy `quantity` of `commodity` at the broker the character is seated at.
  RequestBuy(
    character_id: Int,
    commodity: String,
    quantity: Int,
    reply: Subject(protocol.TradeResult),
  )
  /// Sell, mirror of RequestBuy.
  RequestSell(
    character_id: Int,
    commodity: String,
    quantity: Int,
    reply: Subject(protocol.TradeResult),
  )
  /// The market of the station the character is at (ashore, or docked
  /// aboard). Error("no_market") when neither applies.
  RequestMarket(
    character_id: Int,
    reply: Subject(Result(market.Market, String)),
  )
  /// The resolved class of one ship — the `welcome` frame's `ship_class`.
  RequestShipClass(ship_id: Int, reply: Subject(Result(ShipClass, Nil)))
  /// Replace the character's ship's WHOLE loadout (docked only, free).
  RequestRefit(
    character_id: Int,
    modules: List(#(String, String)),
    parts: List(#(String, String)),
    reply: Subject(Result(Nil, String)),
  )
}

/// Messages the sim sends to connected client handler processes.
pub type ClientMsg {
  SendText(String)
}

/// Claim a free berth at the world's spawn station and spawn a new ship
/// docked there, a character named `name` seated at its namespaced helm in
/// the station composite, and register `client` to receive snapshots and
/// walker updates for as long as its owning process lives. Returns
/// `Ok(#(ship_id, character_id))`, `Error("station_full")` when the spawn
/// station has no free berth, or a `loadout.resolve` refusal reason
/// (`"unknown_hull:<id>"`, `"tag_deficit:<tag>"`, …) when the spawn hull's
/// default loadout does not resolve — spawn refuses rather than falling back
/// to some default hull.
pub fn add_player(
  sim: Subject(Msg),
  name: String,
  client: Subject(ClientMsg),
  timeout_ms: Int,
) -> Result(#(Int, Int), String) {
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
/// (blocking call). `Error("already_docked")` if already docked and seated
/// at that ship's namespaced helm; `Error("not_at_helm")` if not seated at
/// a helm at all.
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

/// Ask the sim for its current tick statistics (blocking call).
pub fn get_stats(sim: Subject(Msg), timeout_ms: Int) -> stats.StatsReply {
  process.call(sim, waiting: timeout_ms, sending: GetStats)
}

/// Buy at the seated broker (blocking call).
pub fn request_buy(
  sim: Subject(Msg),
  character_id: Int,
  commodity: String,
  quantity: Int,
  timeout_ms: Int,
) -> protocol.TradeResult {
  process.call(sim, waiting: timeout_ms, sending: RequestBuy(
    character_id,
    commodity,
    quantity,
    _,
  ))
}

/// Sell at the seated broker (blocking call).
pub fn request_sell(
  sim: Subject(Msg),
  character_id: Int,
  commodity: String,
  quantity: Int,
  timeout_ms: Int,
) -> protocol.TradeResult {
  process.call(sim, waiting: timeout_ms, sending: RequestSell(
    character_id,
    commodity,
    quantity,
    _,
  ))
}

/// The market where the character is (blocking call).
pub fn request_market(
  sim: Subject(Msg),
  character_id: Int,
  timeout_ms: Int,
) -> Result(market.Market, String) {
  process.call(sim, waiting: timeout_ms, sending: RequestMarket(character_id, _))
}

/// The resolved `ShipClass` of `ship_id` (blocking call), or `Error(Nil)` if
/// the sim has no fit for it — which since M4 is the only place the wire's
/// `ship_class` can come from, because a hull is per-ship data and there is no
/// single world-wide class to hand out any more.
pub fn ship_class(
  sim: Subject(Msg),
  ship_id: Int,
  timeout_ms: Int,
) -> Result(ShipClass, Nil) {
  process.call(sim, waiting: timeout_ms, sending: RequestShipClass(ship_id, _))
}

/// Replace the character's ship's whole loadout (blocking call). Docked only
/// and free in this iteration — a later one adds shipyard stations, a refit
/// console to walk to and a bill. `Error` carries `"not_docked"`,
/// `"hold_over_capacity"`, `composite.build`'s reason from the pre-flight, or
/// `loadout.resolve`'s own reason verbatim; a refused refit leaves the ship
/// exactly as it was.
pub fn request_refit(
  sim: Subject(Msg),
  character_id: Int,
  modules: List(#(String, String)),
  parts: List(#(String, String)),
  timeout_ms: Int,
) -> Result(Nil, String) {
  process.call(sim, waiting: timeout_ms, sending: RequestRefit(
    character_id,
    modules,
    parts,
    _,
  ))
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

/// One station's walkable space: its composite plan and a monotonically
/// increasing epoch, bumped on every rebuild (dock, undock, despawn).
/// Clients use the epoch to drop in-flight walker updates serialized
/// against a previous frame.
type StationSpace {
  StationSpace(station_id: String, epoch: Int, composite: composite.Composite)
}

type State {
  State(
    self: Subject(Msg),
    world: World,
    /// Every hull, module and part the world knows — the content registries.
    hulls: dict.Dict(String, hull.Hull),
    modules: dict.Dict(String, module.Module),
    parts: dict.Dict(String, part.Part),
    glyphs: glyphs.Registry,
    /// The hull new ships spawn on.
    spawn_hull: String,
    /// Resolved fit per ship id. A ship without one cannot be simulated, so
    /// spawn refuses rather than falling back to a default.
    fits: List(#(Int, loadout.Fit)),
    ships: List(Ship),
    next_ship_id: Int,
    characters: List(Character),
    next_character_id: Int,
    tick: Int,
    /// Monotonic time (us) when the tick loop started; scheduling anchor.
    start_us: Int,
    clients: List(Client),
    acc: stats.Accumulator,
    markets: List(market.Market),
    price_epoch: Int,
    regen_epoch: Int,
    /// One composite space per concourse, rebuilt on dock/undock/despawn.
    spaces: List(StationSpace),
  )
}

/// Start the simulation actor over the world and the content registries.
/// `spawn_hull` names the hull in `hulls` that new ships are fitted from; every
/// ship resolves its own `loadout.Fit` at spawn, so nothing here is a
/// world-wide class any more.
pub fn start(
  world: World,
  hulls: dict.Dict(String, hull.Hull),
  modules: dict.Dict(String, module.Module),
  parts: dict.Dict(String, part.Part),
  registry: glyphs.Registry,
  spawn_hull: String,
) -> Result(actor.Started(Subject(Msg)), actor.StartError) {
  actor.new_with_initialiser(1000, fn(subject) {
    let state =
      State(
        self: subject,
        world: world,
        hulls: hulls,
        modules: modules,
        parts: parts,
        glyphs: registry,
        spawn_hull: spawn_hull,
        fits: [],
        ships: [],
        next_ship_id: 1,
        characters: [],
        next_character_id: 1,
        tick: 0,
        start_us: clock.now_us(),
        clients: [],
        acc: stats.new(),
        markets: market.init(world),
        price_epoch: 0,
        regen_epoch: 0,
        spaces: initial_spaces(world),
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
        // A subject whose owner is already dead will never fire ClientDown,
        // so spawning a ship for it would leave an un-cleanable ghost in
        // every snapshot. Don't spawn; the reply can't be received anyway.
        Error(Nil) -> actor.continue(state)
        Ok(pid) ->
          case
            free_berth(state, state.next_ship_id, state.world.spawn_station)
          {
            Error(_) -> {
              process.send(reply, Error("station_full"))
              actor.continue(state)
            }
            Ok(berth) ->
              // The fit comes first: a ship whose loadout does not resolve is
              // not simulable at all, so the login is refused with the
              // resolver's own reason rather than spawned onto a fallback hull.
              case default_fit(state, state.spawn_hull) {
                Error(reason) -> {
                  process.send(reply, Error(reason))
                  actor.continue(state)
                }
                Ok(fit) -> {
                  let ship_id = state.next_ship_id
                  let t = int.to_float(state.tick) *. ship.dt
                  let new_ship =
                    ship.spawn_docked(
                      ship_id,
                      state.world,
                      t,
                      berth,
                      fit.class.dock_port_orientation,
                      fit.class.dock_standoff,
                    )
                  // Rebuild the spawn station's composite with the new mooring
                  // before placing the character in the composite frame. The
                  // fit is registered first: the rebuild reads it back out of
                  // `fits` to stitch this ship's own plan into the composite.
                  // Adding a mooring CAN block a berth (the ships already
                  // moored here wear their own durable fits), so the login is
                  // refused with the composite's reason rather than panicking
                  // the actor out from under everyone already aboard.
                  case
                    try_rebuild_space(
                      State(
                        ..state,
                        ships: [new_ship, ..state.ships],
                        next_ship_id: ship_id + 1,
                        fits: [#(ship_id, fit), ..state.fits],
                      ),
                      state.world.spawn_station,
                    )
                  {
                    Error(reason) -> {
                      process.send(reply, Error(reason))
                      actor.continue(state)
                    }
                    Ok(state) -> {
                      let assert Ok(space) =
                        find_space(state.spaces, state.world.spawn_station)
                      // The composite carries the moored (rotated + translated)
                      // console positions — look the helm up there by its
                      // namespaced id rather than re-deriving the transform.
                      let assert Ok(class_helm) =
                        deckplan.find_console_of_kind(fit.class.plan, "helm")
                      let assert Ok(helm) =
                        deckplan.find_console(
                          space.composite.plan,
                          composite.namespace_id(new_ship.id, class_helm.id),
                        )
                      let #(hx, hy) = deckplan.tile_center(helm.x, helm.y)
                      let new_character =
                        character.Character(
                          id: state.next_character_id,
                          name: name,
                          ship_id: new_ship.id,
                          place: character.OnStation(state.world.spawn_station),
                          x: hx,
                          y: hy,
                          // The composite helm console carries its composite deck.
                          deck: helm.deck,
                          // helm.id is already the namespaced composite id.
                          seat: Some(helm.id),
                          move_dx: 0.0,
                          move_dy: 0.0,
                        )
                      let state =
                        State(
                          ..state,
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
                      process.send(reply, Ok(#(new_ship.id, new_character.id)))
                      // Everyone in the spawn station's space (including the new
                      // client) gets the new plan: a ship just moored on.
                      push_space(
                        state,
                        protocol.StationSpace(state.world.spawn_station),
                      )
                      io.println_error(
                        "client connected ("
                        <> int.to_string(list.length(state.clients))
                        <> ")",
                      )
                      actor.continue(state)
                    }
                  }
                }
              }
          }
      }
    }

    SetControls(character_id, rotate, thrust) -> {
      case find_character(state.characters, character_id) {
        Error(Nil) -> actor.continue(state)
        Ok(char) ->
          // Helm gating reads the character's OWN ship's resolved plan; a ship
          // with no fit is not simulable, so its helm simply does not answer.
          case fit_for(state, char.ship_id) {
            Error(Nil) -> actor.continue(state)
            Ok(fit) ->
              case
                char.place == character.Aboard
                && character.is_at_helm(char, fit.class.plan)
              {
                False -> actor.continue(state)
                True -> {
                  let ships =
                    list.map(state.ships, fn(s) {
                      case s.id == char.ship_id, s.dock {
                        True, ship.Flying ->
                          ship.set_controls(s, rotate, thrust)
                        _, _ -> s
                      }
                    })
                  actor.continue(State(..state, ships: ships))
                }
              }
          }
      }
    }

    RequestDock(character_id, reply) ->
      case already_docked_at_helm(state, character_id) {
        True -> {
          process.send(reply, Error("already_docked"))
          actor.continue(state)
        }
        False ->
          with_helm_ship(state, character_id, reply, fn(state, found, fit) {
            let t = int.to_float(state.tick) *. ship.dt
            case
              ship.try_dock(
                found,
                state.world,
                t,
                free_berth(state, found.id, _),
                fit.class.dock_port_orientation,
                fit.class.dock_standoff,
              )
            {
              Error(reason) -> {
                process.send(reply, Error(reason))
                actor.continue(state)
              }
              Ok(docked) -> {
                let assert ship.Docked(station_id, _) = docked.dock
                case
                  State(..state, ships: replace_ship(state.ships, docked))
                  |> try_rebuild_space(station_id)
                {
                  // A fit travels: this hull may be wearing a footprint that
                  // was only ever pre-flighted against the station she was
                  // refitted at, and it does not stitch HERE. Refuse with the
                  // composite's own reason (`dock_result` publishes
                  // `berth_blocked`) and leave her flying — nothing has been
                  // committed at this point but a local `docked` value.
                  Error(reason) -> {
                    process.send(reply, Error(reason))
                    actor.continue(state)
                  }
                  Ok(state) -> {
                    // Join: every crew body aboard steps into the composite
                    // frame, seats namespaced, positions offset by the new
                    // mooring.
                    let assert Ok(space) = find_space(state.spaces, station_id)
                    let assert Ok(mooring) =
                      composite.find_mooring(space.composite, docked.id)
                    let characters =
                      list.map(state.characters, fn(c) {
                        case
                          c.ship_id == docked.id && c.place == character.Aboard
                        {
                          False -> c
                          True -> {
                            // Ship frame -> moored (rotated) frame + offset, and
                            // the body's ship deck -> its composite deck.
                            let #(rx, ry) =
                              composite.from_ship_frame(
                                composite.plan_width(fit.class.plan),
                                c.x,
                                c.y,
                              )
                            character.Character(
                              ..c,
                              place: character.OnStation(station_id),
                              x: rx +. int.to_float(mooring.dx),
                              y: ry +. int.to_float(mooring.dy),
                              deck: composite.composite_deck_of(mooring, c.deck),
                              seat: option.map(c.seat, composite.namespace_id(
                                docked.id,
                                _,
                              )),
                            )
                          }
                        }
                      })
                    let state = State(..state, characters: characters)
                    process.send(reply, Ok(Nil))
                    push_space(state, protocol.StationSpace(station_id))
                    actor.continue(state)
                  }
                }
              }
            }
          })
      }

    RequestUndock(character_id, reply) -> {
      let fail = fn(reason) {
        process.send(reply, Error(reason))
        actor.continue(state)
      }
      case find_character(state.characters, character_id) {
        Error(Nil) -> fail("not_docked")
        Ok(char) ->
          case char.place, char.seat {
            character.OnStation(station_id), Some(seat_id) ->
              case composite.parse_namespaced(seat_id) {
                Error(Nil) -> fail("not_at_helm")
                // The seat is namespaced by the ship it belongs to, so the
                // console is resolved against THAT ship's own resolved plan.
                Ok(#(target_ship_id, console_id)) ->
                  case fit_for(state, target_ship_id) {
                    Error(Nil) -> fail("not_at_helm")
                    Ok(fit) ->
                      case deckplan.find_console(fit.class.plan, console_id) {
                        Error(Nil) -> fail("not_at_helm")
                        Ok(console) if console.kind != "helm" ->
                          fail("not_at_helm")
                        Ok(_) ->
                          case find_ship(state.ships, target_ship_id) {
                            Error(Nil) -> fail("not_docked")
                            Ok(target) ->
                              handle_undock_split(
                                state,
                                station_id,
                                target,
                                fit,
                                reply,
                              )
                          }
                      }
                  }
              }
            _, _ -> fail("not_at_helm")
          }
      }
    }

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
              character.same_place(c, char) && c.seat == Some(console)
            })
          case plan_for(state, char) {
            Error(Nil) -> {
              process.send(
                reply,
                protocol.SeatResult(
                  ok: False,
                  reason: Some("unknown_console"),
                  seat: char.seat,
                ),
              )
              actor.continue(state)
            }
            Ok(plan) ->
              case character.try_sit(char, plan, console, occupied) {
                Ok(updated) -> {
                  process.send(
                    reply,
                    protocol.SeatResult(
                      ok: True,
                      reason: None,
                      seat: updated.seat,
                    ),
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
      // Every station that just lost a docked mooring rebuilds and re-pushes
      // its plan (computed from the pre-filter ships against the surviving
      // crew ids).
      let despawned_station_ids =
        list.filter_map(state.ships, fn(s) {
          case list.contains(crewed_ship_ids, s.id), s.dock {
            False, ship.Docked(station_id, _) -> Ok(station_id)
            _, _ -> Error(Nil)
          }
        })
        |> list.unique
      let state =
        State(
          ..state,
          clients: remaining,
          ships: ships,
          characters: characters,
          fits: prune_fits(state.fits, ships),
        )
      let state = list.fold(despawned_station_ids, state, rebuild_space)
      list.each(despawned_station_ids, fn(sid) {
        push_space(state, protocol.StationSpace(sid))
      })
      io.println_error(
        "client disconnected (" <> int.to_string(list.length(remaining)) <> ")",
      )
      actor.continue(state)
    }
    // We only monitor processes, never ports.
    ClientDown(process.PortDown(..)) -> actor.continue(state)

    GetStats(reply) -> {
      process.send(reply, stats_reply(state))
      actor.continue(state)
    }

    RequestBuy(character_id, commodity, quantity, reply) ->
      handle_trade(state, character_id, commodity, quantity, True, reply)

    RequestSell(character_id, commodity, quantity, reply) ->
      handle_trade(state, character_id, commodity, quantity, False, reply)

    RequestMarket(character_id, reply) -> {
      let result = case find_character(state.characters, character_id) {
        Error(Nil) -> Error("no_market")
        Ok(char) ->
          case market_station_for(state, char) {
            Error(Nil) -> Error("no_market")
            Ok(station_id) ->
              find_market(state.markets, station_id)
              |> result.replace_error("no_market")
          }
      }
      process.send(reply, result)
      actor.continue(state)
    }

    RequestShipClass(ship_id, reply) -> {
      process.send(
        reply,
        fit_for(state, ship_id) |> result.map(fn(f) { f.class }),
      )
      actor.continue(state)
    }

    RequestRefit(character_id, modules, parts, reply) ->
      handle_refit(state, character_id, modules, parts, reply)
  }
}

/// Replace one ship's whole loadout. Docked only and free: shipyard stations,
/// a refit console to walk to, per-station part catalogs and the bill are a
/// later iteration's job, so any crew member of a moored ship can refit her
/// from anywhere in the station's space.
///
/// Every refusal path replies and returns the state UNCHANGED. The new fit is
/// resolved in full — the hold measured against it, and the station's composite
/// pre-flighted with it — before a single field is written back, so there is no
/// window in which a refused refit could leave a half-applied ship behind.
///
/// The hull is taken from the ship's CURRENT loadout, never from the message: a
/// refit changes what she is fitted with, never which hull she is.
///
/// `not_docked` is also the answer to a missing character or ship — degenerate
/// conditions that are not really about dock state, but for which there is
/// nothing truer to tell a client.
fn handle_refit(
  state: State,
  character_id: Int,
  modules: List(#(String, String)),
  parts: List(#(String, String)),
  reply: Subject(Result(Nil, String)),
) -> actor.Next(State, Msg) {
  let fail = fn(reason) {
    process.send(reply, Error(reason))
    actor.continue(state)
  }
  case find_character(state.characters, character_id) {
    Error(Nil) -> fail("not_docked")
    Ok(char) ->
      case find_ship(state.ships, char.ship_id) {
        Error(Nil) -> fail("not_docked")
        Ok(s) ->
          case s.dock {
            // Dockside work: you do not swap an engine under way.
            ship.Flying -> fail("not_docked")
            ship.Docked(station_id, _) ->
              case fit_for(state, s.id) {
                // A ship with no resolved fit has no hull id to refit onto.
                // Unreachable while spawn refuses an unresolvable loadout, but
                // answered rather than crashed on.
                Error(Nil) -> fail("no_fit")
                Ok(current) -> {
                  let lo =
                    loadout.Loadout(
                      hull: current.loadout.hull,
                      modules: modules,
                      parts: parts,
                    )
                  case dict.get(state.hulls, lo.hull) {
                    Error(Nil) -> fail("unknown_hull:" <> lo.hull)
                    Ok(h) ->
                      case
                        loadout.resolve(
                          state.glyphs,
                          h,
                          state.modules,
                          state.parts,
                          lo,
                        )
                      {
                        // The resolver's reason travels to the player verbatim.
                        Error(reason) -> fail(reason)
                        Ok(fit) ->
                          case
                            cargo.hold_total(s) + cargo.incoming_total(s)
                            > fit.class.cargo_capacity
                          {
                            // Silently deleting a player's cargo is not an
                            // acceptable failure mode: sell down first.
                            True -> fail("hold_over_capacity")
                            False ->
                              case
                                composite_survives(state, s.id, station_id, fit)
                              {
                                // The composite's own reason travels to the
                                // player verbatim too.
                                Error(reason) -> fail(reason)
                                Ok(Nil) ->
                                  commit_refit(
                                    state,
                                    s.id,
                                    station_id,
                                    fit,
                                    reply,
                                  )
                              }
                          }
                      }
                  }
                }
              }
          }
      }
  }
}

/// Would `station_id`'s composite still stitch together with `ship_id` wearing
/// `fit`? A refit CAN move a ship relative to her berth: the mooring tile is
/// re-derived from the STAMPED map, and a module is free to draw a docking port
/// or a spawn glyph inside its own slot region — `loadout.check_bounds` only
/// asks that an overlay cell land on that slot's marker, never which glyph it
/// is. A relocated mooring shifts the whole footprint, which can then collide
/// with the concourse or block its own docking tube.
///
/// `rebuild_space` cannot refuse on the commit path — it keeps the old space
/// — so the refit verb pre-flights the same build against the PROSPECTIVE fits
/// here and refuses (`berth_blocked` / `unknown_berth` / `no_concourse_deck`)
/// rather than committing a fit whose station would then be left rendering a
/// composite that no longer matches what is moored in it. The two cases
/// `rebuild_space` treats as no-ops — no such station, or a station with no
/// concourse — have nothing to fail, so they pass.
///
/// This buys a guarantee about the ships docked here AT THIS MOMENT, and no
/// more: the fit it commits is durable, so a hull that arrives later can find
/// the berth line no longer fits her. That case belongs to the dock verb,
/// which re-checks the same build on arrival.
fn composite_survives(
  state: State,
  ship_id: Int,
  station_id: String,
  fit: loadout.Fit,
) -> Result(Nil, String) {
  let prospective = State(..state, fits: replace_fit(state.fits, ship_id, fit))
  case world.get_station(state.world, station_id) {
    Error(Nil) -> Ok(Nil)
    Ok(station) ->
      case station.concourse {
        None -> Ok(Nil)
        Some(concourse) ->
          composite.build(
            concourse,
            world.station_berths(station),
            docked_ships_at(prospective, station_id),
          )
          |> result.replace(Nil)
      }
  }
}

/// Apply a resolved refit: swap the ship's entry in `fits`, then rebuild the
/// station's composite through the same `rebuild_space` + `push_space` path
/// dock/undock use. The rebuild is not optional — the composite stitches each
/// docked ship's own plan in, so a refit that changed only the fit would leave
/// everyone aboard and ashore rendering the old deck. The ship's crew also get
/// a `ship_fit` carrying the new class, wherever their bodies are.
///
/// Only reached once `composite_survives` has already built this exact
/// composite, so the rebuild here cannot fail.
fn commit_refit(
  state: State,
  ship_id: Int,
  station_id: String,
  fit: loadout.Fit,
  reply: Subject(Result(Nil, String)),
) -> actor.Next(State, Msg) {
  let state =
    State(..state, fits: replace_fit(state.fits, ship_id, fit))
    |> rebuild_space(station_id)
  process.send(reply, Ok(Nil))
  push_ship_fit(state, ship_id, fit)
  push_space(state, protocol.StationSpace(station_id))
  actor.continue(state)
}

fn replace_fit(
  fits: List(#(Int, loadout.Fit)),
  ship_id: Int,
  fit: loadout.Fit,
) -> List(#(Int, loadout.Fit)) {
  list.map(fits, fn(entry) {
    case entry.0 == ship_id {
      True -> #(ship_id, fit)
      False -> entry
    }
  })
}

/// Push a `ship_fit` to one ship's *crew* — by membership, wherever their
/// bodies are, the same scope `cargo` uses: the quartermaster at the broker
/// watches the deck change too.
fn push_ship_fit(state: State, ship_id: Int, fit: loadout.Fit) -> Nil {
  let text = protocol.encode_ship_fit(ship_id, fit.class, fit.loadout)
  list.each(state.clients, fn(client) {
    case find_character(state.characters, client.character_id) {
      Error(Nil) -> Nil
      Ok(char) ->
        case char.ship_id == ship_id {
          True -> process.send(client.subject, SendText(text))
          False -> Nil
        }
    }
  })
}

/// The resolved fit of one ship. Every consumer of the old single shared
/// `state.class` goes through here: since M4 a hull is per-ship data, not a
/// world-wide constant.
fn fit_for(state: State, ship_id: Int) -> Result(loadout.Fit, Nil) {
  case list.find(state.fits, fn(entry) { entry.0 == ship_id }) {
    Ok(#(_, fit)) -> Ok(fit)
    Error(Nil) -> Error(Nil)
  }
}

/// Resolve the default loadout of `hull_id` — the fit a freshly spawned ship
/// gets.
fn default_fit(state: State, hull_id: String) -> Result(loadout.Fit, String) {
  case dict.get(state.hulls, hull_id) {
    Error(Nil) -> Error("unknown_hull:" <> hull_id)
    Ok(h) ->
      loadout.resolve(
        state.glyphs,
        h,
        state.modules,
        state.parts,
        loadout.default_for(h),
      )
  }
}

/// Drop the fits of ships that no longer exist. A fit is per-ship data with
/// exactly the ship's lifetime, so it is pruned wherever the ship list is.
fn prune_fits(
  fits: List(#(Int, loadout.Fit)),
  ships: List(Ship),
) -> List(#(Int, loadout.Fit)) {
  list.filter(fits, fn(entry) { list.any(ships, fn(s) { s.id == entry.0 }) })
}

/// `RequestDock` pre-check: is this character already docked, seated at a
/// helm console in the station composite? Mirrors the seat-resolution logic
/// `RequestUndock` uses (`OnStation` + namespaced seat + helm-kind console +
/// the target ship still present) but only needs a yes/no answer, since a
/// docked pilot asking to dock again should get `"already_docked"` rather
/// than falling through to `with_helm_ship`'s `Aboard`-only gate, which
/// would otherwise misread the namespaced seat as "not at helm".
fn already_docked_at_helm(state: State, character_id: Int) -> Bool {
  case find_character(state.characters, character_id) {
    Error(Nil) -> False
    Ok(char) ->
      case char.place, char.seat {
        character.OnStation(_), Some(seat_id) ->
          case composite.parse_namespaced(seat_id) {
            Error(Nil) -> False
            Ok(#(target_ship_id, console_id)) ->
              case fit_for(state, target_ship_id) {
                Error(Nil) -> False
                Ok(fit) ->
                  case deckplan.find_console(fit.class.plan, console_id) {
                    Error(Nil) -> False
                    Ok(console) if console.kind != "helm" -> False
                    Ok(_) ->
                      case find_ship(state.ships, target_ship_id) {
                        Error(Nil) -> False
                        Ok(_) -> True
                      }
                  }
              }
          }
        _, _ -> False
      }
  }
}

/// Helm-seat gating for `RequestDock`: resolve the character, require it to
/// be aboard (flying) and seated at a helm-kind console of its OWN ship's
/// resolved plan, resolve that ship, then hand the ship and its fit to `next`.
/// Replies `Error("not_at_helm")` / `Error("not_docked")` and leaves state
/// untouched on any resolution failure — a ship with no fit answers
/// `"not_at_helm"`, since without a resolved plan it has no helm to be at.
/// Called only after `already_docked_at_helm` rules out the already-docked
/// case. (Undock has its own composite-frame gating.)
fn with_helm_ship(
  state: State,
  character_id: Int,
  reply: Subject(Result(Nil, String)),
  next: fn(State, Ship, loadout.Fit) -> actor.Next(State, Msg),
) -> actor.Next(State, Msg) {
  case find_character(state.characters, character_id) {
    Error(Nil) -> {
      process.send(reply, Error("not_docked"))
      actor.continue(state)
    }
    Ok(char) ->
      case fit_for(state, char.ship_id) {
        Error(Nil) -> {
          process.send(reply, Error("not_at_helm"))
          actor.continue(state)
        }
        Ok(fit) ->
          case
            char.place == character.Aboard
            && character.is_at_helm(char, fit.class.plan)
          {
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
                Ok(found) -> next(state, found, fit)
              }
          }
      }
  }
}

/// Undock `target` from `station_id`: bodies standing on its moored tiles
/// leave with it (and become its crew), bodies on station tiles stay. Ships
/// left crewless by the transfer despawn, the station space rebuilds
/// without the departed moorings, and both sides get their new plan.
fn handle_undock_split(
  state: State,
  station_id: String,
  target: Ship,
  fit: loadout.Fit,
  reply: Subject(Result(Nil, String)),
) -> actor.Next(State, Msg) {
  let t = int.to_float(state.tick) *. ship.dt
  case ship.undock(target, state.world, t, fit.class.dock_standoff) {
    Error(reason) -> {
      process.send(reply, Error(reason))
      actor.continue(state)
    }
    Ok(flying) -> {
      // Split against the *current* (pre-rebuild) frame's mooring.
      let assert Ok(space) = find_space(state.spaces, station_id)
      let assert Ok(mooring) =
        composite.find_mooring(space.composite, target.id)
      let characters =
        list.map(state.characters, fn(c) {
          let departing =
            c.place == character.OnStation(station_id)
            && composite.tile_on_mooring(
              mooring,
              fit.class.plan,
              c.deck,
              c.x,
              c.y,
            )
          case departing {
            False -> c
            True -> {
              // Moored (rotated) composite frame -> ship frame, composite
              // deck -> the ship's own deck index.
              let #(sx, sy) = composite.to_ship_frame(mooring, c.x, c.y)
              let ship_deck =
                composite.ship_deck_of(mooring, c.deck)
                |> result.unwrap(0)
              character.Character(
                ..c,
                ship_id: target.id,
                place: character.Aboard,
                x: sx,
                y: sy,
                deck: ship_deck,
                seat: strip_namespace(c.seat),
              )
            }
          }
        })
      // Crew transfer may have emptied other ships (their last crew member
      // left standing on the departing deck): despawn them.
      let surviving = replace_ship(state.ships, flying)
      let crewed_ship_ids =
        list.map(characters, fn(c) { c.ship_id }) |> list.unique
      let ships =
        list.filter(surviving, fn(s) { list.contains(crewed_ship_ids, s.id) })
      // A ship despawned by the transfer while docked at a *different*
      // station leaves that station's composite with a ghost mooring. Mirror
      // ClientDown: rebuild+re-push every such remote station too (the local
      // station is rebuilt below). rebuild_space's snap re-floors any body
      // that was standing on those remote moorings.
      let despawned_station_ids =
        list.filter_map(surviving, fn(s) {
          case list.contains(crewed_ship_ids, s.id), s.dock {
            False, ship.Docked(sid, _) if sid != station_id -> Ok(sid)
            _, _ -> Error(Nil)
          }
        })
        |> list.unique
      let state =
        rebuild_space(
          State(
            ..state,
            ships: ships,
            characters: characters,
            fits: prune_fits(state.fits, ships),
          ),
          station_id,
        )
      let state = list.fold(despawned_station_ids, state, rebuild_space)
      process.send(reply, Ok(Nil))
      push_space(state, protocol.StationSpace(station_id))
      push_space(state, protocol.ShipSpace(target.id))
      list.each(despawned_station_ids, fn(sid) {
        push_space(state, protocol.StationSpace(sid))
      })
      actor.continue(state)
    }
  }
}

/// `"s3:helm_main"` -> `"helm_main"`; plain ids and `None` pass through.
fn strip_namespace(seat: option.Option(String)) -> option.Option(String) {
  option.map(seat, fn(id) {
    case composite.parse_namespaced(id) {
      Ok(#(_, base)) -> base
      Error(Nil) -> id
    }
  })
}

/// The station whose market the character may inspect: the composite they
/// are standing in (docked crews are `OnStation`). `Aboard` means flying,
/// so there is no station market.
fn market_station_for(_state: State, char: Character) -> Result(String, Nil) {
  case char.place {
    character.OnStation(station_id) -> Ok(station_id)
    character.Aboard -> Error(Nil)
  }
}

/// Shared buy/sell gate: seated at a broker console ashore, own ship
/// docked at that station, handling method available, station trades the
/// commodity. Buys take stock first (price locked from the store), then
/// validate the ship side — the market change is only committed when both
/// halves succeed.
fn handle_trade(
  state: State,
  character_id: Int,
  commodity: String,
  quantity: Int,
  buying: Bool,
  reply: Subject(protocol.TradeResult),
) -> actor.Next(State, Msg) {
  let fail = fn(reason) {
    process.send(
      reply,
      protocol.TradeResult(
        ok: False,
        reason: Some(reason),
        commodity: commodity,
        quantity: quantity,
        price: 0,
      ),
    )
    actor.continue(state)
  }
  case find_character(state.characters, character_id) {
    Error(Nil) -> fail("not_at_broker")
    Ok(char) ->
      case char.place {
        character.Aboard -> fail("not_at_broker")
        character.OnStation(station_id) -> {
          let seated_at_broker = case plan_for(state, char) {
            Ok(plan) -> character.seated_at_kind(char, plan, "broker")
            Error(Nil) -> False
          }
          case seated_at_broker {
            False -> fail("not_at_broker")
            True ->
              case find_ship(state.ships, char.ship_id) {
                Error(Nil) -> fail("ship_not_docked")
                Ok(s) -> {
                  let ship_docked_here = case s.dock {
                    ship.Docked(sid, _) -> sid == station_id
                    ship.Flying -> False
                  }
                  case ship_docked_here {
                    False -> fail("ship_not_docked")
                    True -> {
                      let assert Ok(station) =
                        world.get_station(state.world, station_id)
                      // Handling and hold size are the TRADING SHIP's own
                      // resolved numbers; a ship with no fit has neither, so
                      // there is nothing to load it through.
                      case fit_for(state, s.id) {
                        Error(Nil) -> fail("no_fit")
                        Ok(fit) ->
                          case
                            cargo.transfer_rate(
                              station.crane,
                              fit.class.handling,
                            )
                          {
                            Error(reason) -> fail(reason)
                            Ok(rate) ->
                              case find_market(state.markets, station_id) {
                                Error(Nil) -> fail("not_sold_here")
                                Ok(m) ->
                                  case buying {
                                    True ->
                                      do_buy(
                                        state,
                                        m,
                                        s,
                                        commodity,
                                        quantity,
                                        fit.class.cargo_capacity,
                                        rate,
                                        reply,
                                      )
                                    False ->
                                      do_sell(
                                        state,
                                        m,
                                        s,
                                        commodity,
                                        quantity,
                                        rate,
                                        reply,
                                      )
                                  }
                              }
                          }
                      }
                    }
                  }
                }
              }
          }
        }
      }
  }
}

fn do_buy(
  state: State,
  m: market.Market,
  s: Ship,
  commodity: String,
  quantity: Int,
  capacity: Int,
  rate: Float,
  reply: Subject(protocol.TradeResult),
) -> actor.Next(State, Msg) {
  let fail = fn(reason) {
    process.send(
      reply,
      protocol.TradeResult(
        ok: False,
        reason: Some(reason),
        commodity: commodity,
        quantity: quantity,
        price: 0,
      ),
    )
    actor.continue(state)
  }
  case market.take_stock(m, commodity, quantity) {
    Error(reason) -> fail(reason)
    Ok(#(updated_market, store)) ->
      case
        cargo.begin_buy(s, commodity, quantity, store.price, capacity, rate)
      {
        // Ship-side rejection: the market change is discarded (never
        // committed to state), so stock is untouched.
        Error(reason) -> fail(reason)
        Ok(updated_ship) -> {
          process.send(
            reply,
            protocol.TradeResult(
              ok: True,
              reason: None,
              commodity: commodity,
              quantity: quantity,
              price: store.price,
            ),
          )
          actor.continue(
            State(
              ..state,
              ships: replace_ship(state.ships, updated_ship),
              markets: replace_market(state.markets, updated_market),
            ),
          )
        }
      }
  }
}

fn do_sell(
  state: State,
  m: market.Market,
  s: Ship,
  commodity: String,
  quantity: Int,
  rate: Float,
  reply: Subject(protocol.TradeResult),
) -> actor.Next(State, Msg) {
  let fail = fn(reason) {
    process.send(
      reply,
      protocol.TradeResult(
        ok: False,
        reason: Some(reason),
        commodity: commodity,
        quantity: quantity,
        price: 0,
      ),
    )
    actor.continue(state)
  }
  case market.find_store(m, commodity) {
    Error(Nil) -> fail("not_sold_here")
    Ok(store) ->
      case cargo.begin_sell(s, commodity, quantity, store.price, rate) {
        Error(reason) -> fail(reason)
        Ok(updated_ship) -> {
          process.send(
            reply,
            protocol.TradeResult(
              ok: True,
              reason: None,
              commodity: commodity,
              quantity: quantity,
              price: store.price,
            ),
          )
          actor.continue(
            State(..state, ships: replace_ship(state.ships, updated_ship)),
          )
        }
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

/// The deck plan under the character's feet: their flying ship's own resolved
/// plan when aboard, the station's composite plan when standing in a station
/// space. `Error(Nil)` when neither resolves (no fit for that ship, no such
/// space) — callers skip the character rather than crash.
fn plan_for(state: State, char: Character) -> Result(deckplan.DeckPlan, Nil) {
  case char.place {
    character.Aboard ->
      fit_for(state, char.ship_id) |> result.map(fn(f) { f.class.plan })
    character.OnStation(station_id) ->
      case find_space(state.spaces, station_id) {
        Error(Nil) -> Error(Nil)
        Ok(space) -> Ok(space.composite.plan)
      }
  }
}

/// One composite space per concourse, built empty at startup (world
/// validation guarantees an empty build succeeds). Stations without a
/// concourse get no space and can never be docked at.
fn initial_spaces(world: World) -> List(StationSpace) {
  list.filter_map(world.stations, fn(station) {
    case station.concourse {
      None -> Error(Nil)
      Some(concourse) ->
        case composite.build(concourse, world.station_berths(station), []) {
          Ok(built) ->
            Ok(StationSpace(station_id: station.id, epoch: 0, composite: built))
          Error(_) -> Error(Nil)
        }
    }
  })
}

fn find_space(
  spaces: List(StationSpace),
  station_id: String,
) -> Result(StationSpace, Nil) {
  list.find(spaces, fn(s) { s.station_id == station_id })
}

/// Ships docked at `station_id`, as composite inputs — each contributing its
/// OWN resolved plan, so a berth line of mixed hulls stitches correctly. A
/// docked ship with no fit contributes no mooring rather than failing the
/// rebuild.
fn docked_ships_at(
  state: State,
  station_id: String,
) -> List(composite.DockedShip) {
  list.filter_map(state.ships, fn(s) {
    case s.dock {
      ship.Docked(sid, berth) if sid == station_id ->
        fit_for(state, s.id)
        |> result.map(fn(fit) {
          composite.DockedShip(
            ship_id: s.id,
            berth: berth,
            plan: fit.class.plan,
          )
        })
      _ -> Error(Nil)
    }
  })
}

/// A seed-random free berth index at `station_id` for `ship_id`, or why not
/// (`"no_berths"` / `"berths_full"`). Pure pick, no RNG state: hash
/// `(world.seed, "<station_id>:<ship_id>")` through noise's SplitMix64 and
/// mod it into the ordered free-berth list — same inputs always land the
/// same ship on the same berth, but different ships spread across berths
/// instead of everyone piling onto berth 0.
fn free_berth(
  state: State,
  ship_id: Int,
  station_id: String,
) -> Result(Int, String) {
  case world.get_station(state.world, station_id) {
    Error(Nil) -> Error("no_berths")
    Ok(station) ->
      case world.station_berths(station) {
        [] -> Error("no_berths")
        berths -> {
          let taken =
            list.filter_map(state.ships, fn(s) {
              case s.dock {
                ship.Docked(sid, berth) if sid == station_id -> Ok(berth)
                _ -> Error(Nil)
              }
            })
          case free_indices(list.length(berths), taken) {
            [] -> Error("berths_full")
            free -> {
              let key = station_id <> ":" <> int.to_string(ship_id)
              let assert Ok(pick) =
                int.modulo(
                  noise.seed_string(state.world.seed, key),
                  list.length(free),
                )
              let assert Ok(index) = free |> list.drop(pick) |> list.first
              Ok(index)
            }
          }
        }
      }
  }
}

/// Every index in `[0, count)` not present in `taken`, ascending. (The
/// pinned gleam_stdlib 1.0.3 has no `list.range`, so this walks indices
/// directly.)
fn free_indices(count: Int, taken: List(Int)) -> List(Int) {
  free_indices_from(0, count, taken)
}

fn free_indices_from(index: Int, count: Int, taken: List(Int)) -> List(Int) {
  case index >= count {
    True -> []
    False ->
      case list.contains(taken, index) {
        True -> free_indices_from(index + 1, count, taken)
        False -> [index, ..free_indices_from(index + 1, count, taken)]
      }
  }
}

/// Rebuild `station_id`'s composite from the ships in `state`, bump its
/// epoch, and translate every body standing in that space by the frame
/// shift (uniform: berth-relative layout is stable, only the normalization
/// shift moves). `Error` carries `composite.build`'s own reason
/// (`berth_blocked` / `unknown_berth` / `no_concourse_deck`); the two cases
/// with nothing to rebuild — no such station, or a station with no concourse
/// — are `Ok` with the state untouched.
///
/// Fallible on purpose. Since M4 a fit is DURABLE and per-ship: a ship
/// refitted at one station can fly to another and dock there wearing a
/// footprint that station's berth geometry was never pre-flighted against, so
/// "the build always succeeds" is not an invariant the sim may assert on.
/// Callers that ADD a mooring (login, dock) take the `Result` and refuse with
/// the reason; callers that only REMOVE one go through `rebuild_space`.
fn try_rebuild_space(
  state: State,
  station_id: String,
) -> Result(State, String) {
  case world.get_station(state.world, station_id) {
    Error(Nil) -> Ok(state)
    Ok(station) ->
      case station.concourse {
        None -> Ok(state)
        Some(concourse) ->
          case
            composite.build(
              concourse,
              world.station_berths(station),
              docked_ships_at(state, station_id),
            )
          {
            Error(reason) -> Error(reason)
            Ok(built) -> Ok(rebuilt_state(state, station_id, built))
          }
      }
  }
}

/// `try_rebuild_space` for the callers that cannot possibly have created a
/// collision: undock and despawn only ever REMOVE a mooring, and the refit
/// commit rebuilds a composite `composite_survives` has already built. Nothing
/// there is refusable, so a failure keeps the space exactly as it stands
/// rather than taking the actor down with it.
fn rebuild_space(state: State, station_id: String) -> State {
  try_rebuild_space(state, station_id) |> result.unwrap(state)
}

/// Install a freshly built composite as `station_id`'s space: re-floor the
/// bodies standing in it and bump the epoch.
fn rebuilt_state(
  state: State,
  station_id: String,
  built: composite.Composite,
) -> State {
  let old_composite = case find_space(state.spaces, station_id) {
    Ok(old) -> Some(old.composite)
    Error(Nil) -> None
  }
  let #(old_dx, old_dy) = case old_composite {
    Some(old) -> #(old.concourse_dx, old.concourse_dy)
    None -> #(0, 0)
  }
  let shift_x = int.to_float(built.concourse_dx - old_dx)
  let shift_y = int.to_float(built.concourse_dy - old_dy)
  // A body standing on a ship mooring that just despawned lands in
  // void on the new composite (its tiles are gone). Rather than
  // leave it soft-locked — character.step rejects every move out of
  // a non-walkable circle — snap it to the concourse spawn tile,
  // dropping any now-ghost seat and pending move input.
  let #(spawn_tx, spawn_ty) = built.plan.spawn_tile
  let #(spawn_x, spawn_y) = deckplan.tile_center(spawn_tx, spawn_ty)
  let characters =
    list.map(state.characters, fn(c) {
      case c.place == character.OnStation(station_id) {
        False -> c
        True -> {
          // Deck indices shift as ships dock/undock; remap the body's
          // composite deck onto the new composite before checking it.
          let new_deck = case old_composite {
            Some(old) -> composite.remap_deck(old, built, c.deck)
            None -> c.deck
          }
          let moved =
            character.Character(
              ..c,
              x: c.x +. shift_x,
              y: c.y +. shift_y,
              deck: new_deck,
            )
          case
            character.can_stand_at(built.plan, moved.deck, moved.x, moved.y)
          {
            True -> moved
            False ->
              character.Character(
                ..moved,
                x: spawn_x,
                y: spawn_y,
                // Re-floor onto the concourse plane, whatever index it
                // landed at for this composite.
                deck: built.plan.spawn_deck,
                seat: None,
                move_dx: 0.0,
                move_dy: 0.0,
              )
          }
        }
      }
    })
  let epoch = case find_space(state.spaces, station_id) {
    Ok(old) -> old.epoch + 1
    Error(Nil) -> 1
  }
  let spaces =
    list.map(state.spaces, fn(s) {
      case s.station_id == station_id {
        True -> StationSpace(station_id, epoch, built)
        False -> s
      }
    })
  State(..state, characters: characters, spaces: spaces)
}

/// Push a personalized `space` message to every client whose character is
/// in `space_id`'s scope right now.
fn push_space(state: State, space_id: protocol.SpaceId) -> Nil {
  list.each(state.clients, fn(client) {
    case find_character(state.characters, client.character_id) {
      Error(Nil) -> Nil
      Ok(char) -> {
        let in_scope = case space_id, char.place {
          protocol.StationSpace(sid), character.OnStation(here) -> sid == here
          protocol.ShipSpace(ship_id), character.Aboard ->
            char.ship_id == ship_id
          _, _ -> False
        }
        case in_scope {
          False -> Nil
          True ->
            case space_message_for(state, char) {
              Error(Nil) -> Nil
              Ok(text) -> process.send(client.subject, SendText(text))
            }
        }
      }
    }
  })
}

/// The `space` message for one character's current place.
fn space_message_for(state: State, char: Character) -> Result(String, Nil) {
  case char.place {
    character.Aboard ->
      fit_for(state, char.ship_id)
      |> result.map(fn(fit) {
        protocol.encode_space(
          protocol.ShipSpace(char.ship_id),
          0,
          fit.class.plan,
          [],
          None,
          char,
        )
      })
    character.OnStation(station_id) ->
      case find_space(state.spaces, station_id) {
        Error(Nil) -> Error(Nil)
        Ok(space) ->
          Ok(protocol.encode_space(
            protocol.StationSpace(station_id),
            space.epoch,
            space.composite.plan,
            space.composite.moorings,
            Some(#(space.composite.concourse_dx, space.composite.concourse_dy)),
            char,
          ))
      }
  }
}

fn find_market(
  markets: List(market.Market),
  station_id: String,
) -> Result(market.Market, Nil) {
  list.find(markets, fn(m) { m.station_id == station_id })
}

fn replace_market(
  markets: List(market.Market),
  updated: market.Market,
) -> List(market.Market) {
  list.map(markets, fn(m) {
    case m.station_id == updated.station_id {
      True -> updated
      False -> m
    }
  })
}

fn run_tick(state: State) -> actor.Next(State, Msg) {
  let started_us = clock.now_us()

  // 1. Advance the world and every character.
  let tick = state.tick + 1
  let t = int.to_float(tick) *. ship.dt
  let ships =
    list.map(state.ships, fn(s) {
      // Standoff and flight performance are the ship's own resolved numbers.
      // A ship with no fit is left exactly where it is rather than crashing
      // the tick: a missing fit must never take the server down.
      case fit_for(state, s.id) {
        Error(Nil) -> s
        Ok(fit) ->
          ship.step(
            s,
            state.world,
            t,
            fit.class.dock_standoff,
            fit.class.flight,
          )
      }
    })
  let characters =
    list.map(state.characters, fn(c) {
      case plan_for(state, c) {
        Ok(plan) -> character.step(c, plan)
        Error(Nil) -> c
      }
    })

  // 1b. Advance cargo transfers on docked ships; sold units land in the
  // station's store the moment they cross the dock.
  let #(ships, markets) =
    list.fold(ships, #([], state.markets), fn(acc, s) {
      let #(done, markets) = acc
      case s.transfers, s.dock {
        [], _ -> #([s, ..done], markets)
        [_, ..], ship.Docked(station_id, _) -> {
          let #(stepped, deliveries) = cargo.step_transfers(s)
          let markets =
            list.fold(deliveries, markets, fn(markets, delivery) {
              case find_market(markets, station_id) {
                Error(Nil) -> markets
                Ok(m) ->
                  replace_market(
                    markets,
                    market.add_stock(m, delivery.commodity, delivery.quantity),
                  )
              }
            })
          #([stepped, ..done], markets)
        }
        // Unreachable while undock is blocked mid-transfer; keep the ship
        // untouched rather than crash if that invariant ever changes.
        [_, ..], ship.Flying -> #([s, ..done], markets)
      }
    })
  let ships = list.reverse(ships)

  // 1c. Price and stock epochs, derived from sim time.
  let new_price_epoch = market.price_epoch(t)
  let markets = case new_price_epoch == state.price_epoch {
    True -> markets
    False ->
      list.map(markets, market.reprice(_, state.world.seed, new_price_epoch))
  }
  let new_regen_epoch = market.regen_epoch(t)
  let markets = case new_regen_epoch == state.regen_epoch {
    True -> markets
    False -> list.map(markets, market.regen)
  }

  // 2. Broadcast at 15 Hz (skip serialization with no listeners): one
  // shared exterior snapshot to everyone, plus one `walkers` message per
  // occupied space fanned out only to that space's occupants.
  case tick % snapshot_every == 0 && state.clients != [] {
    True -> {
      let snapshot =
        protocol.encode_snapshot(tick, with_appearance(ships, state.fits))
      list.each(state.clients, fn(client) {
        process.send(client.subject, SendText(snapshot))
      })
      broadcast_walkers(state.clients, characters, state.spaces, tick)
      broadcast_cargo(state.clients, characters, ships, state.fits)
      broadcast_markets(state.clients, characters, markets)
    }
    False -> Nil
  }

  // 3. Record how long the work took.
  let acc = stats.record(state.acc, clock.now_us() - started_us)
  let state =
    State(
      ..state,
      ships: ships,
      characters: characters,
      tick: tick,
      acc: acc,
      markets: markets,
      price_epoch: new_price_epoch,
      regen_epoch: new_regen_epoch,
    )

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

/// One `walkers` message per occupied space, sent only to that space's
/// occupants: flying ships' crews get their ship space, everyone at a
/// docked station (aboard moored ships or on the concourse floor alike)
/// shares the station space.
fn broadcast_walkers(
  clients: List(Client),
  characters: List(Character),
  spaces: List(StationSpace),
  tick: Int,
) -> Nil {
  let keyed =
    list.map(characters, fn(c) {
      case c.place {
        character.Aboard -> #(protocol.ShipSpace(c.ship_id), c)
        character.OnStation(station_id) -> #(
          protocol.StationSpace(station_id),
          c,
        )
      }
    })
  let space_ids = list.map(keyed, fn(pair) { pair.0 }) |> list.unique
  let texts =
    list.map(space_ids, fn(space_id) {
      let occupants =
        list.filter_map(keyed, fn(pair) {
          case pair.0 == space_id {
            True -> Ok(pair.1)
            False -> Error(Nil)
          }
        })
      let epoch = case space_id {
        protocol.ShipSpace(_) -> 0
        protocol.StationSpace(station_id) ->
          case find_space(spaces, station_id) {
            Ok(space) -> space.epoch
            Error(Nil) -> 0
          }
      }
      #(space_id, protocol.encode_walkers(tick, space_id, epoch, occupants))
    })
  list.each(clients, fn(client) {
    case find_character(characters, client.character_id) {
      Error(Nil) -> Nil
      Ok(char) -> {
        let key = case char.place {
          character.Aboard -> protocol.ShipSpace(char.ship_id)
          character.OnStation(station_id) -> protocol.StationSpace(station_id)
        }
        case list.find(texts, fn(t) { t.0 == key }) {
          Error(Nil) -> Nil
          Ok(#(_, text)) -> process.send(client.subject, SendText(text))
        }
      }
    }
  })
}

/// Pair every ship with its fit's appearance. A ship with no fit should be
/// unreachable (spawn resolves or refuses; `prune_fits` only drops dead
/// ships), but if it happens she still appears in the snapshot wearing an
/// EMPTY appearance — a missing fit must never make a hull vanish from the
/// world.
fn with_appearance(
  ships: List(Ship),
  fits: List(#(Int, loadout.Fit)),
) -> List(#(Ship, loadout.Appearance)) {
  list.map(ships, fn(s) {
    case list.find(fits, fn(entry) { entry.0 == s.id }) {
      Ok(#(_, fit)) -> #(s, fit.appearance)
      Error(Nil) -> #(s, loadout.Appearance(hull_sprite: "", mounts: []))
    }
  })
}

/// One `cargo` message per crewed ship, to its *crew* (by membership,
/// wherever their bodies are — the quartermaster ashore watches the hold).
/// Hold size is each ship's own resolved capacity; a ship with no fit is
/// skipped rather than reported with somebody else's hold.
fn broadcast_cargo(
  clients: List(Client),
  characters: List(Character),
  ships: List(Ship),
  fits: List(#(Int, loadout.Fit)),
) -> Nil {
  let texts =
    list.filter_map(ships, fn(s) {
      case list.find(fits, fn(entry) { entry.0 == s.id }) {
        Error(Nil) -> Error(Nil)
        Ok(#(_, fit)) ->
          Ok(#(s.id, protocol.encode_cargo(s, fit.class.cargo_capacity)))
      }
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

/// One `market` message per occupied station's market, to its concourse
/// occupants — prices and stock stay live while you stand at the broker.
fn broadcast_markets(
  clients: List(Client),
  characters: List(Character),
  markets: List(market.Market),
) -> Nil {
  list.each(clients, fn(client) {
    case find_character(characters, client.character_id) {
      Error(Nil) -> Nil
      Ok(char) ->
        case char.place {
          character.Aboard -> Nil
          character.OnStation(station_id) ->
            case find_market(markets, station_id) {
              Error(Nil) -> Nil
              Ok(m) ->
                process.send(
                  client.subject,
                  SendText(protocol.encode_market(m)),
                )
            }
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

/// Sim diagnostics go to stderr (`println_error`, here and at the client
/// connect/disconnect logs): stderr writes never route through the
/// process's group leader, so a sim actor that outlives the process that
/// spawned it — as happens under the eunit test runner, whose per-test
/// group leaders die with each test — logs safely instead of crashing the
/// tick loop with `Io(Terminated)` and taking its linked spawner with it.
fn log_health(state: State) -> Nil {
  let s = stats.current(state.acc)
  io.println_error(
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
