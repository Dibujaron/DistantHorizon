class_name CharacterState
extends RefCounted
## One character's entry in an `interior` message, parsed off the wire in
## network_client.gd. Mirrors ship_state.gd's shape, but not its rendering
## role: unlike ships, characters are never velocity-extrapolated (the wire
## only carries position, and walkers start/stop instantly, so
## extrapolating a stale velocity overshoots on every stop or turn -- the
## snap-back bug). main.gd instead renders the own character from local
## prediction and every other character from delayed interpolation between
## buffered `interior` messages (see main.gd's _interior_history and
## _interpolated_other_position).

var id: int
var name: String
var x: float
var y: float
var seat: String  ## console id, or "" while standing


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
