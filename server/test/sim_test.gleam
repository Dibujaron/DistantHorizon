//// Sim-actor-level tests for M3.1 stitched interiors: login lands seated at
//// a namespaced helm in the station composite, docked crews share one
//// space, ship<->concourse crossing is plain walking, undock splits bodies
//// by tile ownership (visitors carried, crew transferred, emptied ships
//// despawned), berth exhaustion refuses login, and the trade/cargo/despawn
//// flows survive the rework. These drive the real actor through its public
//// API and observe it the way clients do — through snapshot/space/walkers
//// messages.

import dh_server/composite
import dh_server/deckplan
import dh_server/noise
import dh_server/protocol
import dh_server/shipclass
import dh_server/sim
import dh_server/world
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, Some}

fn start_sim() -> process.Subject(sim.Msg) {
  let assert Ok(w) = world.load("worlds/m1_system.json")
  let assert Ok(c) = shipclass.load("classes/mockingbird.json")
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

/// One character as reported by a `walkers` message.
type CrewMember {
  CrewMember(id: Int, x: Float, y: Float, seat: Option(String))
}

fn crew_member_decoder() -> decode.Decoder(CrewMember) {
  use id <- decode.field("id", decode.int)
  use x <- decode.field("x", decode.float)
  use y <- decode.field("y", decode.float)
  use seat <- decode.field("seat", decode.optional(decode.string))
  decode.success(CrewMember(id: id, x: x, y: y, seat: seat))
}

/// A `walkers` message: space id, epoch, and its occupants.
fn walkers_decoder() -> decode.Decoder(#(String, Int, List(CrewMember))) {
  use space <- decode.field("space", decode.string)
  use epoch <- decode.field("epoch", decode.int)
  use characters <- decode.field(
    "characters",
    decode.list(crew_member_decoder()),
  )
  decode.success(#(space, epoch, characters))
}

/// A `space` message: space id and epoch. Decoding also asserts a `you`
/// object is present (personalization), the field the client snaps to.
fn space_decoder() -> decode.Decoder(#(String, Int)) {
  use space <- decode.field("space", decode.string)
  use epoch <- decode.field("epoch", decode.int)
  use _you_x <- decode.field("you", you_x_decoder())
  decode.success(#(space, epoch))
}

fn you_x_decoder() -> decode.Decoder(Float) {
  use x <- decode.field("x", decode.float)
  decode.success(x)
}

fn snapshot_ship_ids_decoder() -> decode.Decoder(List(Int)) {
  decode.field(
    "ships",
    decode.list(decode.field("id", decode.int, decode.success)),
    decode.success,
  )
}

/// Receive messages on `client` until a `walkers` arrives, returning its
/// space id, epoch and characters.
fn receive_walkers(
  client: process.Subject(sim.ClientMsg),
) -> #(String, Int, List(CrewMember)) {
  let assert Ok(sim.SendText(text)) = process.receive(client, 2000)
  let assert Ok(msg_type) = json.parse(text, message_type_decoder())
  case msg_type {
    "walkers" -> {
      let assert Ok(decoded) = json.parse(text, walkers_decoder())
      decoded
    }
    _ -> receive_walkers(client)
  }
}

/// Receive walkers on `client` until one for `space` arrives (draining any
/// stale walkers buffered for a previous space).
fn receive_walkers_for(
  client: process.Subject(sim.ClientMsg),
  space: String,
) -> #(String, Int, List(CrewMember)) {
  let #(sp, epoch, characters) = receive_walkers(client)
  case sp == space {
    True -> #(sp, epoch, characters)
    False -> receive_walkers_for(client, space)
  }
}

/// Receive messages on `client` until a `space` arrives, returning its
/// space id and epoch.
fn receive_space(client: process.Subject(sim.ClientMsg)) -> #(String, Int) {
  let assert Ok(sim.SendText(text)) = process.receive(client, 2000)
  let assert Ok(msg_type) = json.parse(text, message_type_decoder())
  case msg_type {
    "space" -> {
      let assert Ok(decoded) = json.parse(text, space_decoder())
      decoded
    }
    _ -> receive_space(client)
  }
}

