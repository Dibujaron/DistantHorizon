class_name ShipState
extends RefCounted
## One ship's entry in a `snapshot` message, parsed off the wire in
## network_client.gd so the rest of the client never touches raw JSON.

var id: int
var x: float
var y: float
var vx: float
var vy: float
var heading: float  ## radians, y-up counter-clockwise (wire convention)
var docked_at: String  ## station id, or "" while flying free


static func from_dict(data: Dictionary) -> ShipState:
	var ship := ShipState.new()
	ship.id = int(data.get("id", -1))
	ship.x = float(data.get("x", 0.0))
	ship.y = float(data.get("y", 0.0))
	ship.vx = float(data.get("vx", 0.0))
	ship.vy = float(data.get("vy", 0.0))
	ship.heading = float(data.get("heading", 0.0))
	var docked: Variant = data.get("docked")
	ship.docked_at = "" if docked == null else str(docked)
	return ship


func position() -> Vector2:
	return Vector2(x, y)


func velocity() -> Vector2:
	return Vector2(vx, vy)


func is_docked() -> bool:
	return docked_at != ""


## Copy with the position advanced `elapsed` seconds along the current
## velocity (dead reckoning between snapshots); everything else unchanged.
func extrapolated(elapsed: float) -> ShipState:
	var out := ShipState.new()
	out.id = id
	out.x = x + vx * elapsed
	out.y = y + vy * elapsed
	out.vx = vx
	out.vy = vy
	out.heading = heading
	out.docked_at = docked_at
	return out
