class_name CargoState
extends RefCounted
## Typed view of a `cargo` message (M3): one ship's wallet, hold and
## running transfers. Sent at 15 Hz to the ship's crew wherever their
## bodies are, so the quartermaster ashore can watch the hold fill.

var ship_id: int = -1
var wallet: int = 0
var capacity: int = 0
var hold: Dictionary = {}  ## commodity id -> quantity
## Each entry: {"commodity": String, "direction": "to_ship"|"to_station",
## "remaining": int}
var transfers: Array[Dictionary] = []


static func from_dict(data: Dictionary) -> CargoState:
	var cargo := CargoState.new()
	cargo.ship_id = int(data.get("ship_id", -1))
	cargo.wallet = int(data.get("wallet", 0))
	cargo.capacity = int(data.get("capacity", 0))
	for entry: Variant in data.get("hold", []):
		if entry is Dictionary:
			cargo.hold[str(entry.get("commodity", ""))] = int(entry.get("quantity", 0))
	for transfer: Variant in data.get("transfers", []):
		if transfer is Dictionary:
			cargo.transfers.append({
				"commodity": str(transfer.get("commodity", "")),
				"direction": str(transfer.get("direction", "")),
				"remaining": int(transfer.get("remaining", 0)),
			})
	return cargo


func hold_quantity(commodity: String) -> int:
	return int(hold.get(commodity, 0))


func hold_total() -> int:
	var total := 0
	for quantity: Variant in hold.values():
		total += int(quantity)
	return total
