import dh_server/market
import dh_server/world
import gleam/list

fn range(start: Int, end: Int) -> List(Int) {
  case start >= end {
    True -> []
    False -> [start, ..range(start + 1, end)]
  }
}

fn load_world() -> world.World {
  let assert Ok(w) = world.load("worlds/m1_system.json")
  w
}

pub fn init_builds_one_market_per_station_at_initial_stock_test() {
  let w = load_world()
  let markets = market.init(w)
  assert list.length(markets) == 2
  let assert Ok(highport) =
    list.find(markets, fn(m) { m.station_id == "meridian_highport" })
  assert list.length(highport.stores) == 4
  let assert Ok(machinery) = market.find_store(highport, "machinery")
  assert machinery.quantity == 60
  assert machinery.initial == 60
  assert machinery.name == "Machinery"
  // Epoch-0 price is within the elasticity band and floored at 1.
  assert machinery.price >= 55 - 4 && machinery.price <= 55 + 4
}

pub fn price_at_is_deterministic_test() {
  assert market.price_at(20_260_712, "solis_ring", "machinery", 75, 6, 3)
    == market.price_at(20_260_712, "solis_ring", "machinery", 75, 6, 3)
}

pub fn price_at_varies_across_epochs_test() {
  let prices =
    list.map(range(0, 40), fn(epoch) {
      market.price_at(20_260_712, "solis_ring", "machinery", 75, 6, epoch)
    })
  assert list.unique(prices) |> list.length > 1
}

pub fn price_at_stays_in_band_and_floors_at_one_test() {
  list.each(range(0, 40), fn(epoch) {
    let p = market.price_at(1, "stn", "water", 2, 5, epoch)
    assert p >= 1
    // base 2, elasticity 5: raw walk can go to -3, price must floor at 1.
    assert p <= 7
  })
}

pub fn epochs_derive_from_sim_time_test() {
  assert market.price_epoch(0.0) == 0
  assert market.price_epoch(59.9) == 0
  assert market.price_epoch(60.0) == 1
  assert market.regen_epoch(4.9) == 0
  assert market.regen_epoch(5.0) == 1
}

pub fn take_stock_decrements_and_reports_errors_test() {
  let w = load_world()
  let assert Ok(m) =
    list.find(market.init(w), fn(m) { m.station_id == "meridian_highport" })
  let assert Ok(#(m2, store)) = market.take_stock(m, "machinery", 10)
  assert store.quantity == 60
  let assert Ok(after) = market.find_store(m2, "machinery")
  assert after.quantity == 50
  assert market.take_stock(m2, "machinery", 51) == Error("insufficient_stock")
  assert market.take_stock(m2, "unobtainium", 1) == Error("not_sold_here")
}

pub fn add_stock_increments_test() {
  let w = load_world()
  let assert Ok(m) =
    list.find(market.init(w), fn(m) { m.station_id == "solis_ring" })
  let m2 = market.add_stock(m, "machinery", 7)
  let assert Ok(store) = market.find_store(m2, "machinery")
  assert store.quantity == 37
}

pub fn regen_moves_quantity_toward_initial_from_both_sides_test() {
  let w = load_world()
  let assert Ok(m) =
    list.find(market.init(w), fn(m) { m.station_id == "meridian_highport" })
  // Deplete machinery (initial 60, step = max(1, 60/20) = 3).
  let assert Ok(#(depleted, _)) = market.take_stock(m, "machinery", 60)
  let assert Ok(s1) = market.find_store(market.regen(depleted), "machinery")
  assert s1.quantity == 3
  // Overstock: 60 + 30 regenerates downward by 3.
  let overstocked = market.add_stock(m, "machinery", 30)
  let assert Ok(s2) = market.find_store(market.regen(overstocked), "machinery")
  assert s2.quantity == 87
  // Already at initial: no movement.
  let assert Ok(s3) = market.find_store(market.regen(m), "machinery")
  assert s3.quantity == 60
}

pub fn reprice_updates_every_store_deterministically_test() {
  let w = load_world()
  let assert Ok(m) =
    list.find(market.init(w), fn(m) { m.station_id == "solis_ring" })
  let repriced = market.reprice(m, w.seed, 12)
  let assert Ok(store) = market.find_store(repriced, "machinery")
  assert store.price
    == market.price_at(w.seed, "solis_ring", "machinery", 75, 6, 12)
}
