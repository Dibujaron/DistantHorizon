class_name SpaceData
extends RefCounted
## Typed view of the wire protocol's `space` message (M3.1 stitched
## interiors): the walkable plan a client should currently be simulating
## against, which is either a flying ship's interior ("ship:N") or a
## station's composite - concourse plus every docked ship grafted at a
## berth ("station:<id>"). `epoch` increments every time a station space
## is rebuilt (dock/undock/despawn); `walkers` messages carry the same
## tag so stale-frame updates can be dropped. `you_*` is our own
## character's position/seat in the new frame - prediction restarts from
## it, since plan changes move the coordinate frame under our feet.


## One grafted ship: ship-local tile (x,y) sits at composite tile
## (x + dx, y + dy).
class Graft:
	var ship_id: int
	var dx: int
	var dy: int

	static func from_dict(data: Dictionary) -> Graft:
		var graft := Graft.new()
		graft.ship_id = int(data.get("ship_id", -1))
		graft.dx = int(data.get("dx", 0))
		graft.dy = int(data.get("dy", 0))
		return graft


var id: String = ""
var epoch: int = 0
var plan: ShipClassData = null
var grafts: Array[Graft] = []
var you_x: float = 0.0
var you_y: float = 0.0
var you_seat: Variant = null  ## console id or null


static func from_dict(data: Dictionary) -> SpaceData:
	var space := SpaceData.new()
	space.id = str(data.get("space", ""))
	space.epoch = int(data.get("epoch", 0))
	var plan_doc: Variant = data.get("plan")
	if plan_doc is Dictionary:
		space.plan = ShipClassData.from_dict(plan_doc)
	for graft_data: Variant in data.get("grafts", []):
		if graft_data is Dictionary:
			space.grafts.append(Graft.from_dict(graft_data))
	var you: Variant = data.get("you")
	if you is Dictionary:
		space.you_x = float(you.get("x", 0.0))
		space.you_y = float(you.get("y", 0.0))
		space.you_seat = you.get("seat")
	return space


func is_station() -> bool:
	return id.begins_with("station:")


## The station id when this is a station space, "" otherwise.
func station_id() -> String:
	return id.trim_prefix("station:") if is_station() else ""
