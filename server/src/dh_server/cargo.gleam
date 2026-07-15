//// Cargo handling: buy/sell validation and the timed physical transfer
//// (DESIGN.md "Cargo handling" — container cranes vs. robot stevedores).
//// Money and station stock settle at order time for buys; sells pay per
//// unit as it lands on the dock, at the price locked when the order was
//// placed. Everything here is pure functions over Ship — the sim owns the
//// station-market side of each exchange and applies `Delivery`s to it.

import dh_server/ship.{type Ship, Ship, ToShip, ToStation, Transfer}
import dh_server/shipclass.{type Handling, BreakBulk, Container}
import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option

/// Robot stevedores: work at any station, slowly. Units per second.
pub const robot_rate = 1.0

/// Container cranes: major-terminal infrastructure, fast. Units per second.
pub const crane_rate = 5.0

/// Which transfer method serves this ship at this station. Container hulls
/// never open their holds: no crane, no trade.
pub fn transfer_rate(crane: Bool, handling: Handling) -> Result(Float, String) {
  case handling, crane {
    BreakBulk, _ -> Ok(robot_rate)
    Container, True -> Ok(crane_rate)
    Container, False -> Error("no_crane")
  }
}

/// Units of `commodity` in the hold.
pub fn hold_quantity(s: Ship, commodity: String) -> Int {
  case dict.get(s.hold, commodity) {
    Ok(quantity) -> quantity
    Error(Nil) -> 0
  }
}

/// Total units in the hold.
pub fn hold_total(s: Ship) -> Int {
  dict.fold(s.hold, 0, fn(acc, _commodity, quantity) { acc + quantity })
}

/// Units already bought and still inbound — they have a reserved berth in
/// the hold, so capacity checks must count them.
pub fn incoming_total(s: Ship) -> Int {
  list.fold(s.transfers, 0, fn(acc, transfer) {
    case transfer.direction {
      ToShip -> acc + transfer.remaining
      ToStation -> acc
    }
  })
}

/// Start buying: wallet debited and the transfer queued now; units arrive
/// in the hold over time. The caller has already taken the stock from the
/// station store at `price_each`. Check order (quantity, hold, funds) is
/// part of the wire contract — tests depend on it.
pub fn begin_buy(
  s: Ship,
  commodity: String,
  quantity: Int,
  price_each: Int,
  capacity: Int,
  rate: Float,
) -> Result(Ship, String) {
  case quantity <= 0 {
    True -> Error("invalid_quantity")
    False ->
      case hold_total(s) + incoming_total(s) + quantity > capacity {
        True -> Error("insufficient_hold")
        False ->
          case price_each * quantity > s.wallet {
            True -> Error("insufficient_funds")
            False ->
              Ok(
                Ship(
                  ..s,
                  wallet: s.wallet - price_each * quantity,
                  transfers: list.append(s.transfers, [
                    Transfer(
                      commodity: commodity,
                      direction: ToShip,
                      remaining: quantity,
                      progress: 0.0,
                      price_each: price_each,
                      rate: rate,
                    ),
                  ]),
                ),
              )
          }
      }
  }
}

/// Start selling: units leave the hold now (staged on the ramp) and are
/// paid for, one by one, as they land on the dock.
pub fn begin_sell(
  s: Ship,
  commodity: String,
  quantity: Int,
  price_each: Int,
  rate: Float,
) -> Result(Ship, String) {
  case quantity <= 0 {
    True -> Error("invalid_quantity")
    False ->
      case hold_quantity(s, commodity) < quantity {
        True -> Error("insufficient_cargo")
        False ->
          Ok(
            Ship(
              ..s,
              hold: remove_from_hold(s.hold, commodity, quantity),
              transfers: list.append(s.transfers, [
                Transfer(
                  commodity: commodity,
                  direction: ToStation,
                  remaining: quantity,
                  progress: 0.0,
                  price_each: price_each,
                  rate: rate,
                ),
              ]),
            ),
          )
      }
  }
}

/// Units that finished moving ship -> station this tick, for the sim to
/// add to the station's store.
pub type Delivery {
  Delivery(commodity: String, quantity: Int)
}

/// Advance every transfer by one tick of `ship.dt`. Inbound units land in
/// the hold; outbound units credit the wallet at the locked price and are
/// reported as deliveries. Finished transfers are dropped.
pub fn step_transfers(s: Ship) -> #(Ship, List(Delivery)) {
  let #(stepped, kept, deliveries) =
    list.fold(s.transfers, #(s, [], []), fn(acc, transfer) {
      let #(current, kept, deliveries) = acc
      let progress = transfer.progress +. transfer.rate *. ship.dt
      let units = int.min(transfer.remaining, float.truncate(progress))
      let progress = progress -. int.to_float(units)
      let remaining = transfer.remaining - units
      let current = case transfer.direction, units {
        _, 0 -> current
        ToShip, _ ->
          Ship(
            ..current,
            hold: add_to_hold(current.hold, transfer.commodity, units),
          )
        ToStation, _ ->
          Ship(..current, wallet: current.wallet + units * transfer.price_each)
      }
      let deliveries = case transfer.direction, units {
        ToStation, u if u > 0 -> [
          Delivery(commodity: transfer.commodity, quantity: u),
          ..deliveries
        ]
        _, _ -> deliveries
      }
      let kept = case remaining {
        0 -> kept
        _ -> [
          Transfer(..transfer, remaining: remaining, progress: progress),
          ..kept
        ]
      }
      #(current, kept, deliveries)
    })
  #(Ship(..stepped, transfers: list.reverse(kept)), list.reverse(deliveries))
}

fn add_to_hold(
  hold: Dict(String, Int),
  commodity: String,
  units: Int,
) -> Dict(String, Int) {
  dict.upsert(hold, commodity, fn(existing) {
    case existing {
      option.Some(quantity) -> quantity + units
      option.None -> units
    }
  })
}

fn remove_from_hold(
  hold: Dict(String, Int),
  commodity: String,
  units: Int,
) -> Dict(String, Int) {
  let remaining = case dict.get(hold, commodity) {
    Ok(quantity) -> quantity - units
    Error(Nil) -> 0
  }
  case remaining <= 0 {
    True -> dict.delete(hold, commodity)
    False -> dict.insert(hold, commodity, remaining)
  }
}