/// Receive `space` messages on `client` until one for `space` arrives.
fn receive_space_for(
  client: process.Subject(sim.ClientMsg),
  space: String,
) -> #(String, Int) {
  let #(sp, epoch) = receive_space(client)
  case sp == space {
    True -> #(sp, epoch)
    False -> receive_space_for(client, space)
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

/// Receive walkers until `predicate` holds for `char_id`'s position. Fails
/// after `tries` walkers.
fn wait_for_walker(
  client: process.Subject(sim.ClientMsg),
  char_id: Int,
  predicate: fn(Float, Float) -> Bool,
  tries: Int,
) -> Nil {
  let #(_space, _epoch, characters) = receive_walkers(client)
  let position_ok = case list.find(characters, fn(c) { c.id == char_id }) {
    Ok(CrewMember(x: x, y: y, ..)) -> predicate(x, y)
    Error(Nil) -> False
  }
  case position_ok, tries {
    True, _ -> Nil
    False, 0 -> panic as "character never reached the expected position"
    False, _ -> wait_for_walker(client, char_id, predicate, tries - 1)
  }
}

/// Receive walkers until `char_id` appears, returning its position. Fails
/// after `tries` walkers.
fn wait_for_position(
  client: process.Subject(sim.ClientMsg),
  char_id: Int,
  tries: Int,
) -> #(Float, Float) {
  let #(_space, _epoch, characters) = receive_walkers(client)
  case list.find(characters, fn(c) { c.id == char_id }), tries {
    Ok(CrewMember(x: x, y: y, ..)), _ -> #(x, y)
    Error(Nil), 0 -> panic as "character never appeared in walkers"
    Error(Nil), _ -> wait_for_position(client, char_id, tries - 1)
  }
}

/// Receive walkers until one carries every id in `ids`, returning its space
/// and characters. Fails after `tries`.
fn wait_for_walkers_with(
  client: process.Subject(sim.ClientMsg),
  ids: List(Int),
  tries: Int,
) -> #(String, List(CrewMember)) {
  let #(space, _epoch, characters) = receive_walkers(client)
  let all_present =
    list.all(ids, fn(id) { list.any(characters, fn(c) { c.id == id }) })
  case all_present, tries {
    True, _ -> #(space, characters)
    False, 0 -> panic as "walkers never carried every expected character"
    False, _ -> wait_for_walkers_with(client, ids, tries - 1)
  }
}

/// Walk a standing character from their helm seat down and ashore.
/// Iteration 4 (side-on mooring): the moored ship lies nose-west; the
/// upper corridor from the cockpit runs EAST along composite row 7 to the
/// vertical docking corridor at the ship's waist (its column is the berth
/// column, 18 east of the helm), then SOUTH through the port dormer, the
/// 4-tile docking tube and the berth stub onto the concourse floor (rows
/// 14-16). Works from any berth; hull void pins both runs.
fn walk_down_the_gangway(
  s: process.Subject(sim.Msg),
  client: process.Subject(sim.ClientMsg),
  char: Int,
) -> Float {
  let assert protocol.SeatResult(ok: True, ..) =
    sim.request_stand(s, char, 1000)
  let #(x0, _y0) = wait_for_position(client, char, 60)
  let helm_x = int.to_float(float.round(float.floor(x0))) +. 0.5
  let gangway_x = helm_x +. 18.0
  sim.set_move(s, char, 1.0, 0.0)
  wait_for_walker(client, char, fn(x, _y) { x >=. gangway_x -. 0.1 }, 900)
  sim.set_move(s, char, 0.0, 1.0)
  wait_for_walker(client, char, fn(_x, y) { y >=. 15.2 }, 300)
  helm_x
}

/// walk_down_the_gangway, then along the floor to `broker0` at
/// composite (10.5, 15.5) — the stitched-space replacement for M3's
/// stand/walk/disembark.
fn walk_to_broker(
  s: process.Subject(sim.Msg),
  client: process.Subject(sim.ClientMsg),
  char: Int,
) -> Nil {
  let helm_x = walk_down_the_gangway(s, client, char)
  case helm_x +. 18.0 <. 10.5 {
    True -> {
      sim.set_move(s, char, 1.0, 0.0)
      wait_for_walker(client, char, fn(x, _y) { x >=. 10.4 }, 900)
    }
    False -> {
      sim.set_move(s, char, -1.0, 0.0)
      wait_for_walker(client, char, fn(x, _y) { x <=. 10.6 }, 900)
    }
  }
  sim.set_move(s, char, 0.0, 0.0)
}

