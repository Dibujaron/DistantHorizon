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

/// Part ids name the manufacturer that BUILT the part. The Consol patch
/// engine is a Consolidated Orbital part fitted to a Rijay hull, and filing
/// it under `rijay.` erased the joke the starter Mockingbird is built on.
pub fn shipped_engine_parts_load_test() {
  let assert Ok(parts) = part.load_all("parts")
  let assert Ok(patch) = dict.get(parts, "consol.engine.co17f_2")
  assert patch.kind == "engine"
  assert patch.size == "m"
  assert patch.mass == 8.0
  let assert Ok(stork) = dict.get(parts, "rijay.engine.stork_240c2")
  assert stork.size == "m"
  assert stork.mass == 12.0
  // The Sparrow's engine, and the first size-`s` part on disk. Until now
  // every shipped part was `m`, so `mount size >= part size` had never once
  // been exercised by content.
  let assert Ok(wren) = dict.get(parts, "rijay.engine.wren_90b")
  assert wren.size == "s"
  assert wren.mass == 4.0
  assert dict.get(parts, "rijay.engine.stock") == Error(Nil)
  assert dict.get(parts, "rijay.engine.consol_patch") == Error(Nil)
}

/// Flight is EMERGENT, not authored: masses say what each thing is and the
/// engine says what it pushes with, so `accel = thrust / mass` falls out of
/// the loadout. Nothing here is back-solved from a target — 73.0 of hull,
/// 47.0 of default modules and three engines (12.0 + 8.0 + 12.0) give 152.0,
/// and 6500 N of pooled thrust over that is what she accelerates at.
/// (`mockingbird_test` owns the deck-fidelity half of the carve's promise.)
pub fn the_mockingbird_default_fit_flight_derives_from_its_masses_test() {
  let assert Ok(h) = hull.load("shipclasses/mockingbird.json")
  let assert Ok(mods) = module.load_all("modules")
  let assert Ok(parts) = part.load_all("parts")
  let assert Ok(fit) =
    loadout.resolve(glyphs.default(), h, mods, parts, loadout.default_for(h))
  assert fit.mass == 152.0
  assert near(fit.class.flight.accel, 42.76315789473684)
  assert near(fit.class.flight.turn_rate, 141.44736842105263)
  assert fit.class.cargo_capacity == 60
  assert fit.class.handling == shipclass.BreakBulk
}

/// Isolates the swap itself rather than the whole default fit: `parts` names
/// only `engine_center`, so `engine_port`/`engine_stbd` sit bare (mounting is
/// per-mount, never all-or-nothing) and the total is hull 73.0 + modules 47.0
/// + one 12.0 Stork = 132.0, against the 8.0 Consol's 128.0. Reactor draw
/// (4 against a 25-power hull with 14 already spoken for) stays nowhere near
/// the ceiling that `upgrading_the_centre_engine_overdraws_her_reactor_test`
/// hits with all three mounts filled, so this is purely about the mass an
/// engine's own choice trades, not about power.
pub fn the_stock_engine_trades_turn_for_thrust_test() {
  let assert Ok(h) = hull.load("shipclasses/mockingbird.json")
  let assert Ok(mods) = module.load_all("modules")
  let assert Ok(parts) = part.load_all("parts")
  let base = loadout.default_for(h)
  let swapped =
    loadout.Loadout(..base, parts: [
      #("engine_center", "rijay.engine.stork_240c2"),
    ])
  let assert Ok(fit) =
    loadout.resolve(glyphs.default(), h, mods, parts, swapped)
  // Heavier, but it pushes harder: quicker in a straight line, lazier to turn.
  assert near(fit.class.flight.accel, 18.1818)
  assert near(fit.class.flight.turn_rate, 53.0303)
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
  assert near(fit.class.flight.accel, 13.28125)
  assert near(fit.class.flight.turn_rate, 58.59375)
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
