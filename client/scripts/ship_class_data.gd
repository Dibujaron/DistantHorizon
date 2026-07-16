class_name ShipClassData
extends RefCounted
## Typed view of the wire protocol's ship class doc (M2 spec, "Ship class
## doc"), parsed once at welcome (network_client.gd) so the interior
## renderer and input logic never touch raw JSON.
##
## Interior coordinates are tile units, ship-local, y-down; tile (x,y) spans
## [x, x+1) x [y, y+1), center (x+0.5, y+0.5) -- matches the server exactly.


## A labeled rectangular area of the deck plan (rendering/labels only; no
## door graph in M2).
class Room:
	var id: String
	var name: String
	var x: int
	var y: int
	var w: int
	var h: int

	static func from_dict(data: Dictionary) -> Room:
		var room := Room.new()
		room.id = str(data.get("id", ""))
		room.name = str(data.get("name", room.id))
		room.x = int(data.get("x", 0))
		room.y = int(data.get("y", 0))
		room.w = int(data.get("w", 0))
		room.h = int(data.get("h", 0))
		return room

	func contains_tile(tx: int, ty: int) -> bool:
		return tx >= x and tx < x + w and ty >= y and ty < y + h


## A console tile. `kind` "helm" binds flight controls while seated there;
## "cargo" opens the read-only manifest (M3); "broker" consoles exist on
## station concourses and bind trading.
class Console:
	var id: String
	var kind: String
	var x: int
	var y: int

	static func from_dict(data: Dictionary) -> Console:
		var console := Console.new()
		console.id = str(data.get("id", ""))
		console.kind = str(data.get("kind", ""))
		console.x = int(data.get("x", 0))
		console.y = int(data.get("y", 0))
		return console

	## Center of the console's tile, tile units -- matches the server's sit-
	## range and seat-snap math.
	func tile_center() -> Vector2:
		return Vector2(x + 0.5, y + 0.5)


## Walk speed, tiles/s -- mirrors `walk_speed` in
## server/src/dh_server/character.gleam exactly (client-side prediction of
## the own character must match the server's math bit-for-bit or the
## reconciliation drift becomes visible).
const WALK_SPEED := 3.0

## Character collision radius, tiles -- mirrors `radius` in character.gleam.
const CHARACTER_RADIUS := 0.3

var schema: int = 1
var id: String = ""
var name: String = ""
var grid_width: int = 0
var grid_height: int = 0
var walkable: Array[String] = []  ## one row string per y, '#' walkable, '.' hull/void
var rooms: Array[Room] = []
var consoles: Array[Console] = []
var spawn_tile: Vector2i = Vector2i.ZERO
## M3 cargo block (ship class schema 2). Concourse plans parsed through
## this class leave them at 0/"" — a concourse has no hold.
var cargo_capacity: int = 0
var handling: String = ""


static func from_dict(data: Dictionary) -> ShipClassData:
	var doc := ShipClassData.new()
	doc.schema = int(data.get("schema", 1))
	doc.id = str(data.get("id", ""))
	doc.name = str(data.get("name", doc.id))
	var grid: Variant = data.get("grid")
	if grid is Dictionary:
		doc.grid_width = int(grid.get("width", 0))
		doc.grid_height = int(grid.get("height", 0))
	for row: Variant in data.get("walkable", []):
		doc.walkable.append(str(row))
	for room_data: Variant in data.get("rooms", []):
		if room_data is Dictionary:
			doc.rooms.append(Room.from_dict(room_data))
	for console_data: Variant in data.get("consoles", []):
		if console_data is Dictionary:
			doc.consoles.append(Console.from_dict(console_data))
	var spawn: Variant = data.get("spawn_tile")
	if spawn is Array and spawn.size() == 2:
		doc.spawn_tile = Vector2i(int(spawn[0]), int(spawn[1]))
	var cargo: Variant = data.get("cargo")
	if cargo is Dictionary:
		doc.cargo_capacity = int(cargo.get("capacity", 0))
		doc.handling = str(cargo.get("handling", ""))
	return doc