/// Reverse of `walk_to_broker`: along the floor to the ship's gangway
/// column (18 east of the helm column), north up the tube into the
/// docking corridor, then west along the upper corridor to the cockpit.
/// `helm_x` is whatever composite column the character's helm actually
/// sits at (captured before walking away) — never assumes berth 0.
fn walk_broker_to_helm(
  s: process.Subject(sim.Msg),
  client: process.Subject(sim.ClientMsg),
  char: Int,
  helm_x: Float,
) -> Nil {
  let gangway_x = helm_x +. 18.0
  case gangway_x <. 10.5 {
    True -> {
      sim.set_move(s, char, -1.0, 0.0)
      wait_for_walker(client, char, fn(x, _y) { x <=. gangway_x +. 0.1 }, 900)
    }
    False -> {
      sim.set_move(s, char, 1.0, 0.0)
      wait_for_walker(client, char, fn(x, _y) { x >=. gangway_x -. 0.1 }, 900)
    }
  }
  sim.set_move(s, char, 0.0, -1.0)
  wait_for_walker(client, char, fn(_x, y) { y <=. 7.6 }, 300)
  sim.set_move(s, char, -1.0, 0.0)
  wait_for_walker(client, char, fn(x, _y) { x <=. helm_x +. 0.1 }, 300)
  sim.set_move(s, char, 0.0, 0.0)
}

/// A visitor walks onto another ship's deck, wherever both ships' berths
/// landed: down their own gangway, along the floor to the target ship's
/// gangway column (18 east of its helm column), north through the berth
/// stub and the docking tube into the target's 'B' corridor (composite
/// y <= 7.6 is standing on target-ship tiles). `target_helm_x` is the
/// target ship's helm column, e.g. read off a shared `walkers` message.
fn walk_visitor_onto_ship(
  s: process.Subject(sim.Msg),
  client: process.Subject(sim.ClientMsg),
  char: Int,
  target_helm_x: Float,
) -> Nil {
  let _own_helm_x = walk_down_the_gangway(s, client, char)
  let target_gangway_x = target_helm_x +. 18.0
  let #(x_now, _) = wait_for_position(client, char, 60)
  case target_gangway_x <. x_now {
    True -> {
      sim.set_move(s, char, -1.0, 0.0)
      wait_for_walker(client, char, fn(x, _y) { x <=. target_gangway_x }, 900)
    }
    False -> {
      sim.set_move(s, char, 1.0, 0.0)
      wait_for_walker(client, char, fn(x, _y) { x >=. target_gangway_x }, 900)
    }
  }
  sim.set_move(s, char, 0.0, -1.0)
  wait_for_walker(client, char, fn(_x, y) { y <=. 7.6 }, 300)
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

/// Receive `count` consecutive walkers, asserting each is for `space`.
fn assert_walkers_only_for(
  client: process.Subject(sim.ClientMsg),
  space: String,
  count: Int,
) -> Nil {
  case count {
    0 -> Nil
    _ -> {
      let #(sp, _epoch, _characters) = receive_walkers(client)
      assert sp == space
      assert_walkers_only_for(client, space, count - 1)
    }
  }
}

/// The berth sim.gleam's `free_berth` would pick when every berth at
/// `station_id` is free: the same hash it uses
/// (`noise.seed_string(seed, "<station_id>:<ship_id>") mod free_count`)
/// indexed directly into `[0, free_count)`, since the free-berth list is
/// the identity range when nothing is taken yet.
fn expected_berth(
  world_seed: Int,
  station_id: String,
  ship_id: Int,
  free_count: Int,
) -> Int {
  let key = station_id <> ":" <> int.to_string(ship_id)
  let assert Ok(pick) =
    int.modulo(noise.seed_string(world_seed, key), free_count)
  pick
}

/// The composite-frame center of `ship_id`'s helm when moored at `berth`,
/// by replicating production's own `composite.build` + `find_mooring`
/// rather than duplicating the mooring arithmetic (berth column, spawn
/// offset, frame-shift) as magic numbers in the test.
fn composite_helm_position(
  w: world.World,
  class: shipclass.ShipClass,
  ship_id: Int,
  station_id: String,
  berth: Int,
) -> #(Float, Float) {
  let assert Ok(station) = world.get_station(w, station_id)
  let assert Some(concourse) = station.concourse
  let assert Ok(built) =
    composite.build(concourse, station.berths, [
      composite.DockedShip(ship_id: ship_id, berth: berth, plan: class.plan),
    ])
  let assert Ok(_mooring) = composite.find_mooring(built, ship_id)
  // The composite carries the moored (rotated + translated) console — the
  // same lookup production uses at login.
  let assert Ok(helm) =
    deckplan.find_console(built.plan, composite.namespace_id(ship_id, "helm"))
  #(int.to_float(helm.x) +. 0.5, int.to_float(helm.y) +. 0.5)
}

