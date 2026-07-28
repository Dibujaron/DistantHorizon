import dh_server/glyphs
import dh_server/hull
import dh_server/loadout
import dh_server/module
import dh_server/part
import dh_server/shipclass
import gleam/dict
import gleam/float

/// Flight stats are quotients, so compare them with a tolerance rather than
/// float equality — `7000.0 /. 132.0` has no exact binary representation.
fn near(actual: Float, expected: Float) -> Bool {
  float.loosely_equals(actual, expected, tolerating: 0.001)
}

pub fn shipped_parts_load_test() {
  let assert Ok(parts) = part.load_all("parts")
  let assert Ok(patch) = dict.get(parts, "rijay.engine.consol_patch")
  assert patch.kind == "engine"
  assert patch.size == "m"
  let assert Ok(stock) = dict.get(parts, "rijay.engine.stock")
  assert stock.thrust >. patch.thrust
  assert stock.torque <. patch.torque
}

/// Flight is EMERGENT, not authored: masses say what each thing is and the
/// engine says what it pushes with, so `accel = thrust / mass` falls out of
/// the loadout. Nothing here is back-solved from a target — 73.0 of hull,
/// 47.0 of default modules and an 8.0 Consol patch give 128.0, and 5000 N of
/// thrust over that is what she accelerates at. Swapping to the heavier Rijay
/// original moves the total to 132.0, which is exactly why an engine's mass
/// has to be real: it is one of the things the swap trades.
/// (`mockingbird_test` owns the deck-fidelity half of the carve's promise.)
pub fn the_mockingbird_default_fit_flight_derives_from_its_masses_test() {
  let assert Ok(h) = hull.load("shipclasses/mockingbird.json")
  let assert Ok(mods) = module.load_all("modules")
  let assert Ok(parts) = part.load_all("parts")
  let assert Ok(fit) =
    loadout.resolve(glyphs.default(), h, mods, parts, loadout.default_for(h))
  assert fit.mass == 128.0
  assert near(fit.class.flight.accel, 39.0625)
  assert near(fit.class.flight.turn_rate, 171.875)
  assert fit.class.cargo_capacity == 60
  assert fit.class.handling == shipclass.BreakBulk
}

pub fn the_stock_engine_trades_turn_for_thrust_test() {
  let assert Ok(h) = hull.load("shipclasses/mockingbird.json")
  let assert Ok(mods) = module.load_all("modules")
  let assert Ok(parts) = part.load_all("parts")
  let base = loadout.default_for(h)
  let swapped =
    loadout.Loadout(..base, parts: [#("engine_center", "rijay.engine.stock")])
  let assert Ok(fit) =
    loadout.resolve(glyphs.default(), h, mods, parts, swapped)
  // Heavier, but it pushes harder: quicker in a straight line, lazier to turn.
  assert near(fit.class.flight.accel, 53.0303)
  assert near(fit.class.flight.turn_rate, 151.5152)
}

/// Every pytest harness test spawns from the fixture hull, and
/// `harness/test_m1_flight.py` measures distance travelled under thrust, so
/// its bounds are downstream of this number. The fixture's metadata is
/// hand-written rather than derived, so a typo there would surface only as a
/// mystifying harness failure. Pin it here, where the cause is obvious.
pub fn the_harness_fixture_hull_flight_is_pinned_test() {
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
  assert near(fit.class.flight.accel, 39.0625)
  assert near(fit.class.flight.turn_rate, 171.875)
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

/// `mass`, `thrust` and `torque` are JSON `number`s, and a hand-authored part
/// is as likely to spell a round figure `4` as `4.0`. Draft-06 cannot express
/// "float-spelled only" (`4.0` is an integer to a validator), so the decoder
/// takes either rather than the schema pretending to forbid one
/// (`hull.number_decoder`).
pub fn bare_integer_numbers_decode_test() {
  let assert Ok(p) =
    part.decode(
      "{ \"schema\": 1, \"id\": \"test.round\", \"name\": \"R\",
         \"kind\": \"engine\", \"size\": \"m\", \"mass\": 24,
         \"thrust\": 4800, \"torque\": 21600 }",
    )
  assert p.mass == 24.0
  assert p.thrust == 4800.0
  assert p.torque == 21_600.0
}
