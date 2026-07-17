//// Sim-actor-level tests for the M2 character/boarding logic: boarding
//// success and every failure reason, despawn-on-empty (via board and via
//// disconnect), pilot-disconnect-with-crew survival, and interior fan-out
//// isolation. These drive the real actor through its public API and
//// observe it the way clients do — through snapshot/interior messages.

import dh_server/protocol
import dh_server/shipclass
import dh_server/sim
import dh_server/world
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}

fn start_sim() -> process.Subject(sim.Msg) {
  let assert Ok(w) = world.load("worlds/m1_system.json")
  let assert Ok(c) = shipclass.load("classes/sparrow.json")
  let assert Ok(started) = sim.start(w, c)
  started.data
}

/// A fake client handler process for disconnect tests: creates its subject
/// (the owner must be the process the sim's messages are addressed to),
/// hands it back, then idles until killed. Returns the pid to kill and the
/// subject to register.
fn spawn_fake_client() -> #(process.Pid, process.Subject(sim.ClientMsg)) {
  let handoff = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      process.send(handoff, process.new_subject())
      process.sleep_forever()
    })
  let assert Ok(client) = process.receive(handoff, 1000)
  #(pid, client)
}

fn message_type_decoder() -> decode.Decoder(String) {
  decode.field("type", decode.string, decode.success)
}

/// One character as reported by an `interior`/`concourse` message.
type CrewMember {
  CrewMember(id: Int, x: Float, y: Float, seat: Option(String))
}

fn interior_decoder() -> decode.Decoder(#(Int, List(CrewMember))) {
  use ship_id <- decode.field("ship_id", decode.int)
  use characters <- decode.field(
    "characters",
    decode.list({
      use id <- decode.field("id", decode.int)
      use x <- decode.field("x", decode.float)
      use y <- decode.field("y", decode.float)
      use seat <- decode.field("seat", decode.optional(decode.string))
      decode.success(CrewMember(id: id, x: x, y: y, seat: seat))
    }),
  )
  decode.success(#(ship_id, characters))
}

fn snapshot_ship_ids_decoder() -> decode.Decoder(List(Int)) {
  decode.field(
    "ships",
    decode.list(decode.field("id", decode.int, decode.success)),
    decode.success,
  )
}

/// Receive messages on `client` until an `interior` arrives, returning its
/// ship_id and characters.
fn receive_interior(
  client: process.Subject(sim.ClientMsg),
) -> #(Int, List(CrewMember)) {
  let assert Ok(sim.SendText(text)) = process.receive(client, 2000)
  let assert Ok(msg_type) = json.parse(text, message_type_decoder())
  case msg_type {
    "interior" -> {
      let assert Ok(decoded) = json.parse(text, interior_decoder())
      decoded
    }
    _ -> receive_interior(client)
  }
}

/// Receive interiors on `client` until one for `ship_id` arrives (skipping
/// any stale pre-transition interiors buffered for a previous ship),
/// returning its characters.
fn receive_interior_for_ship(
  client: process.Subject(sim.ClientMsg),
  ship_id: Int,
) -> List(CrewMember) {
  let #(sid, characters) = receive_interior(client)
  case sid == ship_id {
    True -> characters
    False -> receive_interior_for_ship(client, ship_id)
  }
}

/// Receive messages on `client` until a `snapshot` arrives, returning the
/// ids of the ships in it.
fn receive_snapshot_ship_ids(
  client: process.Subject(sim.ClientMsg),
) -> List(Int) {
  let assert Ok(sim.SendText(text)) = process.receive(client, 2000)
  let assert Ok(msg_type) = json.parse(text, message_type_decoder())
  case msg_type {
    "snapshot" -> {
      let assert Ok(ids) = json.parse(text, snapshot_ship_ids_decoder())
      ids
    }
    _ -> receive_snapshot_ship_ids(client)
  }
}