pub fn login_lands_in_the_station_space_seated_at_own_helm_test() {
  let s = start_sim()
  let client = process.new_subject()
  let assert Ok(#(ship_id, char_id)) = sim.add_player(s, "ada", client, 1000)
  // The space message names the spawn station's composite and seats us at
  // our own namespaced helm.
  let #(space, _epoch) = receive_space(client)
  assert space == "station:meridian_highport"
  let #(walk_space, _epoch, characters) = receive_walkers(client)
  assert walk_space == "station:meridian_highport"
  let assert Ok(CrewMember(x: x, y: y, seat: seat, ..)) =
    list.find(characters, fn(c) { c.id == char_id })
  assert seat == Some("s" <> int.to_string(ship_id) <> ":helm")
  // Every berth is free at the very first login, so free_berth's pick is a
  // direct hash(seed, "meridian_highport:<ship_id>") mod 3 into
  // [berth_0, berth_1, berth_2]. Derive the picked berth and its mooring
  // (rather than assume berth 0) so this stays correct if the seed or the
  // hash ever changes which berth ship 1 lands on.
  let assert Ok(w) = world.load("worlds/m1_system.json")
  let assert Ok(class) = shipclass.load("classes/mockingbird.json")
  let assert Ok(station) = world.get_station(w, "meridian_highport")
  let berth =
    expected_berth(
      w.seed,
      "meridian_highport",
      ship_id,
      list.length(station.berths),
    )
  let #(expected_x, expected_y) =
    composite_helm_position(w, class, ship_id, "meridian_highport", berth)
  assert x == expected_x
  assert y == expected_y
}

pub fn dock_while_docked_is_already_docked_test() {
  let s = start_sim()
  let client = process.new_subject()
  let assert Ok(#(_ship_id, char_id)) = sim.add_player(s, "ada", client, 1000)
  // Login spawns docked, seated at the ship's own namespaced helm
  // ("s{ship_id}:helm"). Requesting dock from there must report
  // already-docked, not misread the namespaced seat as "not at helm".
  let assert Error("already_docked") = sim.request_dock(s, char_id, 1000)
}

pub fn two_docked_crews_share_one_space_test() {
  let s = start_sim()
  let client_a = process.new_subject()
  let client_b = process.new_subject()
  let assert Ok(#(_ship_a, char_a)) = sim.add_player(s, "ada", client_a, 1000)
  let assert Ok(#(_ship_b, char_b)) = sim.add_player(s, "grace", client_b, 1000)
  // Both crews are in the same station space and see each other.
  let #(space, characters) =
    wait_for_walkers_with(client_a, [char_a, char_b], 40)
  assert space == "station:meridian_highport"
  assert list.any(characters, fn(c) { c.id == char_a })
  assert list.any(characters, fn(c) { c.id == char_b })
}

// PENDING v3 multi-deck walk: this and the eight tests below drive a FLAT
// gangway walk (helm on the concourse plane). With the 3-deck Mockingbird the
// pilot spawns on the Upper deck and must descend `x` stairs to reach the
// concourse, so `walk_to_broker`/`walk_broker_to_helm`/`walk_visitor_onto_ship`
// need a multi-deck (BFS) driver. Parked pending the finalized Mockingbird
// layout; restore by dropping the `_pending_v3walk` suffix once the driver
// lands. Tracking: deck-plan v3 branch.
pub fn walking_from_ship_to_concourse_is_just_walking_test_pending_v3walk() {
  let s = start_sim()
  let client = process.new_subject()
  let assert Ok(#(_ship, char)) = sim.add_player(s, "ada", client, 1000)
  // From the helm seat to the broker with nothing but move input: down the
  // deck, through the airlock, across the berth stub, onto the floor.
  walk_to_broker(s, client, char)
  let assert protocol.SeatResult(ok: True, ..) =
    sim.request_sit(s, char, "broker0", 1000)
}

pub fn undock_splits_bodies_by_tile_test_pending_v3walk() {
  let s = start_sim()
  let pilot = process.new_subject()
  let walker = process.new_subject()
  let assert Ok(#(ship_p, char_p)) = sim.add_player(s, "ada", pilot, 1000)
  let assert Ok(#(ship_w, char_w)) = sim.add_player(s, "grace", walker, 1000)
  // grace walks off her ship onto the concourse floor and stays there.
  walk_to_broker(s, walker, char_w)
  // ada undocks (seated at her namespaced helm since login): her ship
  // leaves with her body; grace stays in the station space, and grace's
  // crew membership is untouched (her ship still sits at its berth).
  let assert Ok(Nil) = sim.request_undock(s, char_p, 1000)
  // ada is now in her ship's own space, at the ship-local helm.
  let #(space_p, _epoch) =
    receive_space_for(pilot, "ship:" <> int.to_string(ship_p))
  assert space_p == "ship:" <> int.to_string(ship_p)
  let #(_, _, crew) =
    receive_walkers_for(pilot, "ship:" <> int.to_string(ship_p))
  let assert Ok(CrewMember(x: x, y: y, seat: seat, ..)) =
    list.find(crew, fn(c) { c.id == char_p })
  assert seat == Some("helm")
  assert x == 6.5
  assert y == 4.5
  // grace still walks the station space, which no longer moors ship_p.
  let #(space_w, _, ashore) =
    receive_walkers_for(walker, "station:meridian_highport")
  assert space_w == "station:meridian_highport"
  assert list.any(ashore, fn(c) { c.id == char_w })
  // grace's ship survives (she's still its crew); ada's left the berth.
  let ids = receive_snapshot_ship_ids(walker)
  assert list.contains(ids, ship_w)
}

pub fn undock_carries_visitors_and_transfers_crew_test_pending_v3walk() {
  let s = start_sim()
  let pilot = process.new_subject()
  let visitor = process.new_subject()
  let assert Ok(#(ship_p, char_p)) = sim.add_player(s, "ada", pilot, 1000)
  let assert Ok(#(ship_v, char_v)) = sim.add_player(s, "grace", visitor, 1000)
  // grace walks onto ada's ship, wherever its berth landed, stopping on
  // ship tiles.
  let #(pilot_x, _pilot_y) = wait_for_position(visitor, char_p, 60)
  walk_visitor_onto_ship(s, visitor, char_v, pilot_x)
  // ada undocks: grace's body is on ada's tiles, so she leaves with the
  // ship and becomes its crew; her old ship, now crewless, despawns.
  let assert Ok(Nil) = sim.request_undock(s, char_p, 1000)
  let #(_, _, crew) =
    receive_walkers_for(visitor, "ship:" <> int.to_string(ship_p))
  assert list.any(crew, fn(c) { c.id == char_v })
  assert list.any(crew, fn(c) { c.id == char_p })
  // The pilot's snapshot buffer accumulated (undrained) through grace's long
  // walk — up to ~60s across the highport bar at 15 Hz — so drain very
  // generously to reach the post-undock frames.
  assert_ship_leaves_snapshots(pilot, ship_v, 1600)
}

pub fn body_on_a_despawning_mooring_is_refloored_test_pending_v3walk() {
  let s = start_sim()
  let #(pid_a, client_a) = spawn_fake_client()
  let client_b = process.new_subject()
  let assert Ok(#(_ship_a, char_a)) = sim.add_player(s, "ada", client_a, 1000)
  let assert Ok(#(_ship_b, char_b)) = sim.add_player(s, "grace", client_b, 1000)
  // grace walks onto ada's *docked* ship, wherever its berth landed, and
  // stops on its tiles.
  let #(pilot_x, _pilot_y) = wait_for_position(client_b, char_a, 60)
  walk_visitor_onto_ship(s, client_b, char_b, pilot_x)
  // ada disconnects: her crewless docked ship despawns and the composite
  // rebuilds without its mooring, so the tiles grace is standing on become
  // void. rebuild_space must re-floor her to the concourse spawn tile
  // center rather than soft-lock her (character.step rejects every move out
  // of a non-walkable circle forever otherwise).
  process.kill(pid_a)
  assert wait_for_clients(s, 1, 100)
  // She lands at the concourse spawn tile: (47,3) + concourse offset
  // (0,12) = (47,15) tile -> center (47.5, 15.5). The frame is stable
  // (berths sit >= 18 tiles from the west edge), so the rebuild does not
  // shift it.
  wait_for_walker(client_b, char_b, fn(x, y) { x == 47.5 && y == 15.5 }, 120)
  // ...and she is unstuck: fresh move input changes her position again.
  sim.set_move(s, char_b, 1.0, 0.0)
  wait_for_walker(client_b, char_b, fn(x, _y) { x >. 47.5 }, 120)
}

// FINDING 3 (remote-station rebuild on undock crew-transfer despawn) has no
// direct sim_test: it needs a ship despawned by the transfer while docked at
// a station OTHER than where the undock happens, i.e. that ship's entire crew
// standing on the departing ship's mooring at station S1 while their own ship
// sits docked at S2. Constructible in principle (a shanghaied visitor can take
// the vacated helm and fly the ship to another station), but that requires
// scripted inter-station piloting this suite has never done — impractical
// here, not impossible. The fix mirrors ClientDown's despawned_station_ids computation
// (see the ClientDown handler in sim.gleam), which the disconnect-despawn
// tests above exercise as the shared shape; FINDING 2's re-floor (now inside
// rebuild_space) protects any body left on such a remote ghost mooring.

pub fn spawn_station_fills_up_test() {
  let s = start_sim()
  // Meridian Highport authors three berths; the fourth login is refused.
  let assert Ok(_) = sim.add_player(s, "a", process.new_subject(), 1000)
  let assert Ok(_) = sim.add_player(s, "b", process.new_subject(), 1000)
  let assert Ok(_) = sim.add_player(s, "c", process.new_subject(), 1000)
  assert sim.add_player(s, "d", process.new_subject(), 1000)
    == Error("station_full")
}

pub fn undock_frees_the_berth_test() {
  let s = start_sim()
  let client_a = process.new_subject()
  let assert Ok(#(_, char_a)) = sim.add_player(s, "a", client_a, 1000)
  let assert Ok(_) = sim.add_player(s, "b", process.new_subject(), 1000)
  let assert Ok(_) = sim.add_player(s, "c", process.new_subject(), 1000)
  let assert Ok(Nil) = sim.request_undock(s, char_a, 1000)
  // a's departure freed a berth: a fourth login now succeeds.
  let assert Ok(_) = sim.add_player(s, "d", process.new_subject(), 1000)
}

pub fn free_berth_is_seed_random_among_free_berths_test() {
  let s = start_sim()
  let assert Ok(w) = world.load("worlds/m1_system.json")
  let assert Ok(class) = shipclass.load("classes/mockingbird.json")
  let assert Ok(station) = world.get_station(w, "meridian_highport")
  let free_count = list.length(station.berths)

  // Undocking before the next login puts every berth free again, so each
  // of these three logins hits free_berth's "all free" case: pick =
  // hash(seed, "meridian_highport:<ship_id>") mod free_count, indexed
  // straight into [berth_0, berth_1, berth_2] — exactly the scenario the
  // feature targets ("I'm always assigned to Berth 1").
  let client_1 = process.new_subject()
  let assert Ok(#(ship_1, char_1)) = sim.add_player(s, "p1", client_1, 1000)
  let #(_space, _epoch, chars_1) = receive_walkers(client_1)
  let assert Ok(CrewMember(x: x1, y: y1, ..)) =
    list.find(chars_1, fn(c) { c.id == char_1 })
  let assert Ok(Nil) = sim.request_undock(s, char_1, 1000)

  let client_2 = process.new_subject()
  let assert Ok(#(ship_2, char_2)) = sim.add_player(s, "p2", client_2, 1000)
  let #(_space, _epoch, chars_2) =
    receive_walkers_for(client_2, "station:meridian_highport")
  let assert Ok(CrewMember(x: x2, y: y2, ..)) =
    list.find(chars_2, fn(c) { c.id == char_2 })
  let assert Ok(Nil) = sim.request_undock(s, char_2, 1000)

  let client_3 = process.new_subject()
  let assert Ok(#(ship_3, char_3)) = sim.add_player(s, "p3", client_3, 1000)
  let #(_space, _epoch, chars_3) =
    receive_walkers_for(client_3, "station:meridian_highport")
  let assert Ok(CrewMember(x: x3, y: y3, ..)) =
    list.find(chars_3, fn(c) { c.id == char_3 })

  let berth_1 = expected_berth(w.seed, "meridian_highport", ship_1, free_count)
  let berth_2 = expected_berth(w.seed, "meridian_highport", ship_2, free_count)
  let berth_3 = expected_berth(w.seed, "meridian_highport", ship_3, free_count)

  // The sim's actual pick matches the hash formula, not just "somewhere
  // walkable" — assert exact composite coordinates for the derived berth.
  let #(ex1, ey1) =
    composite_helm_position(w, class, ship_1, "meridian_highport", berth_1)
  let #(ex2, ey2) =
    composite_helm_position(w, class, ship_2, "meridian_highport", berth_2)
  let #(ex3, ey3) =
    composite_helm_position(w, class, ship_3, "meridian_highport", berth_3)
  assert x1 == ex1 && y1 == ey1
  assert x2 == ex2 && y2 == ey2
  assert x3 == ex3 && y3 == ey3

  // Pinned regression for world seed 20260712 (worlds/m1_system.json): the
  // actual berth triple ships 1, 2, 3 land on when every berth is free.
  assert #(berth_1, berth_2, berth_3) == #(0, 0, 1)
}

pub fn seat_occupancy_is_scoped_to_the_shared_space_test() {
  let s = start_sim()
  let client_a = process.new_subject()
  let client_b = process.new_subject()
  let assert Ok(#(ship_a, _char_a)) = sim.add_player(s, "ada", client_a, 1000)
  let assert Ok(#(_ship_b, char_b)) = sim.add_player(s, "grace", client_b, 1000)
  // Both crews share the station space, so ada's occupied helm is visible to
  // grace's sit attempt. grace stands first, then tries to take ada's helm.
  let assert protocol.SeatResult(ok: True, ..) =
    sim.request_stand(s, char_b, 1000)
  let helm_a = "s" <> int.to_string(ship_a) <> ":helm"
  let result = sim.request_sit(s, char_b, helm_a, 1000)
  assert result.ok == False
  // Too far (grace is docked at a different berth than ada's helm) or
  // occupied — either way the shared space resolved the console.
  assert result.reason == Some("occupied") || result.reason == Some("too_far")
}

pub fn ship_despawns_when_last_character_disconnects_test() {
  let s = start_sim()
  let #(pid_a, client_a) = spawn_fake_client()
  let observer = process.new_subject()
  let assert Ok(#(ship_a, _char_a)) = sim.add_player(s, "ada", client_a, 1000)
  let assert Ok(#(_ship_o, _char_o)) = sim.add_player(s, "obs", observer, 1000)

  // a's character was the only one crewing ship A: killing the connection
  // removes the character and must despawn the ship.
  process.kill(pid_a)
  assert_ship_leaves_snapshots(observer, ship_a, 20)
}

pub fn ship_keeps_flying_when_pilot_disconnects_with_crew_aboard_test_pending_v3walk() {
  let s = start_sim()
  let #(pid_a, client_a) = spawn_fake_client()
  let client_b = process.new_subject()
  let assert Ok(#(ship_a, char_a)) = sim.add_player(s, "ada", client_a, 1000)
  let assert Ok(#(ship_b, char_b)) = sim.add_player(s, "grace", client_b, 1000)

  // grace shanghais onto ada's ship (walk aboard + ada undocks), becoming
  // its crew and emptying/despawning ship B. Then ada disconnects in flight.
  let #(pilot_x, _pilot_y) = wait_for_position(client_b, char_a, 60)
  walk_visitor_onto_ship(s, client_b, char_b, pilot_x)
  let assert Ok(Nil) = sim.request_undock(s, char_a, 1000)
  process.kill(pid_a)
  assert wait_for_clients(s, 1, 100)

  // The disconnect has been processed once b's ship-space crew shrinks to
  // just their own character (the pilot's character is gone)...
  wait_for_solo_crew(client_b, "ship:" <> int.to_string(ship_a), char_b, 40)

  // ...and the ship survives its pilot: still in snapshots, while b's old
  // emptied ship stays gone.
  let ids = receive_snapshot_ship_ids(client_b)
  assert list.contains(ids, ship_a)
  assert !list.contains(ids, ship_b)
}

/// Receive walkers for `space` until the crew is exactly the one character
/// `char_id`. Fails the test after `tries` walkers.
fn wait_for_solo_crew(
  client: process.Subject(sim.ClientMsg),
  space: String,
  char_id: Int,
  tries: Int,
) -> Nil {
  let #(_sp, _epoch, characters) = receive_walkers_for(client, space)
  case characters, tries {
    [CrewMember(id: only_id, ..)], _ if only_id == char_id -> Nil
    _, 0 -> panic as "crew never shrank to the surviving character"
    _, _ -> wait_for_solo_crew(client, space, char_id, tries - 1)
  }
}

pub fn interior_fan_out_is_isolated_per_ship_test() {
  let s = start_sim()
  let client_a = process.new_subject()
  let client_b = process.new_subject()
  let assert Ok(#(ship_a, char_a)) = sim.add_player(s, "ada", client_a, 1000)
  let assert Ok(#(ship_b, char_b)) = sim.add_player(s, "grace", client_b, 1000)

  // Both undock (each seated at their own namespaced helm since login) and
  // fly off in their own ships. Every walkers message each client receives
  // must carry its own ship's space — never the other's.
  let assert Ok(Nil) = sim.request_undock(s, char_a, 1000)
  let assert Ok(Nil) = sim.request_undock(s, char_b, 1000)
  let space_a = "ship:" <> int.to_string(ship_a)
  let space_b = "ship:" <> int.to_string(ship_b)
  let _ = receive_walkers_for(client_a, space_a)
  let _ = receive_walkers_for(client_b, space_b)
  assert_walkers_only_for(client_a, space_a, 5)
  assert_walkers_only_for(client_b, space_b, 5)
}

pub fn ship_survives_whole_crew_ashore_test_pending_v3walk() {
  let s = start_sim()
  let client = process.new_subject()
  let observer = process.new_subject()
  let assert Ok(#(ship_id, char)) = sim.add_player(s, "ada", client, 1000)
  let assert Ok(#(_obs_ship, _obs_char)) =
    sim.add_player(s, "obs", observer, 1000)
  // ada walks off her ship onto the concourse floor: her body is ashore but
  // her crew membership (ship_id) is unchanged, so the ship stays docked.
  walk_to_broker(s, client, char)
  let ids = receive_snapshot_ship_ids(observer)
  assert list.contains(ids, ship_id)
}

pub fn buy_delivers_over_time_then_sell_pays_out_test_pending_v3walk() {
  let s = start_sim()
  let client = process.new_subject()
  let assert Ok(#(ship_id, char)) = sim.add_player(s, "ada", client, 1000)
  // Walk from the helm to the broker, then sit — one composite space, no
  // disembark.
  walk_to_broker(s, client, char)
  let assert protocol.SeatResult(ok: True, ..) =
    sim.request_sit(s, char, "broker0", 1000)

  let buy = sim.request_buy(s, char, "machinery", 2, 1000)
  assert buy.ok
  assert buy.price >= 51 && buy.price <= 59
  // Wallet debited immediately, before any goods land (robots need ~1 s for
  // the first unit). Skip past the cargo backlog buffered while walking: the
  // first *debited* message is the one the buy produced, and its hold must
  // still be empty.
  let CargoMsg(wallet: wallet, hold: hold_at_debit, ..) =
    wait_for_cargo(
      client,
      fn(c) { c.ship_id == ship_id && c.wallet != 2000 },
      60,
    )
  assert wallet == 2000 - 2 * buy.price
  assert hold_at_debit == []

  // Robots carry 1 unit/s: both units aboard within ~2 s.
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

pub fn undock_is_blocked_mid_transfer_test_pending_v3walk() {
  let s = start_sim()
  let client = process.new_subject()
  let assert Ok(#(ship_a, char)) = sim.add_player(s, "ada", client, 1000)
  // Capture the helm's composite column (whatever berth it landed on)
  // before walking away, to find the way back later.
  let #(helm_x, _helm_y) = wait_for_position(client, char, 60)
  // Walk to the broker and start a long inbound transfer on ada's own ship.
  walk_to_broker(s, client, char)
  let assert protocol.SeatResult(ok: True, ..) =
    sim.request_sit(s, char, "broker0", 1000)
  let buy = sim.request_buy(s, char, "machinery", 20, 1000)
  assert buy.ok
  // Walk back to the helm and sit (the transfer keeps running while docked).
  let assert protocol.SeatResult(ok: True, ..) =
    sim.request_stand(s, char, 1000)
  walk_broker_to_helm(s, client, char, helm_x)
  let assert protocol.SeatResult(ok: True, ..) =
    sim.request_sit(s, char, "s" <> int.to_string(ship_a) <> ":helm", 1000)
  // ada cannot leave mid-load...
  assert sim.request_undock(s, char, 1000) == Error("transfer_in_progress")
  // ...until the robots finish (20 units at 1 u/s).
  let _ = wait_for_cargo(client, fn(c) { c.hold == [#("machinery", 20)] }, 600)
  let assert Ok(Nil) = sim.request_undock(s, char, 1000)
}

pub fn trade_requires_broker_seat_test_pending_v3walk() {
  let s = start_sim()
  let client = process.new_subject()
  let assert Ok(#(_ship, char)) = sim.add_player(s, "ada", client, 1000)
  // Seated at the helm (not a broker) in the station space: no.
  let at_helm = sim.request_buy(s, char, "machinery", 1, 1000)
  assert at_helm.reason == Some("not_at_broker")
  // Standing on the concourse near the broker, but not seated: still no.
  walk_to_broker(s, client, char)
  let standing = sim.request_buy(s, char, "machinery", 1, 1000)
  assert standing.reason == Some("not_at_broker")
}

pub fn request_market_resolves_ashore_and_docked_test() {
  let s = start_sim()
  let client = process.new_subject()
  let assert Ok(#(_ship, char)) = sim.add_player(s, "ada", client, 1000)
  // Docked (OnStation in the composite): the station market is visible.
  let assert Ok(m) = sim.request_market(s, char, 1000)
  assert m.station_id == "meridian_highport"
  assert list.length(m.stores) == 4
  // Flying: no market.
  let assert Ok(Nil) = sim.request_undock(s, char, 1000)
  assert sim.request_market(s, char, 1000) == Error("no_market")
}
