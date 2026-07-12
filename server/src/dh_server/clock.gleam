//// Monotonic clock access, used for tick scheduling and duration measurement.

/// Erlang time units we care about. The variant name compiles to the
/// equivalent Erlang atom (`microsecond`), which is what
/// `erlang:monotonic_time/1` expects.
pub type TimeUnit {
  Microsecond
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: TimeUnit) -> Int

/// Current monotonic time in microseconds. Only differences are meaningful.
pub fn now_us() -> Int {
  monotonic_time(Microsecond)
}