/// Receive snapshots on `client` until one arrives without `ship_id`
/// (skipping snapshots buffered from before the despawn). Fails the test
/// after `tries` snapshots still containing it.
fn assert_ship_leaves_snapshots(
  client: process.Subject(sim.ClientMsg),
  ship_id: Int,
  tries: Int,
) -> Nil {
  let ids = receive_snapshot_ship_ids(client)
  case list.contains(ids, ship_id), tries {
    False, _ -> Nil
    True, 0 -> panic as "ship never left snapshots"
    True, _ -> assert_ship_leaves_snapshots(client, ship_id, tries - 1)
  }
}

/// The Down message races our stats call, so poll briefly.
fn wait_for_clients(
  s: process.Subject(sim.Msg),
  want: Int,
  tries: Int,
) -> Bool {
  case sim.get_stats(s, 1000).clients == want, tries {
    True, _ -> True
    False, 0 -> False
    False, _ -> {
      process.sleep(10)
      wait_for_clients(s, want, tries - 1)
    }
  }
}

fn concourse_decoder() -> decode.Decoder(#(String, List(CrewMember))) {
  use station_id <- decode.field("station_id", decode.string)
  use characters <- decode.field(
    "characters",
    decode.list({
      use id <- decode.field("id", decode.int)
      use x <- decode.field("x", decode.float)
      use y <- decode.field("y", decode.float)
      use seat <- decode.field("seat", decode.optional(decode.string))
      decode.success(CrewMember(id: id, x: x, y: y, seat: seat))
    }),
  )
  decode.success(#(station_id, characters))
}

/// Receive messages until a `concourse` arrives.
fn receive_concourse(
  client: process.Subject(sim.ClientMsg),
) -> #(String, List(CrewMember)) {
  let assert Ok(sim.SendText(text)) = process.receive(client, 2000)
  let assert Ok(msg_type) = json.parse(text, message_type_decoder())
  case msg_type {
    "concourse" -> {
      let assert Ok(decoded) = json.parse(text, concourse_decoder())
      decoded
    }
    _ -> receive_concourse(client)
  }
}

/// Receive interiors until `predicate` holds for `char_id`'s position.
/// Fails after `tries` interiors.
fn wait_for_character(
  client: process.Subject(sim.ClientMsg),
  char_id: Int,
  predicate: fn(Float, Float) -> Bool,
  tries: Int,
) -> Nil {
  let #(_ship_id, characters) = receive_interior(client)
  let position_ok = case list.find(characters, fn(c) { c.id == char_id }) {
    Ok(CrewMember(x: x, y: y, ..)) -> predicate(x, y)
    Error(Nil) -> False
  }
  case position_ok, tries {
    True, _ -> Nil
    False, 0 -> panic as "character never reached the expected position"
    False, _ -> wait_for_character(client, char_id, predicate, tries - 1)
  }
}

/// Concourse twin of wait_for_character.
fn wait_for_ashore_character(
  client: process.Subject(sim.ClientMsg),
  char_id: Int,
  predicate: fn(Float, Float) -> Bool,
  tries: Int,
) -> Nil {
  let #(_station_id, characters) = receive_concourse(client)
  let position_ok = case list.find(characters, fn(c) { c.id == char_id }) {
    Ok(CrewMember(x: x, y: y, ..)) -> predicate(x, y)
    Error(Nil) -> False
  }
  case position_ok, tries {
    True, _ -> Nil
    False, 0 -> panic as "character never reached the expected position"
    False, _ -> wait_for_ashore_character(client, char_id, predicate, tries - 1)
  }
}

