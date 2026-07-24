import dh_server/glyphs
import dh_server/hull
import dh_server/loadout
import dh_server/part
import dh_server/shipclass
import gleam/dict

pub fn shipped_parts_load_test() {
  let assert Ok(parts) = part.load_all("parts")
  let assert Ok(patch) = dict.get(parts, "rijay.engine.consol_patch")
  assert patch.kind == "engine"
  assert patch.size == "m"
  let assert Ok(stock) = dict.get(parts, "rijay.engine.stock")
  assert stock.thrust >. patch.thrust
  assert stock.torque <. patch.torque
}

/// The uncarved Mockingbird resolves with an engine and no modules at all —
/// the "a hull with no slots is legal" case — at exactly the pre-M4 constants.
pub fn uncarved_mockingbird_flies_at_the_pre_m4_constants_test() {
  let assert Ok(h) = hull.load("shipclasses/mockingbird.json")
  let assert Ok(parts) = part.load_all("parts")
  let assert Ok(fit) =
    loadout.resolve(
      glyphs.default(),
      h,
      dict.new(),
      parts,
      loadout.default_for(h),
    )
  assert fit.mass == 120.0
  assert fit.class.flight.accel == 40.0
  assert fit.class.flight.turn_rate == 180.0
  assert fit.class.cargo_capacity == 60
  assert fit.class.handling == shipclass.BreakBulk
}

pub fn the_stock_engine_trades_turn_for_thrust_test() {
  let assert Ok(h) = hull.load("shipclasses/mockingbird.json")
  let assert Ok(parts) = part.load_all("parts")
  let swapped =
    loadout.Loadout(hull: "mockingbird", modules: [], parts: [
      #("engine_center", "rijay.engine.stock"),
    ])
  let assert Ok(fit) =
    loadout.resolve(glyphs.default(), h, dict.new(), parts, swapped)
  assert fit.class.flight.accel == 55.0
  assert fit.class.flight.turn_rate == 160.0
}

/// Every pytest harness test spawns from the fixture hull, and
/// `harness/test_m1_flight.py` asserts "~20 u for ~1 s of full thrust" — which
/// is 40 u/s^2. Its metadata is hand-written rather than derived, so a typo
/// there would only surface as a mystifying harness failure once the sim
/// resolves fits. Pin it here, where the cause is obvious.
pub fn the_harness_fixture_hull_flies_at_the_pre_m4_constants_test() {
  let assert Ok(h) = hull.load("../harness/fixtures/test_fixture.json")
  let assert Ok(parts) = part.load_all("parts")
  let assert Ok(fit) =
    loadout.resolve(
      glyphs.default(),
      h,
      dict.new(),
      parts,
      loadout.default_for(h),
    )
  assert fit.class.flight.accel == 40.0
  assert fit.class.flight.turn_rate == 180.0
}

/// A hull that requires `{"engine": 1}` cannot resolve with nothing mounted —
/// this is the pooled-tag rule doing the "she has to be able to move" job, not
/// a special case in the engine.
pub fn no_engine_is_refused_test() {
  let assert Ok(h) = hull.load("shipclasses/mockingbird.json")
  let bare = loadout.Loadout(hull: "mockingbird", modules: [], parts: [])
  let assert Error(e) =
    loadout.resolve(glyphs.default(), h, dict.new(), dict.new(), bare)
  assert e == "tag_deficit:engine"
}
