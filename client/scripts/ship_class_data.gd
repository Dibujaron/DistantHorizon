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
## "cargo" is inert in M2 (M3 will bind it).
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


var schema: int = 1
var id: String = ""
var name: String = ""
var grid_width: int = 0
var grid_height: int = 0
var walkable: Array[String] = []  ## one row string per y, '#' walkable, '.' hull/void
var rooms: Array[Room] = []
var consoles: Array[Console] = []
var spawn_tile: Vector2i = Vector2i.ZERO


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