/// Walk a standing character from the helm to the sparrow's aft airlock
/// (the spawn tile, [5, 4]): east along row 2, then south down the cargo
/// strip. Disembarking requires standing near the airlock (see
/// character.near_airlock), so tests that go ashore walk there first, the
/// same way a player does. Each leg is ~4 tiles at 3 tiles/s, well inside
/// 60 interiors (4 s) at 15 Hz.
fn walk_to_ship_airlock(
  s: process.Subject(sim.Msg),
  client: process.Subject(sim.ClientMsg),
  char: Int,
) -> Nil {
  sim.set_move(s, char, 1.0, 0.0)
  wait_for_character(client, char, fn(x, _y) { x >=. 5.3 }, 60)
  sim.set_move(s, char, 0.0, 1.0)
  wait_for_character(client, char, fn(_x, y) { y >=. 4.3 }, 60)
  sim.set_move(s, char, 0.0, 0.0)
}

/// One decoded `cargo` message (hold entries stay (commodity, quantity)
/// pairs; transfers is just the in-flight count).
type CargoMsg {
  CargoMsg(
    ship_id: Int,
    wallet: Int,
    hold: List(#(String, Int)),
    transfers: Int,
  )
}

fn cargo_decoder() -> decode.Decoder(CargoMsg) {
  use ship_id <- decode.field("ship_id", decode.int)
  use wallet <- decode.field("wallet", decode.int)
  use hold <- decode.field(
    "hold",
    decode.list({
      use commodity <- decode.field("commodity", decode.string)
      use quantity <- decode.field("quantity", decode.int)
      decode.success(#(commodity, quantity))
    }),
  )
  use transfers <- decode.field(
    "transfers",
    decode.list(decode.field("remaining", decode.int, decode.success)),
  )
  decode.success(CargoMsg(
    ship_id: ship_id,
    wallet: wallet,
    hold: hold,
    transfers: list.length(transfers),
  ))
}

fn receive_cargo(client: process.Subject(sim.ClientMsg)) -> CargoMsg {
  let assert Ok(sim.SendText(text)) = process.receive(client, 2000)
  let assert Ok(msg_type) = json.parse(text, message_type_decoder())
  case msg_type {
    "cargo" -> {
      let assert Ok(decoded) = json.parse(text, cargo_decoder())
      decoded
    }
    _ -> receive_cargo(client)
  }
}

/// Receive cargo messages until `predicate` holds. Fails after `tries`.
fn wait_for_cargo(
  client: process.Subject(sim.ClientMsg),
  predicate: fn(CargoMsg) -> Bool,
  tries: Int,
) -> CargoMsg {
  let cargo_msg = receive_cargo(client)
  case predicate(cargo_msg), tries {
    True, _ -> cargo_msg
    False, 0 -> panic as "cargo never reached the expected state"
    False, _ -> wait_for_cargo(client, predicate, tries - 1)
  }
}

/// Assert the next `count` sim pushes to `client` include no `concourse`.
fn assert_no_concourse(
  client: process.Subject(sim.ClientMsg),
  count: Int,
) -> Nil {
  case count {
    0 -> Nil
    _ -> {
      let assert Ok(sim.SendText(text)) = process.receive(client, 2000)
      let assert Ok(msg_type) = json.parse(text, message_type_decoder())
      assert msg_type != "concourse"
      assert_no_concourse(client, count - 1)
    }
  }
}

pub fn board_success_arrives_standing_at_spawn_tile_test() {
  let s = start_sim()
  let client_a = process.new_subject()
  let client_b = process.new_subject()
  let #(ship_a, char_a) = sim.add_player(s, "ada", client_a, 1000)
  let #(ship_b, char_b) = sim.add_player(s, "grace", client_b, 1000)

  // Both ships spawn docked at the same spawn station, so boarding works
  // immediately.
  assert sim.request_board(s, char_b, ship_a, 1000)
    == protocol.BoardResult(ok: True, reason: None, ship_id: ship_a)

  // b's interior is now ship A's, with b standing at the spawn tile
  // ([5, 4] -> center (5.5, 4.5)) and a still seated at the helm.
  let characters = receive_interior_for_ship(client_b, ship_a)
  let assert Ok(CrewMember(x: bx, y: by, seat: b_seat, ..)) =
    list.find(characters, fn(c) { c.id == char_b })
  assert b_seat == None
  assert bx == 5.5
  assert by == 4.5
  let assert Ok(CrewMember(seat: a_seat, ..)) =
    list.find(characters, fn(c) { c.id == char_a })
  assert a_seat == Some("helm_main")
  assert list.length(characters) == 2

  // b's old ship, emptied by the board, despawns from snapshots.
  assert_ship_leaves_snapshots(client_b, ship_b, 10)
}

/// Standing, walking input buffered on the old ship must not survive a
/// board: without clearing `move_dx`/`move_dy` alongside the seat (the fix
/// this test pins), the boarded character would resume walking away from
/// the new ship's spawn tile on the very next tick.
pub fn board_while_walking_arrives_and_stays_at_spawn_tile_test() {
  let s = start_sim()
  let client_a = process.new_subject()
  let client_b = process.new_subject()
  let #(ship_a, _char_a) = sim.add_player(s, "ada", client_a, 1000)
  let #(_ship_b, char_b) = sim.add_player(s, "grace", client_b, 1000)

  // b stands and sets nonzero walk input on their own ship, then boards a.
  let assert protocol.SeatResult(ok: True, ..) =
    sim.request_stand(s, char_b, 1000)
  sim.set_move(s, char_b, 1.0, 0.0)

  assert sim.request_board(s, char_b, ship_a, 1000)
    == protocol.BoardResult(ok: True, reason: None, ship_id: ship_a)

  // b lands at the spawn tile center and, since the buffered input was
  // cleared, stays there across several interiors rather than walking off
  // toward the engine room.
  assert_stays_at_spawn_tile(client_b, ship_a, char_b, 10)
}

/// Assert `char_id` is at the spawn tile center ([5, 4] -> (5.5, 4.5)) in
/// `count` consecutive interiors for `ship_id`.
fn assert_stays_at_spawn_tile(
  client: process.Subject(sim.ClientMsg),
  ship_id: Int,
  char_id: Int,
  count: Int,
) -> Nil {
  case count {
    0 -> Nil
    _ -> {
      let characters = receive_interior_for_ship(client, ship_id)
      let assert Ok(CrewMember(x: x, y: y, ..)) =
        list.find(characters, fn(c) { c.id == char_id })
      assert x == 5.5
      assert y == 4.5
      assert_stays_at_spawn_tile(client, ship_id, char_id, count - 1)
    }
  }
}

/// `RequestSit`'s occupied check is scoped to the character's *current*
/// ship (`c.ship_id == char.ship_id`) — nothing else end-to-end exercises
/// that scoping. b boards a's ship (landing standing, per `handle_board`)
/// and tries to take a's seat at the helm.
pub fn request_sit_occupied_is_scoped_to_current_ship_test() {
  let s = start_sim()
  let client_a = process.new_subject()
  let client_b = process.new_subject()
  let #(ship_a, _char_a) = sim.add_player(s, "ada", client_a, 1000)
  let #(_ship_b, char_b) = sim.add_player(s, "grace", client_b, 1000)

  let assert protocol.BoardResult(ok: True, ..) =
    sim.request_board(s, char_b, ship_a, 1000)

  assert sim.request_sit(s, char_b, "helm_main", 1000)
    == protocol.SeatResult(ok: False, reason: Some("occupied"), seat: None)
}

pub fn board_unknown_ship_test() {
  let s = start_sim()
  let client = process.new_subject()
  let #(ship_id, char_id) = sim.add_player(s, "ada", client, 1000)

  assert sim.request_board(s, char_id, 999, 1000)
    == protocol.BoardResult(
      ok: False,
      reason: Some("unknown_ship"),
      ship_id: ship_id,
    )
}

pub fn board_same_ship_test() {
  let s = start_sim()
  let client = process.new_subject()
  let #(ship_id, char_id) = sim.add_player(s, "ada", client, 1000)

  assert sim.request_board(s, char_id, ship_id, 1000)
    == protocol.BoardResult(
      ok: False,
      reason: Some("same_ship"),
      ship_id: ship_id,
    )
}

pub fn board_not_docked_together_test() {
  let s = start_sim()
  let client_a = process.new_subject()
  let client_b = process.new_subject()
  let #(ship_a, char_a) = sim.add_player(s, "ada", client_a, 1000)
  let #(ship_b, char_b) = sim.add_player(s, "grace", client_b, 1000)

  // a undocks (seated at the helm since login), so the two ships are no
  // longer docked at the same station.
  let assert Ok(Nil) = sim.request_undock(s, char_a, 1000)

  assert sim.request_board(s, char_b, ship_a, 1000)
    == protocol.BoardResult(
      ok: False,
      reason: Some("not_docked_together"),
      ship_id: ship_b,
    )
}

pub fn ship_despawns_when_last_character_disconnects_test() {
  let s = start_sim()
  let #(pid_a, client_a) = spawn_fake_client()
  let observer = process.new_subject()
  let #(ship_a, _char_a) = sim.add_player(s, "ada", client_a, 1000)
  let #(_ship_o, _char_o) = sim.add_player(s, "obs", observer, 1000)

  // a's character was the only one aboard ship A: killing the connection
  // removes the character and must despawn the ship.
  process.kill(pid_a)
  assert_ship_leaves_snapshots(observer, ship_a, 20)
}

pub fn ship_keeps_flying_when_pilot_disconnects_with_crew_aboard_test() {
  let s = start_sim()
  let #(pid_a, client_a) = spawn_fake_client()
  let client_b = process.new_subject()
  let #(ship_a, char_a) = sim.add_player(s, "ada", client_a, 1000)
  let #(ship_b, char_b) = sim.add_player(s, "grace", client_b, 1000)

  // b crews a's ship (emptying and despawning ship B), then a undocks and
  // disconnects mid-flight.
  let result = sim.request_board(s, char_b, ship_a, 1000)
  assert result.ok
  let assert Ok(Nil) = sim.request_undock(s, char_a, 1000)
  process.kill(pid_a)
  assert wait_for_clients(s, 1, 100)

  // The disconnect has been processed once b's interior shrinks to just
  // their own character (the pilot's character is gone)...
  wait_for_solo_crew(client_b, ship_a, char_b, 20)

  // ...and the ship survives its pilot: still in snapshots, while b's old
  // emptied ship stays gone.
  let ids = receive_snapshot_ship_ids(client_b)
  assert list.contains(ids, ship_a)
  assert !list.contains(ids, ship_b)
}

/// Receive interiors for `ship_id` until the crew is exactly the one
/// character `char_id` (skipping interiors buffered from before the other
/// crew member was removed). Fails the test after `tries` interiors.
fn wait_for_solo_crew(
  client: process.Subject(sim.ClientMsg),
  ship_id: Int,
  char_id: Int,
  tries: Int,
) -> Nil {
  let characters = receive_interior_for_ship(client, ship_id)
  case characters, tries {
    [CrewMember(id: only_id, ..)], _ if only_id == char_id -> Nil
    _, 0 -> panic as "crew never shrank to the surviving character"
    _, _ -> wait_for_solo_crew(client, ship_id, char_id, tries - 1)
  }
}

pub fn interior_fan_out_is_isolated_per_ship_test() {
  let s = start_sim()
  let client_a = process.new_subject()
  let client_b = process.new_subject()
  let #(ship_a, _char_a) = sim.add_player(s, "ada", client_a, 1000)
  let #(ship_b, _char_b) = sim.add_player(s, "grace", client_b, 1000)

  // Two clients aboard different ships: every interior each receives must
  // carry its own ship's id — a client never sees another ship's interior.
  assert_interiors_only_for(client_a, ship_a, 5)
  assert_interiors_only_for(client_b, ship_b, 5)
}

fn assert_interiors_only_for(
  client: process.Subject(sim.ClientMsg),
  ship_id: Int,
  count: Int,
) -> Nil {
  case count {
    0 -> Nil
    _ -> {
      let #(sid, _) = receive_interior(client)
      assert sid == ship_id
      assert_interiors_only_for(client, ship_id, count - 1)
    }
  }
}

pub fn disembark_lands_standing_at_concourse_spawn_test() {
  let s = start_sim()
  let client = process.new_subject()
  let #(_ship, char) = sim.add_player(s, "ada", client, 1000)
  let assert protocol.SeatResult(ok: True, ..) =
    sim.request_stand(s, char, 1000)
  walk_to_ship_airlock(s, client, char)
  assert sim.request_disembark(s, char, 1000)
    == protocol.DisembarkResult(
      ok: True,
      reason: None,
      station_id: Some("meridian_highport"),
    )
  // Meridian Highport's concourse spawn tile is [4, 4] -> center (4.5, 4.5).
  let #(station_id, characters) = receive_concourse(client)
  assert station_id == "meridian_highport"
  let assert Ok(CrewMember(x: x, y: y, seat: seat, ..)) =
    list.find(characters, fn(c) { c.id == char })
  assert x == 4.5
  assert y == 4.5
  assert seat == None
}

pub fn disembark_fails_while_flying_test() {
  let s = start_sim()
  let client = process.new_subject()
  let #(_ship, char) = sim.add_player(s, "ada", client, 1000)
  let assert Ok(Nil) = sim.request_undock(s, char, 1000)
  assert sim.request_disembark(s, char, 1000)
    == protocol.DisembarkResult(
      ok: False,
      reason: Some("not_docked"),
      station_id: None,
    )
}

pub fn disembark_fails_away_from_the_airlock_test() {
  let s = start_sim()
  let client = process.new_subject()
  let #(_ship, char) = sim.add_player(s, "ada", client, 1000)
  // Standing at the helm, ~4.4 tiles from the aft airlock: the deck and
  // the concourse connect at their airlocks, not from anywhere aboard.
  let assert protocol.SeatResult(ok: True, ..) =
    sim.request_stand(s, char, 1000)
  assert sim.request_disembark(s, char, 1000)
    == protocol.DisembarkResult(
      ok: False,
      reason: Some("not_at_airlock"),
      station_id: None,
    )
}

pub fn board_from_concourse_fails_away_from_the_airlock_test() {
  let s = start_sim()
  let client = process.new_subject()
  let #(ship_id, char) = sim.add_player(s, "ada", client, 1000)
  let assert protocol.SeatResult(ok: True, ..) =
    sim.request_stand(s, char, 1000)
  walk_to_ship_airlock(s, client, char)
  let assert protocol.DisembarkResult(ok: True, ..) =
    sim.request_disembark(s, char, 1000)
  // Walk north off the concourse airlock ([4, 4]) into the concourse
  // proper, past airlock range (1.2 tiles).
  sim.set_move(s, char, 0.0, -1.0)
  wait_for_ashore_character(client, char, fn(_x, y) { y <=. 2.9 }, 60)
  sim.set_move(s, char, 0.0, 0.0)
  assert sim.request_board(s, char, ship_id, 1000)
    == protocol.BoardResult(
      ok: False,
      reason: Some("not_at_airlock"),
      ship_id: ship_id,
    )
}

pub fn board_own_ship_back_from_concourse_test() {
  let s = start_sim()
  let client = process.new_subject()
  let #(ship_id, char) = sim.add_player(s, "ada", client, 1000)
  let assert protocol.SeatResult(ok: True, ..) =
    sim.request_stand(s, char, 1000)
  walk_to_ship_airlock(s, client, char)
  let assert protocol.DisembarkResult(ok: True, ..) =
    sim.request_disembark(s, char, 1000)
  // Ashore, your own ship is a legal board target (M2's same_ship rule only
  // applies aboard) — and the ship must have survived its crew going ashore.
  // Disembarking lands on the concourse airlock, so boarding back is in
  // range immediately.
  assert sim.request_board(s, char, ship_id, 1000)
    == protocol.BoardResult(ok: True, reason: None, ship_id: ship_id)
  // Skip any stale pre-disembark interiors buffered during the walk: the
  // post-board one reports the exact airlock (spawn tile) snap.
  wait_for_character(client, char, fn(x, y) { x == 5.5 && y == 4.5 }, 60)
}

pub fn ship_survives_whole_crew_ashore_test() {
  let s = start_sim()
  let client = process.new_subject()
  let observer = process.new_subject()
  let #(ship_id, char) = sim.add_player(s, "ada", client, 1000)
  let #(_obs_ship, _obs_char) = sim.add_player(s, "obs", observer, 1000)
  let assert protocol.SeatResult(ok: True, ..) =
    sim.request_stand(s, char, 1000)
  walk_to_ship_airlock(s, client, char)
  let assert protocol.DisembarkResult(ok: True, ..) =
    sim.request_disembark(s, char, 1000)
  // Crew ashore, zero bodies aboard: the ship stays in snapshots.
  let ids = receive_snapshot_ship_ids(observer)
  assert list.contains(ids, ship_id)
}

pub fn concourse_fan_out_is_isolated_test() {
  let s = start_sim()
  let ashore_client = process.new_subject()
  let aboard_client = process.new_subject()
  let #(_ship_a, char_a) = sim.add_player(s, "ada", ashore_client, 1000)
  let #(_ship_b, _char_b) = sim.add_player(s, "grace", aboard_client, 1000)
  let assert protocol.SeatResult(ok: True, ..) =
    sim.request_stand(s, char_a, 1000)
  walk_to_ship_airlock(s, ashore_client, char_a)
  let assert protocol.DisembarkResult(ok: True, ..) =
    sim.request_disembark(s, char_a, 1000)
  // ada (ashore) gets concourse messages; grace (aboard, same station's
  // dock) must never see one.
  let #(station_id, _) = receive_concourse(ashore_client)
  assert station_id == "meridian_highport"
  assert_no_concourse(aboard_client, 20)
}

pub fn buy_delivers_over_time_then_sell_pays_out_test() {
  let s = start_sim()
  let client = process.new_subject()
  let #(ship_id, char) = sim.add_player(s, "ada", client, 1000)
  let assert protocol.SeatResult(ok: True, ..) =
    sim.request_stand(s, char, 1000)
  walk_to_ship_airlock(s, client, char)
  let assert protocol.DisembarkResult(ok: True, ..) =
    sim.request_disembark(s, char, 1000)
  // Spawn tile (4.5, 4.5) is 1.0 from broker_main at (4, 3) — inside the
  // 1.2 sit range, no walking needed.
  let assert protocol.SeatResult(ok: True, ..) =
    sim.request_sit(s, char, "broker_main", 1000)

  let buy = sim.request_buy(s, char, "machinery", 2, 1000)
  assert buy.ok
  assert buy.price >= 51 && buy.price <= 59
  // Wallet debited immediately, before any goods land (robots need ~1 s
  // for the first unit). Skip past the cargo backlog buffered while
  // walking to the airlock: the first *debited* message is the one the
  // buy produced, and its hold must still be empty.
  let CargoMsg(wallet: wallet, hold: hold_at_debit, ..) =
    wait_for_cargo(
      client,
      fn(c) { c.ship_id == ship_id && c.wallet != 2000 },
      60,
    )
  assert wallet == 2000 - 2 * buy.price
  assert hold_at_debit == []

  // Robots carry 1 unit/s: both units aboard within ~2 s (cargo arrives at
  // 15 Hz; give it 60 messages ≈ 4 s of headroom).
  let CargoMsg(hold: hold, transfers: transfers, ..) =
    wait_for_cargo(
      client,
      fn(c) { c.hold == [#("machinery", 2)] && c.transfers == 0 },
      60,
    )
  assert hold == [#("machinery", 2)]
  assert transfers == 0

  let sell = sim.request_sell(s, char, "machinery", 2, 1000)
  assert sell.ok
  let expected_wallet = 2000 - 2 * buy.price + 2 * sell.price
  let CargoMsg(wallet: final_wallet, hold: final_hold, ..) =
    wait_for_cargo(
      client,
      fn(c) { c.wallet == expected_wallet && c.hold == [] },
      60,
    )
  assert final_wallet == expected_wallet
  assert final_hold == []
}

pub fn undock_is_blocked_mid_transfer_test() {
  let s = start_sim()
  let pilot = process.new_subject()
  let quartermaster = process.new_subject()
  let #(ship_a, char_pilot) = sim.add_player(s, "ada", pilot, 1000)
  let #(_ship_b, char_qm) = sim.add_player(s, "grace", quartermaster, 1000)
  // grace crews ada's ship, then goes ashore to the broker.
  let assert protocol.BoardResult(ok: True, ..) =
    sim.request_board(s, char_qm, ship_a, 1000)
  let assert protocol.DisembarkResult(ok: True, ..) =
    sim.request_disembark(s, char_qm, 1000)
  let assert protocol.SeatResult(ok: True, ..) =
    sim.request_sit(s, char_qm, "broker_main", 1000)
  let buy = sim.request_buy(s, char_qm, "machinery", 8, 1000)
  assert buy.ok
  // ada (still seated at the helm from login) cannot leave mid-load...
  assert sim.request_undock(s, char_pilot, 1000)
    == Error("transfer_in_progress")
  // ...until the robots finish (8 units at 1 u/s; wait via grace's cargo
  // feed — she's crew, so she gets it ashore).
  let _ =
    wait_for_cargo(quartermaster, fn(c) { c.hold == [#("machinery", 8)] }, 200)
  let assert Ok(Nil) = sim.request_undock(s, char_pilot, 1000)
}

pub fn trade_requires_broker_seat_test() {
  let s = start_sim()
  let client = process.new_subject()
  let #(_ship, char) = sim.add_player(s, "ada", client, 1000)
  let assert protocol.SeatResult(ok: True, ..) =
    sim.request_stand(s, char, 1000)
  // Aboard: no.
  let aboard = sim.request_buy(s, char, "machinery", 1, 1000)
  assert aboard
    == protocol.TradeResult(
      ok: False,
      reason: Some("not_at_broker"),
      commodity: "machinery",
      quantity: 1,
      price: 0,
    )
  // Ashore but standing: still no.
  walk_to_ship_airlock(s, client, char)
  let assert protocol.DisembarkResult(ok: True, ..) =
    sim.request_disembark(s, char, 1000)
  let standing = sim.request_buy(s, char, "machinery", 1, 1000)
  assert standing.reason == Some("not_at_broker")
}

pub fn request_market_resolves_ashore_and_docked_test() {
  let s = start_sim()
  let client = process.new_subject()
  let #(_ship, char) = sim.add_player(s, "ada", client, 1000)
  // Docked, aboard, seated at the helm: market is visible (cargo-console
  // manifest use case).
  let assert Ok(m) = sim.request_market(s, char, 1000)
  assert m.station_id == "meridian_highport"
  assert list.length(m.stores) == 4
  // Flying: no market.
  let assert Ok(Nil) = sim.request_undock(s, char, 1000)
  assert sim.request_market(s, char, 1000) == Error("no_market")
}
