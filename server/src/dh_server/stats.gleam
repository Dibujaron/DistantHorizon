//// Tick-duration statistics. Samples (in microseconds) accumulate in a
//// tumbling window of `window_size` ticks; when the window fills, its
//// percentiles are computed and become the reported figures until the next
//// window completes. The maximum is tracked across the whole run.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

const window_size = 1000

/// Percentiles of tick duration, in milliseconds. `max_ms` is the all-time
/// maximum; the percentiles are over the most recent completed window (or
/// the current partial window before the first one completes).
pub type TickStats {
  TickStats(p50_ms: Float, p95_ms: Float, p99_ms: Float, max_ms: Float)
}

/// Snapshot of server health, returned in reply to a stats request.
pub type StatsReply {
  StatsReply(ticks: Int, clients: Int, stats: TickStats)
}

pub type Accumulator {
  Accumulator(
    /// Samples in the currently filling window, newest first, in us.
    window: List(Int),
    window_len: Int,
    /// Percentiles of the last completed window.
    completed: Option(TickStats),
    all_time_max_us: Int,
    total_ticks: Int,
  )
}

pub fn new() -> Accumulator {
  Accumulator(
    window: [],
    window_len: 0,
    completed: None,
    all_time_max_us: 0,
    total_ticks: 0,
  )
}

/// Record one tick's duration in microseconds.
pub fn record(acc: Accumulator, sample_us: Int) -> Accumulator {
  let max_us = int.max(acc.all_time_max_us, sample_us)
  let window = [sample_us, ..acc.window]
  let window_len = acc.window_len + 1
  let total = acc.total_ticks + 1
  case window_len >= window_size {
    True ->
      Accumulator(
        window: [],
        window_len: 0,
        completed: Some(compute(window, max_us)),
        all_time_max_us: max_us,
        total_ticks: total,
      )
    False ->
      Accumulator(
        ..acc,
        window: window,
        window_len: window_len,
        all_time_max_us: max_us,
        total_ticks: total,
      )
  }
}

/// Current best-available stats: the last completed window, or the partial
/// one if no window has completed yet.
pub fn current(acc: Accumulator) -> TickStats {
  case acc.completed {
    Some(stats) -> TickStats(..stats, max_ms: us_to_ms(acc.all_time_max_us))
    None -> compute(acc.window, acc.all_time_max_us)
  }
}

fn compute(samples: List(Int), all_time_max_us: Int) -> TickStats {
  let sorted = list.sort(samples, int.compare)
  let n = list.length(sorted)
  TickStats(
    p50_ms: us_to_ms(percentile(sorted, n, 50)),
    p95_ms: us_to_ms(percentile(sorted, n, 95)),
    p99_ms: us_to_ms(percentile(sorted, n, 99)),
    max_ms: us_to_ms(all_time_max_us),
  )
}

/// Nearest-rank percentile over an ascending sorted list.
fn percentile(sorted: List(Int), n: Int, p: Int) -> Int {
  case n {
    0 -> 0
    _ -> {
      // ceil(p * n / 100) - 1, clamped to [0, n - 1]
      let rank = { p * n + 99 } / 100 - 1
      let index = int.clamp(rank, 0, n - 1)
      case sorted |> list.drop(index) |> list.first {
        Ok(v) -> v
        Error(_) -> 0
      }
    }
  }
}

fn us_to_ms(us: Int) -> Float {
  int.to_float(us) /. 1000.0
}
