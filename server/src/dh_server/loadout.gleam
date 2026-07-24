//// LOADOUTS: which interior module sits in each of a hull's slots and which
//// exterior part hangs on each of its mounts — and the bake that turns
//// hull + loadout into the resolved `ShipClass` the sim, the composite and the
//// wire already speak (`docs/modules.md`).
////
//// The bake is deliberately dumb: it splices each module's authored character
//// blocks into the hull's authored rows (void = passthrough) and re-runs the
//// ordinary v3 parse. Consoles, the mooring tile, docking ports and the
//// pallet-derived hold capacity therefore all fall out of the STAMPED map,
//// with no derivation logic of its own — install a cockpit and the helm
//// console exists because the glyph does.
////
//// Validation is one rule — `sum(provides) >= sum(requires)` pooled per tag —
//// plus three structural checks (one module per slot, every non-void overlay
//// cell lands on that slot's digit, mount kind/size fits the part). There is
//// never any reachability or geometry analysis: walkability is the hull
//// author's responsibility and the module guarantees its own insides.

import dh_server/deckplan.{type DeckPlan}
import dh_server/glyphs
import dh_server/hull.{type Hull, type Mount, type Slot}
import dh_server/module.{type Module, type Patch}
import dh_server/part.{type Part}
import dh_server/shipclass.{type ShipClass}
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string

