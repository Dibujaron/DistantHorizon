import dh_server/character
import dh_server/protocol
import dh_server/ship
import dh_server/shipclass
import dh_server/world
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string

fn test_class() -> shipclass.ShipClass {
  let assert Ok(c) = shipclass.load("classes/sparrow.json")
  c
}

pub fn parse_login_test() {
  assert protocol.parse_client_message(
      "{\"v\":1,\"type\":\"login\",\"username\":\"alice\",\"password\":\"secret\"}",
    )
    == Ok(protocol.Login(username: "alice", password: "secret"))
}

pub fn parse_helm_test() {
  assert protocol.parse_client_message(
      "{\"v\":1,\"type\":\"helm\",\"rotate\":0.5,\"thrust\":1.0}",
    )
    == Ok(protocol.Helm(rotate: 0.5, thrust: 1.0))
}

pub fn parse_helm_out_of_range_still_parses_test() {
  // Clamping is sim-side; the protocol layer must still accept and pass
  // through out-of-range values.
  assert protocol.parse_client_message(
      "{\"v\":1,\"type\":\"helm\",\"rotate\":5.0,\"thrust\":-3.0}",
    )
    == Ok(protocol.Helm(rotate: 5.0, thrust: -3.0))
}

pub fn parse_dock_test() {
  assert protocol.parse_client_message("{\"v\":1,\"type\":\"dock\"}")
    == Ok(protocol.Dock)
}

pub fn parse_undock_test() {
  assert protocol.parse_client_message("{\"v\":1,\"type\":\"undock\"}")
    == Ok(protocol.Undock)
}

pub fn parse_move_test() {
  assert protocol.parse_client_message(
      "{\"v\":1,\"type\":\"move\",\"dx\":0.5,\"dy\":-1.0}",
    )
    == Ok(protocol.Move(dx: 0.5, dy: -1.0))
}

pub fn parse_sit_test() {
  assert protocol.parse_client_message(
      "{\"v\":1,\"type\":\"sit\",\"console\":\"helm_main\"}",
    )
    == Ok(protocol.Sit(console: "helm_main"))
}

pub fn parse_stand_test() {
  assert protocol.parse_client_message("{\"v\":1,\"type\":\"stand\"}")
    == Ok(protocol.Stand)
}

pub fn parse_board_test() {
  assert protocol.parse_client_message(
      "{\"v\":1,\"type\":\"board\",\"ship_id\":7}",
    )
    == Ok(protocol.Board(ship_id: 7))
}

pub fn parse_get_stats_test() {
  assert protocol.parse_client_message("{\"v\":1,\"type\":\"get_stats\"}")
    == Ok(protocol.GetStats)
}

pub fn parse_wrong_version_test() {
  assert protocol.parse_client_message(
      "{\"v\":2,\"type\":\"login\",\"username\":\"a\",\"password\":\"b\"}",
    )
    == Error(Nil)
  assert protocol.parse_client_message(
      "{\"v\":2,\"type\":\"helm\",\"rotate\":0.0,\"thrust\":0.0}",
    )
    == Error(Nil)
}

pub fn parse_garbage_test() {
  assert protocol.parse_client_message("not json") == Error(Nil)
  assert protocol.parse_client_message("{\"v\":1,\"type\":\"warp_drive\"}")
    == Error(Nil)
  assert protocol.parse_client_message("{\"v\":1,\"type\":\"login\"}")
    == Error(Nil)
}

pub fn encode_welcome_contains_world_name_and_stations_test() {
  let assert Ok(w) = world.load("worlds/m1_system.json")
  let text = protocol.encode_welcome(0, 1, 1, w, test_class())
  assert string.contains(text, "\"type\":\"welcome\"")
  assert string.contains(text, "\"account_id\":0")
  assert string.contains(text, "\"ship_id\":1")
  assert string.contains(text, "Krasny Sector (M1 pinned system)")
  assert string.contains(text, "meridian_highport")
  assert string.contains(text, "solis_ring")
}

pub fn encode_welcome_contains_character_id_and_ship_class_test() {
  let assert Ok(w) = world.load("worlds/m1_system.json")
  let text = protocol.encode_welcome(0, 1, 42, w, test_class())
  assert string.contains(text, "\"character_id\":42")
  assert string.contains(text, "\"ship_class\":")
  assert string.contains(text, "\"id\":\"sparrow\"")
  assert string.contains(text, "\"spawn_tile\":[5,4]")
  assert string.contains(text, "\"consoles\":")
  assert string.contains(text, "helm_main")
}

pub fn encode_error_test() {
  let text = protocol.encode_error("auth_failed", "bad credentials")
  assert string.contains(text, "\"type\":\"error\"")
  assert string.contains(text, "\"code\":\"auth_failed\"")
  assert string.contains(text, "\"message\":\"bad credentials\"")
}

pub fn encode_dock_result_ok_test() {
  let text = protocol.encode_dock_result(Ok(Nil))
  assert string.contains(text, "\"type\":\"dock_result\"")
  assert string.contains(text, "\"ok\":true")
  assert string.contains(text, "\"reason\":null")
}

pub fn encode_dock_result_error_test() {
  let text = protocol.encode_dock_result(Error("out_of_range"))
  assert string.contains(text, "\"ok\":false")
  assert string.contains(text, "\"reason\":\"out_of_range\"")
}

type DecodedShip {
  DecodedShip(
    id: Int,
    x: Float,
    y: Float,
    vx: Float,
    vy: Float,
    heading: Float,
    thrust: Float,
    docked: option.Option(String),
  )
}

