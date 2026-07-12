import dh_server/auth
import dh_server/protocol
import dh_server/sim
import dh_server/stats
import dh_server/world
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/string
import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn accept_all_rejects_empty_credentials_test() {
  let authenticate = auth.accept_all()
  assert authenticate("", "secret") == Error(auth.InvalidCredentials)
  assert authenticate("alice", "") == Error(auth.InvalidCredentials)
  assert authenticate("", "") == Error(auth.InvalidCredentials)
}

pub fn accept_all_accepts_nonempty_credentials_test() {
  let authenticate = auth.accept_all()
  assert authenticate("alice", "secret") == Ok(0)
}

pub fn stats_percentiles_test() {
  // 1000 samples of 100..100_000 us in some order.
  let acc =
    list.index_map(list.repeat(Nil, 1000), fn(_, i) { i + 1 })
    |> list.fold(stats.new(), fn(acc, i) { stats.record(acc, i * 100) })
  let s = stats.current(acc)
  assert s.p50_ms == 50.0
  assert s.p95_ms == 95.0
  assert s.p99_ms == 99.0
  assert s.max_ms == 100.0
}

fn test_world() -> world.World {
  let assert Ok(w) = world.load("worlds/m1_system.json")
  w
}

pub fn dead_client_is_unregistered_test() {
  let assert Ok(started) = sim.start(test_world())
  let sim_subject = started.data

  // A fake client handler process: creates its subject (the owner must be
  // the process that will receive on it), hands it back, then idles.
  let handoff = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      process.send(handoff, process.new_subject())
      process.sleep_forever()
    })
  let assert Ok(client) = process.receive(handoff, 1000)

  let _ship_id = sim.add_ship(sim_subject, client, 1000)
  assert sim.get_stats(sim_subject, 1000).clients == 1

  // Crash the client without any goodbye; the monitor must clean it up.
  process.kill(pid)
  assert wait_for_clients(sim_subject, 0, 100)
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

pub fn snapshot_shape_test() {
  let json = protocol.encode_snapshot(42, [])
  // Cheap shape checks; the Python harness does the full validation.
  assert string.contains(json, "\"v\":1")
  assert string.contains(json, "\"type\":\"snapshot\"")
  assert string.contains(json, "\"tick\":42")
}

pub fn add_ship_returns_incrementing_ids_test() {
  let assert Ok(started) = sim.start(test_world())
  let sim_subject = started.data

  let client1 = process.new_subject()
  let client2 = process.new_subject()

  assert sim.add_ship(sim_subject, client1, 1000) == 1
  assert sim.add_ship(sim_subject, client2, 1000) == 2
}

pub fn add_ship_snapshot_contains_docked_ship_test() {
  let assert Ok(started) = sim.start(test_world())
  let sim_subject = started.data

  let client = process.new_subject()
  let ship_id = sim.add_ship(sim_subject, client, 1000)

  let #(_tick, x) = receive_snapshot_at_or_after(client, ship_id, 0)
  // Docked at meridian_highport (radius 400 from meridian, itself at radius
  // 4000 from the origin at t=0): well away from the origin either way.
  assert x != 0.0
}

pub fn set_controls_and_undock_advances_x_test() {
  let assert Ok(started) = sim.start(test_world())
  let sim_subject = started.data

  let client = process.new_subject()
  let ship_id = sim.add_ship(sim_subject, client, 1000)

  let assert Ok(Nil) = sim.request_undock(sim_subject, ship_id, 1000)
  sim.set_controls(sim_subject, ship_id, 0.0, 1.0)

  let #(first_tick, first_x) = receive_snapshot_at_or_after(client, ship_id, 0)
  let #(_last_tick, last_x) =
    receive_snapshot_at_or_after(client, ship_id, first_tick + 30)

  assert last_x >. first_x
}

fn snapshot_decoder() -> decode.Decoder(#(Int, List(#(Int, Float)))) {
  use tick <- decode.field("tick", decode.int)
  use ships <- decode.field(
    "ships",
    decode.list({
      use id <- decode.field("id", decode.int)
      use x <- decode.field("x", decode.float)
      decode.success(#(id, x))
    }),
  )
  decode.success(#(tick, ships))
}

/// Receive snapshots on `client` until one with `tick >= min_tick` arrives,
/// returning that snapshot's tick and the x of `ship_id` within it.
fn receive_snapshot_at_or_after(
  client: process.Subject(sim.ClientMsg),
  ship_id: Int,
  min_tick: Int,
) -> #(Int, Float) {
  let assert Ok(sim.SendText(text)) = process.receive(client, 2000)
  let assert Ok(#(tick, ships)) = json.parse(text, snapshot_decoder())
  case tick >= min_tick {
    True -> {
      let assert Ok(#(_, x)) = list.find(ships, fn(pair) { pair.0 == ship_id })
      #(tick, x)
    }
    False -> receive_snapshot_at_or_after(client, ship_id, min_tick)
  }
}