/// What a specific ship is fitted with: its hull id, its slot -> module
/// assignments and its mount -> part assignments.
pub type Loadout {
  Loadout(
    hull: String,
    modules: List(#(String, String)),
    parts: List(#(String, String)),
  )
}

/// A resolved loadout: the fit itself, the baked class it produced, and the
/// total mass the flight stats were divided by.
pub type Fit {
  Fit(loadout: Loadout, class: ShipClass, mass: Float)
}

/// The loadout a hull ships with — the Mockingbird's default loadout is how
/// today's authored deck is expressed, so nothing about her out-of-the-box
/// look changes.
pub fn default_for(h: Hull) -> Loadout {
  Loadout(hull: h.id, modules: h.default_modules, parts: h.default_parts)
}

/// Resolve a loadout onto a hull. `Error` carries a machine-readable reason
/// (`"tag_deficit:power"`, `"out_of_slot_bounds:<module id>"`, …) that the
/// `refit_result` wire message forwards verbatim.
pub fn resolve(
  reg: glyphs.Registry,
  h: Hull,
  modules: Dict(String, Module),
  parts: Dict(String, Part),
  lo: Loadout,
) -> Result(Fit, String) {
  use <- guard(lo.hull == h.id, "loadout_wrong_hull:" <> lo.hull)
  use fitted <- result.try(lookup_modules(h, modules, lo))
  use mounted <- result.try(lookup_parts(h, parts, lo))
  use _ <- result.try(check_tags(h, fitted, mounted))
  use base <- result.try(
    deckplan.from_rows(reg, h.decks)
    |> result.map_error(fn(e) { "invalid_hull_plan:" <> e }),
  )
  use _ <- result.try(check_bounds(reg, base, fitted))
  use plan <- result.try(
    deckplan.from_rows(reg, stamp_all(reg, h.decks, fitted))
    |> result.map_error(fn(e) { "invalid_resolved_plan:" <> e }),
  )
  let mass = total_mass(h, fitted, mounted)
  use flight <- result.try(flight_of(mass, mounted))
  use class <- result.try(
    shipclass.from_plan(
      reg,
      h.id,
      h.name,
      h.schema,
      plan,
      h.fallback_capacity,
      h.handling,
      h.dock_port_orientation,
      h.dock_standoff,
      flight,
    )
    |> result.map_error(fn(e) { "invalid_resolved_plan:" <> e }),
  )
  Ok(Fit(loadout: lo, class: class, mass: mass))
}

// ------------------------------------------------------------- lookups --

fn lookup_modules(
  h: Hull,
  modules: Dict(String, Module),
  lo: Loadout,
) -> Result(List(#(Slot, Module)), String) {
  list.try_fold(lo.modules, [], fn(acc: List(#(Slot, Module)), entry) {
    let #(slot_id, module_id) = entry
    use slot <- result.try(
      hull.slot_by_id(h, slot_id)
      |> result.replace_error("slot_not_on_hull:" <> slot_id),
    )
    use <- guard(
      !list.any(acc, fn(a) { { a.0 }.id == slot_id }),
      "duplicate_slot:" <> slot_id,
    )
    use m <- result.try(
      dict.get(modules, module_id)
      |> result.replace_error("unknown_module:" <> module_id),
    )
    use <- guard(m.hull == h.id, "module_wrong_hull:" <> module_id)
    use <- guard(m.slot == slot_id, "module_wrong_slot:" <> module_id)
    Ok(list.append(acc, [#(slot, m)]))
  })
}

fn lookup_parts(
  h: Hull,
  parts: Dict(String, Part),
  lo: Loadout,
) -> Result(List(#(Mount, Part)), String) {
  list.try_fold(lo.parts, [], fn(acc: List(#(Mount, Part)), entry) {
    let #(mount_id, part_id) = entry
    use mount <- result.try(
      hull.mount_by_id(h, mount_id)
      |> result.replace_error("mount_not_on_hull:" <> mount_id),
    )
    use <- guard(
      !list.any(acc, fn(a) { { a.0 }.id == mount_id }),
      "duplicate_mount:" <> mount_id,
    )
    use p <- result.try(
      dict.get(parts, part_id)
      |> result.replace_error("unknown_part:" <> part_id),
    )
    use <- guard(p.kind == mount.kind, "mount_wrong_kind:" <> mount_id)
    use mount_rank <- result.try(
      part.size_rank(mount.size)
      |> result.replace_error("mount_bad_size:" <> mount_id),
    )
    use part_rank <- result.try(
      part.size_rank(p.size)
      |> result.replace_error("part_bad_size:" <> part_id),
    )
    use <- guard(part_rank <= mount_rank, "mount_too_small:" <> mount_id)
    Ok(list.append(acc, [#(mount, p)]))
  })
}

// ---------------------------------------------------------- validation --

/// The single loadout rule: for every tag, pooled `provides` across the hull,
/// its modules and its parts must cover pooled `requires`. Power is the
/// cross-cutting currency this expresses; `gun_control` (M5) is the same rule
/// linking a gun to any sufficient gun room, not to one specific partner.
fn check_tags(
  h: Hull,
  fitted: List(#(Slot, Module)),
  mounted: List(#(Mount, Part)),
) -> Result(Nil, String) {
  let provides =
    h.provides
    |> merge_all(list.map(fitted, fn(f) { { f.1 }.provides }))
    |> merge_all(list.map(mounted, fn(m) { { m.1 }.provides }))
  let requires =
    h.requires
    |> merge_all(list.map(fitted, fn(f) { { f.1 }.requires }))
    |> merge_all(list.map(mounted, fn(m) { { m.1 }.requires }))
  list.try_fold(dict.to_list(requires), Nil, fn(_, entry) {
    let #(tag, needed) = entry
    let supplied = case dict.get(provides, tag) {
      Ok(v) -> v
      Error(Nil) -> 0
    }
    case supplied >= needed {
      True -> Ok(Nil)
      False -> Error("tag_deficit:" <> tag)
    }
  })
}

fn merge_all(
  base: Dict(String, Int),
  others: List(Dict(String, Int)),
) -> Dict(String, Int) {
  list.fold(others, base, fn(acc, d) {
    list.fold(dict.to_list(d), acc, fn(acc, entry) {
      let #(tag, n) = entry
      let current = case dict.get(acc, tag) {
        Ok(v) -> v
        Error(Nil) -> 0
      }
      dict.insert(acc, tag, current + n)
    })
  })
}

/// Every non-void overlay cell must land on a hull cell carrying that slot's
/// digit — the cheap bounds check that stops a module scribbling on hull
/// structure. This reads the AUTHORED hull, never the previously resolved
/// plan, so a refit always validates against the same fixed structure.
fn check_bounds(
  reg: glyphs.Registry,
  base: DeckPlan,
  fitted: List(#(Slot, Module)),
) -> Result(Nil, String) {
  list.try_fold(fitted, Nil, fn(_, entry) {
    let #(slot, m) = entry
    list.try_fold(m.patches, Nil, fn(_, p) {
      case deckplan.deck_at(base, p.deck) {
        Error(Nil) -> Error("patch_bad_deck:" <> m.id)
        Ok(g) ->
          list.try_fold(patch_tiles(reg, p), Nil, fn(_, tile) {
            let #(tx, ty) = tile
            case deckplan.cell_at_xy(g, p.x + tx, p.y + ty) {
              Error(Nil) -> Error("out_of_slot_bounds:" <> m.id)
              Ok(cell) ->
                case cell.slot == Some(slot.digit) {
                  True -> Ok(Nil)
                  False -> Error("out_of_slot_bounds:" <> m.id)
                }
            }
          })
      }
    })
  })
}

/// The patch-local tile coordinates whose centre glyph is NOT void — the cells
/// that actually overwrite the hull.
fn patch_tiles(reg: glyphs.Registry, p: Patch) -> List(#(Int, Int)) {
  let cells = list.map(p.rows, string.to_graphemes)
  let width = case list.first(p.rows) {
    Ok(r) -> string.length(r) / 3
    Error(Nil) -> 0
  }
  let height = list.length(p.rows) / 3
  list.flat_map(range(0, height), fn(y) {
    list.filter_map(range(0, width), fn(x) {
      case is_void(reg, at(cells, 3 * y + 1, 3 * x + 1)) {
        True -> Error(Nil)
        False -> Ok(#(x, y))
      }
    })
  })
}

// --------------------------------------------------------------- stamp --

/// Stamp every fitted module's patches into the hull's rows, deck by deck.
fn stamp_all(
  reg: glyphs.Registry,
  decks: List(#(String, List(String))),
  fitted: List(#(Slot, Module)),
) -> List(#(String, List(String))) {
  list.index_map(decks, fn(deck, index) {
    let #(name, rows) = deck
    let patches =
      list.flat_map(fitted, fn(f) {
        list.filter({ f.1 }.patches, fn(p) { p.deck == index })
      })
    #(name, list.fold(patches, rows, fn(acc, p) { stamp(reg, acc, p) }))
  })
}

/// Splice one patch into a deck's rows. A patch tile whose centre glyph is
/// VOID leaves the hull's tile untouched (the passthrough rule); any other
/// tile overwrites the hull's 3x3 block — **except its SW corner**, which stays
/// the hull's because slot regions are hull-owned and a later refit has to
/// find them again.
fn stamp(reg: glyphs.Registry, rows: List(String), p: Patch) -> List(String) {
  let base = list.map(rows, string.to_graphemes)
  let patch = list.map(p.rows, string.to_graphemes)
  let stamped =
    list.fold(patch_tiles(reg, p), base, fn(acc, tile) {
      let #(px, py) = tile
      copy_tile(acc, patch, p.x + px, p.y + py, px, py)
    })
  list.map(stamped, string.concat)
}

/// Copy the eight non-SW characters of patch tile `(px, py)` onto base tile
/// `(tx, ty)`.
fn copy_tile(
  base: List(List(String)),
  patch: List(List(String)),
  tx: Int,
  ty: Int,
  px: Int,
  py: Int,
) -> List(List(String)) {
  list.fold(block_offsets(), base, fn(acc, off) {
    let #(dr, dc) = off
    set_at(acc, 3 * ty + dr, 3 * tx + dc, at(patch, 3 * py + dr, 3 * px + dc))
  })
}

/// The 3x3 block positions a stamp writes: everything but the SW corner
/// `#(2, 0)`, the hull's slot digit.
fn block_offsets() -> List(#(Int, Int)) {
  [#(0, 0), #(0, 1), #(0, 2), #(1, 0), #(1, 1), #(1, 2), #(2, 1), #(2, 2)]
}

fn is_void(reg: glyphs.Registry, ch: String) -> Bool {
  glyphs.center(reg, ch).tile == glyphs.Void
}

fn at(rows: List(List(String)), r: Int, c: Int) -> String {
  case list.drop(rows, r) |> list.first {
    Error(Nil) -> " "
    Ok(row) ->
      case list.drop(row, c) |> list.first {
        Error(Nil) -> " "
        Ok(ch) -> ch
      }
  }
}

fn set_at(
  rows: List(List(String)),
  r: Int,
  c: Int,
  value: String,
) -> List(List(String)) {
  list.index_map(rows, fn(row, ri) {
    case ri == r {
      False -> row
      True ->
        list.index_map(row, fn(ch, ci) {
          case ci == c {
            False -> ch
            True -> value
          }
        })
    }
  })
}

// ------------------------------------------------------------- numbers --

fn total_mass(
  h: Hull,
  fitted: List(#(Slot, Module)),
  mounted: List(#(Mount, Part)),
) -> Float {
  let modules = list.fold(fitted, 0.0, fn(t, f) { t +. { f.1 }.mass })
  let parts = list.fold(mounted, 0.0, fn(t, m) { t +. { m.1 }.mass })
  h.mass +. modules +. parts
}

/// Flight performance is the fitted engines' pooled thrust and torque over the
/// fit's total mass, so hull choice and every installed module change how she
/// flies. A hull that requires `{"engine": 1}` cannot resolve without one, so
/// a zero-thrust fit never reaches the sim.
fn flight_of(
  mass: Float,
  mounted: List(#(Mount, Part)),
) -> Result(shipclass.Flight, String) {
  case mass >. 0.0 {
    False -> Error("zero_mass")
    True -> {
      let thrust = list.fold(mounted, 0.0, fn(t, m) { t +. { m.1 }.thrust })
      let torque = list.fold(mounted, 0.0, fn(t, m) { t +. { m.1 }.torque })
      Ok(shipclass.Flight(accel: thrust /. mass, turn_rate: torque /. mass))
    }
  }
}

// -------------------------------------------------------------- helpers --

fn guard(
  condition: Bool,
  error: String,
  next: fn() -> Result(a, String),
) -> Result(a, String) {
  case condition {
    True -> next()
    False -> Error(error)
  }
}

/// [from, to) as a list of ints (the pinned gleam_stdlib has no `list.range`;
/// matches the local helper idiom used in `deckplan` and `composite`).
fn range(from: Int, to: Int) -> List(Int) {
  case from >= to {
    True -> []
    False -> [from, ..range(from + 1, to)]
  }
}
