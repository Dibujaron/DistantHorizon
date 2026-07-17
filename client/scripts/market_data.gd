class_name MarketData
extends RefCounted
## Typed view of a `market` message (M3): one station's commodity stores
## with live prices and stock.


class Store:
	var commodity: String
	var name: String
	var price: int
	var quantity: int

	static func from_dict(data: Dictionary) -> Store:
		var store := Store.new()
		store.commodity = str(data.get("commodity", ""))
		store.name = str(data.get("name", store.commodity))
		store.price = int(data.get("price", 0))
		store.quantity = int(data.get("quantity", 0))
		return store


var station_id: String = ""
var stores: Array[Store] = []


static func from_dict(data: Dictionary) -> MarketData:
	var market := MarketData.new()
	market.station_id = str(data.get("station_id", ""))
	for store_data: Variant in data.get("stores", []):
		if store_data is Dictionary:
			market.stores.append(Store.from_dict(store_data))
	return market


func find_store(commodity: String) -> Store:
	for store in stores:
		if store.commodity == commodity:
			return store
	return null
