//// Deterministic 1D value noise: the price-walk generator ported from
//// Classic's NoiseUtils (DynamicCommodityStore's
//// `price = initial + noise(seed, updateCount) * elasticity`). Pure
//// integer hashing — no RNG state — so the same (seed, x) always produces
//// the same value in every test and on every node.

import gleam/float
import gleam/int
import gleam/list
import gleam/string

const mask_64 = 0xffffffffffffffff

const golden = 0x9e3779b97f4a7c15

const mix_1 = 0xbf58476d1ce4e5b9

const mix_2 = 0x94d049bb133111eb

/// SplitMix64 finalizer over (seed, x): a well-mixed 64-bit integer.
pub fn hash(seed: Int, x: Int) -> Int {
  let z = int.bitwise_and(seed + x * golden, mask_64)
  let z = mix(z, 30, mix_1)
  let z = mix(z, 27, mix_2)
  int.bitwise_exclusive_or(z, int.bitwise_shift_right(z, 31))
}

fn mix(z: Int, shift: Int, multiplier: Int) -> Int {
  int.bitwise_and(
    int.bitwise_exclusive_or(z, int.bitwise_shift_right(z, shift)) * multiplier,
    mask_64,
  )
}

/// Fold a string into a seed, for per-(station, commodity) noise streams.
pub fn seed_string(seed: Int, text: String) -> Int {
  string.to_utf_codepoints(text)
  |> list.fold(seed, fn(acc, cp) { hash(acc, string.utf_codepoint_to_int(cp)) })
}

/// Lattice value at integer coordinate `x`, uniform in [-1.0, 1.0].
pub fn lattice(seed: Int, x: Int) -> Float {
  let bits = int.bitwise_and(hash(seed, x), 0xfffff)
  int.to_float(bits) /. 524_287.5 -. 1.0
}

/// Smoothly interpolated value noise at continuous `x`, in [-1.0, 1.0]:
/// a smoothstep blend between the two neighbouring lattice values, so
/// consecutive price epochs drift instead of jumping.
pub fn at(seed: Int, x: Float) -> Float {
  let x0f = float.floor(x)
  let x0 = float.round(x0f)
  let f = x -. x0f
  let t = f *. f *. { 3.0 -. 2.0 *. f }
  lattice(seed, x0) *. { 1.0 -. t } +. lattice(seed, x0 + 1) *. t
}
