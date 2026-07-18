import dh_server/character
import dh_server/composite
import dh_server/deckplan
import dh_server/market
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
  let assert Ok(c) = shipclass.load("classes/mockingbird.json")
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

pub fn board_and_disembark_are_no_longer_messages_test() {
  // M3.1 deleted the airlock-cycling crossing: these parse as unknown.
  assert protocol.parse_client_message(
      "{\"v\":1,\"type\":\"board\",\"ship_id\":7}",
    )
    == Error(Nil)
  assert protocol.parse_client_message("{\"v\":1,\"type\":\"disembark\"}")
    == Error(Nil)
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
  assert string.contains(text, "\"id\":\"mockingbird\"")
  assert string.contains(text, "\"spawn_tile\":[5,22]")
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
      dock: ship.Docked("meridian_highport", 0),
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

pub fn encode_walkers_test() {
  let char =
    character.Character(
      id: 4,
      name: "ada",
      ship_id: 1,
      place: character.OnStation("meridian_highport"),
      x: 2.5,
      y: 2.5,
      deck: deckplan.Lower,
      seat: Some("s1:helm_main"),
      move_dx: 0.0,
      move_dy: 0.0,
    )
  let text =
    protocol.encode_walkers(120, protocol.StationSpace("meridian_highport"), 3, [
      char,
    ])
  assert string.contains(text, "\"type\":\"walkers\"")
  assert string.contains(text, "\"space\":\"station:meridian_highport\"")
  assert string.contains(text, "\"epoch\":3")
  assert string.contains(text, "\"deck\":\"lower\"")
  assert string.contains(text, "\"seat\":\"s1:helm_main\"")
}

pub fn encode_space_test() {
  let plan =
    deckplan.DeckPlan(
      grid: deckplan.Grid(width: 3, height: 3),
      walkable: [".#.", "###", ".#."],
      rooms: [],
      consoles: [],
      spawn_tile: #(1, 1),
    )
  let you =
    character.Character(
      id: 4,
      name: "ada",
      ship_id: 1,
      place: character.OnStation("meridian_highport"),
      x: 2.5,
      y: 2.5,
      deck: deckplan.Upper,
      seat: None,
      move_dx: 0.0,
      move_dy: 0.0,
    )
  let text =
    protocol.encode_space(
      protocol.StationSpace("meridian_highport"),
      2,
      plan,
      [composite.Mooring(ship_id: 1, dx: 1, dy: 0)],
      Some(#(0, 4)),
      you,
    )
  assert string.contains(text, "\"type\":\"space\"")
  assert string.contains(text, "\"space\":\"station:meridian_highport\"")
  assert string.contains(
    text,
    "\"moorings\":[{\"ship_id\":1,\"dx\":1,\"dy\":0}]",
  )
  assert string.contains(text, "\"concourse\":{\"dx\":0,\"dy\":4}")
  assert string.contains(
    text,
    "\"you\":{\"x\":2.5,\"y\":2.5,\"deck\":\"upper\",\"seat\":null}",
  )
}

pub fn ship_space_id_test() {
  let text = protocol.encode_walkers(1, protocol.ShipSpace(3), 0, [])
  assert string.contains(text, "\"space\":\"ship:3\"")
}

pub fn parse_buy_and_sell_test() {
  assert protocol.parse_client_message(
      "{\"v\":1,\"type\":\"buy\",\"commodity\":\"machinery\",\"quantity\":5}",
    )
    == Ok(protocol.Buy(commodity: "machinery", quantity: 5))
  assert protocol.parse_client_message(
      "{\"v\":1,\"type\":\"sell\",\"commodity\":\"water\",\"quantity\":1}",
    )
    == Ok(protocol.Sell(commodity: "water", quantity: 1))
}

pub fn parse_buy_rejects_float_quantity_test() {
  // decode.int rejects floats — the inverse of the move/helm rule.
  let assert Error(Nil) =
    protocol.parse_client_message(
      "{\"v\":1,\"type\":\"buy\",\"commodity\":\"water\",\"quantity\":1.0}",
    )
}

pub fn parse_get_market_test() {
  assert protocol.parse_client_message("{\"v\":1,\"type\":\"get_market\"}")
    == Ok(protocol.GetMarket)
}

pub fn encode_trade_result_test() {
  let text =
    protocol.encode_trade_result(protocol.TradeResult(
      ok: False,
      reason: Some("insufficient_funds"),
      commodity: "machinery",
      quantity: 38,
      price: 0,
    ))
  assert text
    == "{\"v\":1,\"type\":\"trade_result\",\"ok\":false,\"reason\":\"insufficient_funds\",\"commodity\":\"machinery\",\"quantity\":38,\"price\":0}"
}

pub fn encode_market_test() {
  let m =
    market.Market(station_id: "solis_ring", stores: [
      market.Store(
        commodity: "machinery",
        name: "Machinery",
        initial: 30,
        quantity: 28,
        base_price: 75,
        elasticity: 6,
        price: 77,
      ),
    ])
  assert protocol.encode_market(m)
    == "{\"v\":1,\"type\":\"market\",\"station_id\":\"solis_ring\",\"stores\":[{\"commodity\":\"machinery\",\"name\":\"Machinery\",\"price\":77,\"quantity\":28}]}"
}

pub fn encode_cargo_sorts_hold_and_lists_transfers_test() {
  let assert Ok(w) = world.load("worlds/m1_system.json")
  let s = ship.spawn_docked(7, w, 0.0, 0)
  let s =
    ship.Ship(
      ..s,
      wallet: 1725,
      hold: dict.from_list([#("water", 3), #("machinery", 5)]),
      transfers: [
        ship.Transfer(
          commodity: "food",
          direction: ship.ToShip,
          remaining: 4,
          progress: 0.5,
          price_each: 10,
          rate: 1.0,
        ),
      ],
    )
  assert protocol.encode_cargo(s, 40)
    == "{\"v\":1,\"type\":\"cargo\",\"ship_id\":7,\"wallet\":1725,\"capacity\":40,\"hold\":[{\"commodity\":\"machinery\",\"quantity\":5},{\"commodity\":\"water\",\"quantity\":3}],\"transfers\":[{\"commodity\":\"food\",\"direction\":\"to_ship\",\"remaining\":4}]}"
}