fn decoded_ship_decoder() -> decode.Decoder(DecodedShip) {
  use id <- decode.field("id", decode.int)
  use x <- decode.field("x", decode.float)
  use y <- decode.field("y", decode.float)
  use vx <- decode.field("vx", decode.float)
  use vy <- decode.field("vy", decode.float)
  use heading <- decode.field("heading", decode.float)
  use thrust <- decode.field("thrust", decode.float)
  use docked <- decode.field("docked", decode.optional(decode.string))
  decode.success(DecodedShip(
    id: id,
    x: x,
    y: y,
    vx: vx,
    vy: vy,
    heading: heading,
    thrust: thrust,
    docked: docked,
  ))
}

fn snapshot_decoder() -> decode.Decoder(List(DecodedShip)) {
  decode.field("ships", decode.list(decoded_ship_decoder()), decode.success)
}

pub fn encode_snapshot_round_trip_test() {
  let flying =
    ship.Ship(
      id: 1,
      x: 10.0,
      y: 20.0,
      vx: 1.0,
      vy: 2.0,
      heading: 0.5,
      controls: ship.Controls(rotate: 0.0, thrust: 0.75),
      dock: ship.Flying,
      wallet: ship.starting_wallet,
      hold: dict.new(),
      transfers: [],
    )
  let docked =
    ship.Ship(
      id: 2,
      x: 400.0,
      y: 0.0,
      vx: 0.0,
      vy: 13.9,
      heading: 0.0,
      controls: ship.Controls(rotate: 0.0, thrust: 0.0),
      dock: ship.Docked("meridian_highport"),
      wallet: ship.starting_wallet,
      hold: dict.new(),
      transfers: [],
    )

  let text = protocol.encode_snapshot(42, [flying, docked])
  assert string.contains(text, "\"tick\":42")

  let assert Ok(ships) = json.parse(text, snapshot_decoder())
  let assert Ok(decoded_flying) = list.find(ships, fn(s) { s.id == 1 })
  let assert Ok(decoded_docked) = list.find(ships, fn(s) { s.id == 2 })

  assert decoded_flying.x == 10.0
  assert decoded_flying.y == 20.0
  assert decoded_flying.heading == 0.5
  assert decoded_flying.thrust == 0.75
  assert decoded_flying.docked == None

  assert decoded_docked.vy == 13.9
  assert decoded_docked.docked == Some("meridian_highport")
}

pub fn encode_seat_result_ok_test() {
  let text =
    protocol.encode_seat_result(protocol.SeatResult(
      ok: True,
      reason: None,
      seat: Some("helm_main"),
    ))
  assert string.contains(text, "\"type\":\"seat_result\"")
  assert string.contains(text, "\"ok\":true")
  assert string.contains(text, "\"reason\":null")
  assert string.contains(text, "\"seat\":\"helm_main\"")
}

pub fn encode_seat_result_error_test() {
  let text =
    protocol.encode_seat_result(protocol.SeatResult(
      ok: False,
      reason: Some("too_far"),
      seat: None,
    ))
  assert string.contains(text, "\"ok\":false")
  assert string.contains(text, "\"reason\":\"too_far\"")
  assert string.contains(text, "\"seat\":null")
}

pub fn encode_board_result_ok_test() {
  let text =
    protocol.encode_board_result(protocol.BoardResult(
      ok: True,
      reason: None,
      ship_id: 2,
    ))
  assert string.contains(text, "\"type\":\"board_result\"")
  assert string.contains(text, "\"ok\":true")
  assert string.contains(text, "\"reason\":null")
  assert string.contains(text, "\"ship_id\":2")
}

pub fn encode_board_result_error_test() {
  let text =
    protocol.encode_board_result(protocol.BoardResult(
      ok: False,
      reason: Some("not_docked_together"),
      ship_id: 1,
    ))
  assert string.contains(text, "\"ok\":false")
  assert string.contains(text, "\"reason\":\"not_docked_together\"")
}

type DecodedCharacter {
  DecodedCharacter(
    id: Int,
    name: String,
    x: Float,
    y: Float,
    seat: option.Option(String),
  )
}

fn decoded_character_decoder() -> decode.Decoder(DecodedCharacter) {
  use id <- decode.field("id", decode.int)
  use name <- decode.field("name", decode.string)
  use x <- decode.field("x", decode.float)
  use y <- decode.field("y", decode.float)
  use seat <- decode.field("seat", decode.optional(decode.string))
  decode.success(DecodedCharacter(id: id, name: name, x: x, y: y, seat: seat))
}

fn interior_decoder() -> decode.Decoder(#(Int, Int, List(DecodedCharacter))) {
  use tick <- decode.field("tick", decode.int)
  use ship_id <- decode.field("ship_id", decode.int)
  use characters <- decode.field(
    "characters",
    decode.list(decoded_character_decoder()),
  )
  decode.success(#(tick, ship_id, characters))
}

pub fn encode_interior_round_trip_test() {
  let class = test_class()
  let pilot = character.spawn_seated_at_helm(1, "ada", 9, class.plan)
  let walker = character.spawn_at_spawn_tile(2, "grace", 9, class.plan)
  let text = protocol.encode_interior(90, 9, [pilot, walker])
  assert string.contains(text, "\"type\":\"interior\"")
  assert string.contains(text, "\"tick\":90")
  assert string.contains(text, "\"ship_id\":9")

  let assert Ok(#(tick, ship_id, characters)) =
    json.parse(text, interior_decoder())
  assert tick == 90
  assert ship_id == 9
  let assert Ok(decoded_pilot) = list.find(characters, fn(c) { c.id == 1 })
  let assert Ok(decoded_walker) = list.find(characters, fn(c) { c.id == 2 })
  assert decoded_pilot.name == "ada"
  assert decoded_pilot.seat == Some("helm_main")
  assert decoded_walker.name == "grace"
  assert decoded_walker.seat == None
  assert decoded_walker.x == walker.x
  assert decoded_walker.y == walker.y
}
