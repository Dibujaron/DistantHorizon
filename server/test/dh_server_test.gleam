import dh_server/protocol
import dh_server/sim
import dh_server/stats
import gleam/erlang/process
import gleam/list
import gleam/string
import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn parse_client_message_test() {
  assert protocol.parse_client_message("{\"v\":1,\"type\":\"get_stats\"}")
    == Ok(protocol.GetStats)
  assert protocol.parse_client_message("{\"v\":2,\"type\":\"get_stats\"}")
    == Error(Nil)
  assert protocol.parse_client_message("{\"v\":1,\"type\":\"warp_drive\"}")
    == Error(Nil)
  assert protocol.parse_client_message("not json") == Error(Nil)
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

pub fn dead_client_is_unregistered_test() {
  let assert Ok(started) = sim.start()
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

  sim.register(sim_subject, client)
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