## True if tile (tx,ty) is in bounds and marked walkable ('#') in the
## `walkable` row strings.
func is_walkable(tx: int, ty: int) -> bool:
	if ty < 0 or ty >= walkable.size():
		return false
	var row := walkable[ty]
	if tx < 0 or tx >= row.length():
		return false
	return row[tx] == "#"


## The room whose rect contains tile (tx,ty), or null (corridors and
## hull/void tiles have no room).
func room_at(tx: int, ty: int) -> Room:
	for room in rooms:
		if room.contains_tile(tx, ty):
			return room
	return null


func find_console(console_id: String) -> Console:
	for console in consoles:
		if console.id == console_id:
			return console
	return null


## Advances a standing character one tick of client-side prediction from
## `(x, y)` with move input `(dx, dy)` over `delta` seconds. Mirrors `step`
## in server/src/dh_server/character.gleam exactly: normalize input if its
## magnitude exceeds 1, then step x then y independently, rejecting an axis
## step (leaving that axis unchanged) if the character's collision circle at
## the candidate position overlaps a non-walkable tile of `cls` -- classic
## per-axis tile collision, so sliding into a wall at an angle keeps moving
## along it instead of stopping dead. Used only to predict the OWN
## character locally between server `interior` messages; other characters
## stay server-driven.
static func step_walk(cls: ShipClassData, x: float, y: float, dx: float, dy: float, delta: float) -> Vector2:
	var input := _normalize_input(dx, dy)
	var candidate_x := x + input.x * WALK_SPEED * delta
	var out_x := candidate_x if _circle_walkable(cls, candidate_x, y) else x
	var candidate_y := y + input.y * WALK_SPEED * delta
	var out_y := candidate_y if _circle_walkable(cls, out_x, candidate_y) else y
	return Vector2(out_x, out_y)


## Scales `(dx, dy)` down to magnitude 1 if it exceeds 1, leaving it
## unchanged otherwise -- mirrors `normalize` in character.gleam.
static func _normalize_input(dx: float, dy: float) -> Vector2:
	var magnitude_sq := dx * dx + dy * dy
	if magnitude_sq > 1.0:
		var magnitude := sqrt(magnitude_sq)
		return Vector2(dx / magnitude, dy / magnitude)
	return Vector2(dx, dy)


## Whether every tile overlapped by the character collision circle centered
## at `(cx, cy)` is walkable in `cls` -- mirrors `circle_walkable` in
## character.gleam (out-of-bounds tiles are non-walkable, via
## ShipClassData.is_walkable).
static func _circle_walkable(cls: ShipClassData, cx: float, cy: float) -> bool:
	var tx0 := int(floor(cx - CHARACTER_RADIUS))
	var tx1 := int(floor(cx + CHARACTER_RADIUS))
	var ty0 := int(floor(cy - CHARACTER_RADIUS))
	var ty1 := int(floor(cy + CHARACTER_RADIUS))
	for tx in range(tx0, tx1 + 1):
		for ty in range(ty0, ty1 + 1):
			if _tile_overlaps_circle(tx, ty, cx, cy) and not cls.is_walkable(tx, ty):
				return false
	return true


## Closest-point-on-AABB circle overlap test for tile `(tx, ty)` (spanning
## `[tx, tx+1) x [ty, ty+1)`) against the character circle centered at
## `(cx, cy)` -- mirrors `tile_overlaps_circle` in character.gleam.
static func _tile_overlaps_circle(tx: int, ty: int, cx: float, cy: float) -> bool:
	var closest_x := clampf(cx, float(tx), float(tx) + 1.0)
	var closest_y := clampf(cy, float(ty), float(ty) + 1.0)
	var dx := cx - closest_x
	var dy := cy - closest_y
	return dx * dx + dy * dy <= CHARACTER_RADIUS * CHARACTER_RADIUS
