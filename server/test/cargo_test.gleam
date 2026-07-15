import dh_server/cargo
import dh_server/ship
import dh_server/shipclass
import gleam/dict
import gleam/list

fn range(start: Int, end: Int) -> List(Int) {
  case start >= end {
    True -> []
    False -> [start, ..range(start + 1, end)]
  }
}

fn test_ship() -> ship.Ship {
  ship.Ship(
    id: 1,
    x: 0.0,
    y: 0.0,
    vx: 0.0,
    vy: 0.0,
    heading: 0.0,
    controls: ship.Controls(rotate: 0.0, thrust: 0.0),
    dock: ship.Docked("meridian_highport"),
    wallet: 2000,
    hold: dict.new(),
    transfers: [],
  )
}

pub fn transfer_rate_matrix_test() {
  assert cargo.transfer_rate(False, shipclass.BreakBulk) == Ok(cargo.robot_rate)
  assert cargo.transfer_rate(True, shipclass.BreakBulk) == Ok(cargo.robot_rate)
  assert cargo.transfer_rate(True, shipclass.Container) == Ok(cargo.crane_rate)
  assert cargo.transfer_rate(False, shipclass.Container) == Error("no_crane")
}

pub fn begin_buy_debits_wallet_and_queues_transfer_test() {
  let assert Ok(s) = cargo.begin_buy(test_ship(), "machinery", 5, 55, 40, 1.0)
  assert s.wallet == 2000 - 275
  let assert [transfer] = s.transfers
  assert transfer.commodity == "machinery"
  assert transfer.direction == ship.ToShip
  assert transfer.remaining == 5
  assert transfer.price_each == 55
  // Nothing in the hold until the robots carry it aboard.
  assert cargo.hold_total(s) == 0
  assert cargo.incoming_total(s) == 5
}

pub fn begin_buy_check_order_is_quantity_hold_funds_test() {
  assert cargo.begin_buy(test_ship(), "machinery", 0, 55, 40, 1.0)
    == Error("invalid_quantity")
  assert cargo.begin_buy(test_ship(), "machinery", -3, 55, 40, 1.0)
    == Error("invalid_quantity")
  // 45 > capacity 40 (cost 2475 would also fail funds — hold wins).
  assert cargo.begin_buy(test_ship(), "machinery", 45, 55, 40, 1.0)
    == Error("insufficient_hold")
  // 38 fits the hold but costs 2090 > 2000.
  assert cargo.begin_buy(test_ship(), "machinery", 38, 55, 40, 1.0)
    == Error("insufficient_funds")
}

pub fn begin_buy_counts_hold_and_inbound_against_capacity_test() {
  let with_cargo =
    ship.Ship(..test_ship(), hold: dict.from_list([#("water", 20)]))
  let assert Ok(s) = cargo.begin_buy(with_cargo, "food", 10, 10, 40, 1.0)
  // 20 held + 10 inbound: another 11 must not fit in a 40-unit hold.
  assert cargo.begin_buy(s, "water", 11, 4, 40, 1.0)
    == Error("insufficient_hold")
  let assert Ok(_) = cargo.begin_buy(s, "water", 10, 4, 40, 1.0)
}

pub fn begin_sell_stages_cargo_out_of_the_hold_test() {
  let with_cargo =
    ship.Ship(..test_ship(), hold: dict.from_list([#("machinery", 8)]))
  let assert Ok(s) = cargo.begin_sell(with_cargo, "machinery", 5, 70, 1.0)
  assert cargo.hold_quantity(s, "machinery") == 3
  // Wallet is credited on delivery, not at order time.
  assert s.wallet == 2000
  let assert [transfer] = s.transfers
  assert transfer.direction == ship.ToStation
  assert transfer.remaining == 5
  assert cargo.begin_sell(s, "machinery", 4, 70, 1.0)
    == Error("insufficient_cargo")
  assert cargo.begin_sell(s, "machinery", 0, 70, 1.0)
    == Error("invalid_quantity")
}

pub fn step_transfers_moves_whole_units_at_rate_test() {
  let assert Ok(s) = cargo.begin_buy(test_ship(), "machinery", 2, 55, 40, 1.0)
  // rate 1.0 u/s at 60 Hz: one unit lands on the 60th tick.
  let after_59 = step_times(s, 59)
  assert cargo.hold_quantity(after_59, "machinery") == 0
  let after_60 = step_times(s, 60)
  assert cargo.hold_quantity(after_60, "machinery") == 1
  // Transfer completes and is dropped after 2 s.
  let done = step_times(s, 121)
  assert cargo.hold_quantity(done, "machinery") == 2
  assert done.transfers == []
}

pub fn step_transfers_credits_sales_per_unit_and_reports_deliveries_test() {
  let with_cargo =
    ship.Ship(..test_ship(), hold: dict.from_list([#("machinery", 2)]))
  let assert Ok(s) = cargo.begin_sell(with_cargo, "machinery", 2, 70, 1.0)
  let #(after_60, deliveries) = step_collecting(s, 60)
  assert after_60.wallet == 2000 + 70
  assert deliveries == [cargo.Delivery(commodity: "machinery", quantity: 1)]
  let #(done, all_deliveries) = step_collecting(s, 121)
  assert done.wallet == 2000 + 140
  assert done.transfers == []
  assert list.length(all_deliveries) == 2
}

fn step_times(s: ship.Ship, times: Int) -> ship.Ship {
  case times {
    0 -> s
    _ -> {
      let #(next, _) = cargo.step_transfers(s)
      step_times(next, times - 1)
    }
  }
}

/// Step `times` ticks, concatenating every tick's deliveries.
fn step_collecting(
  s: ship.Ship,
  times: Int,
) -> #(ship.Ship, List(cargo.Delivery)) {
  list.fold(range(1, times + 1), #(s, []), fn(acc, _) {
    let #(current, deliveries) = acc
    let #(next, new_deliveries) = cargo.step_transfers(current)
    #(next, list.append(deliveries, new_deliveries))
  })
}
