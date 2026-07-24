//// Shared test helper: the content registries as they sit on disk, and the
//// Mockingbird's default fit resolved out of them.
////
//// Since M4 there is no `shipclass.load` — a `ShipClass` only ever comes from
//// `loadout.resolve` (or the wire), so every test that used to load the
//// bundled class from a file resolves the bundled HULL's default loadout here
//// instead. Paths are relative to `server/`, the directory `gleam test` runs
//// from.

import dh_server/glyphs
import dh_server/hull
import dh_server/loadout
import dh_server/module
import dh_server/part
import dh_server/shipclass
import gleam/dict

pub const hull_dir = "shipclasses"

pub const module_dir = "modules"

pub const part_dir = "parts"

/// The hull new ships spawn on in the bundled world.
pub const default_hull = "mockingbird"

/// `#(hulls, modules, parts, glyphs, spawn_hull)` — exactly `sim.start`'s
/// registry arguments.
pub fn sim_args() -> #(
  dict.Dict(String, hull.Hull),
  dict.Dict(String, module.Module),
  dict.Dict(String, part.Part),
  glyphs.Registry,
  String,
) {
  let assert Ok(hulls) = hull.load_all(hull_dir)
  let assert Ok(modules) = module.load_all(module_dir)
  let assert Ok(parts) = part.load_all(part_dir)
  #(hulls, modules, parts, glyphs.default(), default_hull)
}

/// The resolved default fit of `hull_id`.
pub fn resolve_default(hull_id: String) -> loadout.Fit {
  let #(hulls, modules, parts, reg, _) = sim_args()
  let assert Ok(h) = dict.get(hulls, hull_id)
  let assert Ok(f) =
    loadout.resolve(reg, h, modules, parts, loadout.default_for(h))
  f
}

/// The bundled Mockingbird as the sim resolves her at spawn — the replacement
/// for the old `shipclass.load("shipclasses/mockingbird.json")`.
pub fn mockingbird() -> shipclass.ShipClass {
  resolve_default(default_hull).class
}
