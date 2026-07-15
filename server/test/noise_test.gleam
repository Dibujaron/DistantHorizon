import dh_server/noise
import gleam/float
import gleam/int
import gleam/list

fn range(start: Int, end: Int) -> List(Int) {
  case start >= end {
    True -> []
    False -> [start, ..range(start + 1, end)]
  }
}

pub fn hash_is_deterministic_test() {
  assert noise.hash(42, 7) == noise.hash(42, 7)
  assert noise.hash(42, 7) != noise.hash(42, 8)
  assert noise.hash(42, 7) != noise.hash(43, 7)
}

pub fn seed_string_is_deterministic_and_distinct_test() {
  assert noise.seed_string(1, "machinery") == noise.seed_string(1, "machinery")
  assert noise.seed_string(1, "machinery") != noise.seed_string(1, "water")
  assert noise.seed_string(1, "machinery") != noise.seed_string(2, "machinery")
}

pub fn lattice_stays_in_unit_range_test() {
  list.each(range(0, 200), fn(x) {
    let v = noise.lattice(99, x)
    assert v >=. -1.0 && v <=. 1.0
  })
}

pub fn lattice_varies_test() {
  let values = list.map(range(0, 20), noise.lattice(99, _))
  assert list.unique(values) |> list.length > 1
}

pub fn at_matches_lattice_on_integers_test() {
  assert noise.at(7, 3.0) == noise.lattice(7, 3)
}

pub fn at_is_continuous_test() {
  // Adjacent samples 0.01 apart may never jump by more than a generous
  // bound; catches interpolation bugs (e.g. jumping straight between
  // lattice values).
  list.each(range(0, 100), fn(i) {
    let x = 0.05 *. int.to_float(i)
    let delta = float.absolute_value(noise.at(7, x) -. noise.at(7, x +. 0.01))
    assert delta <. 0.2
  })
}
