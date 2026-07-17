//// Station markets: per-station commodity stores with Classic's noise-walk
//// dynamic prices (DynamicCommodityStore ported — see DESIGN.md "dynamic
//// prices ported from Classic"). Prices are a pure function of
//// (world seed, station, commodity, epoch): no state to persist, identical
//// on every node, testable without waiting. Stock is mutated by trades and
//// regenerates toward its authored initial level.

import dh_server/noise
import dh_server/world.{type World}
import gleam/float
import gleam/int
import gleam/list

/// Prices re-roll every 60 s of sim time.
pub const price_period_s = 60.0

/// Stock regenerates one step toward initial every 5 s of sim time.
pub const regen_period_s = 5.0

/// Price epochs per noise lattice step: higher = smoother drift.
const epochs_per_lattice = 4.0

pub type Store {
  Store(
    commodity: String,
    name: String,
    initial: Int,
    quantity: Int,
    base_price: Int,
    elasticity: Int,
    price: Int,
  )
}

pub type Market {
  Market(station_id: String, stores: List(Store))
}

/// One market per station (possibly with no stores), stocked at initial
/// levels and priced at epoch 0. Market entries referencing unknown
/// commodities were rejected at world load, so the lookup cannot fail on a
/// validated world.
pub fn init(world: World) -> List(Market) {
  list.map(world.stations, fn(station) {
    let stores =
      list.filter_map(station.market, fn(entry) {
        case list.find(world.commodities, fn(c) { c.id == entry.commodity }) {
          Error(Nil) -> Error(Nil)
          Ok(commodity) ->
            Ok(Store(
              commodity: entry.commodity,
              name: commodity.name,
              initial: entry.initial,
              quantity: entry.initial,
              base_price: entry.price,
              elasticity: entry.elasticity,
              price: price_at(
                world.seed,
                station.id,
                entry.commodity,
                entry.price,
                entry.elasticity,
                0,
              ),
            ))
        }
      })
    Market(station_id: station.id, stores: stores)
  })
}

pub fn price_epoch(t: Float) -> Int {
  float.round(float.floor(t /. price_period_s))
}

pub fn regen_epoch(t: Float) -> Int {
  float.round(float.floor(t /. regen_period_s))
}

/// The Classic price walk: base + noise * elasticity, floored at 1. The
/// noise stream is seeded per (world, station, commodity) so every store
/// walks independently but reproducibly.
pub fn price_at(
  seed: Int,
  station_id: String,
  commodity: String,
  base: Int,
  elasticity: Int,
  epoch: Int,
) -> Int {
  let stream = noise.seed_string(noise.seed_string(seed, station_id), commodity)
  let wiggle = noise.at(stream, int.to_float(epoch) /. epochs_per_lattice)
  int.max(1, base + float.round(wiggle *. int.to_float(elasticity)))
}

/// Re-roll every store's price for `epoch`.
pub fn reprice(market: Market, seed: Int, epoch: Int) -> Market {
  Market(
    ..market,
    stores: list.map(market.stores, fn(store) {
      Store(
        ..store,
        price: price_at(
          seed,
          market.station_id,
          store.commodity,
          store.base_price,
          store.elasticity,
          epoch,
        ),
      )
    }),
  )
}

/// Move each store's quantity one regen step (max(1, initial / 20)) toward
/// its initial level, from either direction.
pub fn regen(market: Market) -> Market {
  Market(
    ..market,
    stores: list.map(market.stores, fn(store) {
      let step = int.max(1, store.initial / 20)
      let delta =
        int.clamp(store.initial - store.quantity, min: -step, max: step)
      Store(..store, quantity: store.quantity + delta)
    }),
  )
}

pub fn find_store(market: Market, commodity: String) -> Result(Store, Nil) {
  list.find(market.stores, fn(s) { s.commodity == commodity })
}

/// Remove `quantity` units from a store, returning the updated market and
/// the store *as it was at sale time* (its `price` is the locked unit
/// price). `Error("not_sold_here")` for unknown commodities,
/// `Error("insufficient_stock")` when stock is short.
pub fn take_stock(
  market: Market,
  commodity: String,
  quantity: Int,
) -> Result(#(Market, Store), String) {
  case find_store(market, commodity) {
    Error(Nil) -> Error("not_sold_here")
    Ok(store) ->
      case store.quantity >= quantity {
        False -> Error("insufficient_stock")
        True ->
          Ok(#(
            replace_store(
              market,
              Store(..store, quantity: store.quantity - quantity),
            ),
            store,
          ))
      }
  }
}

/// Add `quantity` units to a store (deliveries from a selling ship).
/// Unknown commodities are ignored — sell offers were validated against
/// the store before any transfer started.
pub fn add_stock(market: Market, commodity: String, quantity: Int) -> Market {
  case find_store(market, commodity) {
    Error(Nil) -> market
    Ok(store) ->
      replace_store(market, Store(..store, quantity: store.quantity + quantity))
  }
}

fn replace_store(market: Market, updated: Store) -> Market {
  Market(
    ..market,
    stores: list.map(market.stores, fn(s) {
      case s.commodity == updated.commodity {
        True -> updated
        False -> s
      }
    }),
  )
}
