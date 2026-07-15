class_name CharacterState
extends RefCounted
## One character's entry in an `interior` message, parsed off the wire in
## network_client.gd. Mirrors ship_state.gd's shape and role, with one
## difference: the wire only carries position (no velocity, unlike ships),
## so main.gd estimates vx/vy itself by diffing consecutive `interior`
## snapshots before handing characters to InteriorView, then calls
## extrapolated() the same way it dead-reckons ships between snapshots.

var id: int
var name: String
var x: float
var y: float
var seat: String  ## console id, or "" while standing
var vx: float = 0.0  ## client-estimated, not on the wire
var vy: float = 0.0  ## client-estimated, not on the wire


static func from_dict(data: Dictionary) -> CharacterState:
	var character := CharacterState.new()
	character.id = int(data.get("id", -1))
	character.name = str(data.get("name", ""))
	character.x = float(data.get("x", 0.0))
	character.y = float(data.get("y", 0.0))
	var seat_value: Variant = data.get("seat")
	character.seat = "" if seat_value == null else str(seat_value)
	return character


func position() -> Vector2:
	return Vector2(x, y)


func is_seated() -> bool:
	return seat != ""


## Copy with the position advanced `elapsed` seconds along the (client-
## estimated) velocity; everything else unchanged. Mirrors
## ShipState.extrapolated.
func extrapolated(elapsed: float) -> CharacterState:
	var out := CharacterState.new()
	out.id = id
	out.name = name
	out.x = x + vx * elapsed
	out.y = y + vy * elapsed
	out.vx = vx
	out.vy = vy
	out.seat = seat
	return out
