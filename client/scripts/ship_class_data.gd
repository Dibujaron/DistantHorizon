class_name ShipClassData
extends RefCounted
## Typed view of the wire protocol's ship class doc (M2 spec, "Ship class
## doc"), parsed once at welcome (network_client.gd) so the interior
## renderer and input logic never touch raw JSON.
##
## Interior coordinates are tile units, ship-local, y-down; tile (x,y) spans
## [x, x+1) x [y, y+1), center (x+0.5, y+0.5) -- matches the server exactly.


## A labeled rectangular area of the deck plan (rendering/labels only; no
## door graph in M2). `deck` is split-level metadata: "lower"/"upper" shows
## the label only on that deck's view, "" (default) on both.
class Room:
	var id: String
	var name: String
	var x: int
	var y: int
	var w: int
	var h: int
	var deck: String

	static func from_dict(data: Dictionary) -> Room:
		var room := Room.new()
		room.id = str(data.get("id", ""))
		room.name = str(data.get("name", room.id))
		room.x = int(data.get("x", 0))
		room.y = int(data.get("y", 0))
		room.w = int(data.get("w", 0))
		room.h = int(data.get("h", 0))
		room.deck = str(data.get("deck", ""))
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

## Per-edge structure on a floor tile (#19). Every tile edge (N/E/S/W)
## declares what sits on it: NONE (open -- the floor runs straight through),
## WALL (a bulkhead), DOOR (a hatch, drawn distinctly), or EQUIPMENT
## (reserved: consoles/lockers/machinery mounted on an edge, styled later).
## Interior walls and doors are thus DATA, not implied by adjacency -- but a
## tile with no authored edge DERIVES the classic behaviour (a wall wherever
## floor meets void/other-deck) so existing deckplans render unchanged.
## #20 (grid softening), #22 (stairs) and #11 (collision) all build on this.
enum Edge { NONE, WALL, DOOR, EQUIPMENT }

## Edge directions, indexed to match EDGE_KEYS: 0=N, 1=E, 2=S, 3=W.
const EDGE_DELTAS: Array[Vector2i] = [
	Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
const EDGE_KEYS := ["n", "e", "s", "w"]
## Wire/author spelling -> Edge, for the optional `edges` block in a class doc.
const EDGE_NAMES := {
	"none": Edge.NONE, "wall": Edge.WALL,
	"door": Edge.DOOR, "equipment": Edge.EQUIPMENT}

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
## This hull's docking-port outward normal, ship-local radians (0 = nose/+x);
## PI/2 = port flank (side-on mooring, the default). With the station berth's
## orientation this fixes the moored heading (#14). Concourse plans, which
## carry no such field, keep the default.
var dock_port_orientation: float = PI / 2.0

## Authored per-edge structure: "x,y" -> { "n"/"e"/"s"/"w": Edge }. Empty
## means "derive every edge from adjacency" (fully backward compatible). Filled
## from the class doc's optional `edges` block, or -- until the server carries
## edges on the wire -- from a built-in client table for known hulls (see
## _apply_default_edges).
var edges: Dictionary = {}


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
	doc.dock_port_orientation = float(
		data.get("dock_port_orientation", PI / 2.0))
	var edges_data: Variant = data.get("edges")
	if edges_data is Dictionary:
		for cell_key: Variant in edges_data:
			var cell: Variant = edges_data[cell_key]
			if not cell is Dictionary:
				continue
			var parsed := {}
			for side: Variant in cell:
				var edge_name := str(cell[side]).to_lower()
				var side_key := str(side).to_lower()
				if EDGE_NAMES.has(edge_name) and side_key in EDGE_KEYS:
					parsed[side_key] = int(EDGE_NAMES[edge_name])
			if not parsed.is_empty():
				doc.edges[str(cell_key)] = parsed
	if doc.edges.is_empty():
		doc._apply_default_edges()
	return doc


## Interim client-side edge authoring (#19): until the server ships an `edges`
## block on the wire, seed doors/walls for known hulls here so the interior
## renders them today. Kept collision-neutral: these only mark HULL-edge
## boundaries (already non-walkable void beyond) as hatches, so the client's
## walkable prediction still matches the server's tile rule exactly. Authoring
## a BLOCKING interior partition would need the server's collision to agree --
## see the report's coordinator follow-up.
func _apply_default_edges() -> void:
	match id:
		"mockingbird":
			# Boarding hatch off the docking-deck between-level, plus a
			# port/starboard airlock on the widest hold ring.
			edges = {
				"6,22": {"s": Edge.DOOR},
				"7,22": {"s": Edge.DOOR},
				"3,14": {"w": Edge.DOOR},
				"10,14": {"e": Edge.DOOR},
			}


## The walkable character at tile (tx,ty), "." out of bounds. Alphabet
## (mirrors deckplan.gleam): '.' void, '#' generic single floor, 'L' lower
## deck only, 'U' upper deck only, '2' two stacked floors, 'B'
## between-level (one floor connecting both decks).
func char_at(tx: int, ty: int) -> String:
	if ty < 0 or ty >= walkable.size():
		return "."
	var row := walkable[ty]
	if tx < 0 or tx >= row.length():
		return "."
	return row[tx]


## True if tile (tx,ty) is in bounds and walkable on ANY deck.
func is_walkable(tx: int, ty: int) -> bool:
	return char_at(tx, ty) != "."


## Whether a walker on `deck` ("lower"/"upper") may stand on (tx,ty).
## `deck` "" is the between-level's deck-agnostic access (standing on 'B').
## Mirrors deckplan.walkable_for + character.step's 'B' rule exactly.
func walkable_for(deck: String, tx: int, ty: int) -> bool:
	var ch := char_at(tx, ty)
	if ch == ".":
		return false
	if ch == "L":
		return deck == "" or deck == "lower"
	if ch == "U":
		return deck == "" or deck == "upper"
	return true


## The deck a walker is on after arriving at position (x,y): exclusive
## tiles force it, everything else keeps `deck`. Mirrors
## deckplan.deck_of_tile via the center tile, like character.step.
func deck_after(deck: String, x: float, y: float) -> String:
	var ch := char_at(int(floor(x)), int(floor(y)))
	if ch == "L":
		return "lower"
	if ch == "U":
		return "upper"
	return deck


## Whether a floor exists at (tx,ty) as seen from `view_deck`: generic,
## between-level and stacked tiles always show; exclusive tiles only on
## their own deck. (Rendering helper — NOT the movement rule.)
func visible_floor(view_deck: String, tx: int, ty: int) -> bool:
	var ch := char_at(tx, ty)
	if ch == "." :
		return false
	if ch == "L":
		return view_deck == "lower"
	if ch == "U":
		return view_deck == "upper"
	return true


## The structure on tile (tx,ty)'s `dir` edge (0=N,1=E,2=S,3=W) as seen from
## `view_deck` (#19). Non-floor tiles have no edges. An authored edge wins --
## this tile's, or the neighbour's matching edge, so a door authored from
## either side shows once. Otherwise DERIVE: WALL where this floor meets
## void/off-grid/the other deck, else NONE. Rendering-only: collision still
## runs on walkable_for (the server's tile rule) until edges reach the wire.
func edge_at(view_deck: String, tx: int, ty: int, dir: int) -> int:
	if not visible_floor(view_deck, tx, ty):
		return Edge.NONE
	var authored := _authored_edge(tx, ty, dir)
	if authored == -1:
		var d: Vector2i = EDGE_DELTAS[dir]
		authored = _authored_edge(tx + d.x, ty + d.y, (dir + 2) % 4)
	if authored != -1:
		return authored
	var nd: Vector2i = EDGE_DELTAS[dir]
	return Edge.WALL if not visible_floor(view_deck, tx + nd.x, ty + nd.y) else Edge.NONE


## The authored Edge on tile (tx,ty)'s `dir` edge, or -1 if none is authored.
func _authored_edge(tx: int, ty: int, dir: int) -> int:
	var cell: Variant = edges.get("%d,%d" % [tx, ty])
	if cell is Dictionary and cell.has(EDGE_KEYS[dir]):
		return int(cell[EDGE_KEYS[dir]])
	return -1


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
static func step_walk(cls: ShipClassData, deck: String, x: float, y: float, dx: float, dy: float, delta: float) -> Vector2:
	var input := _normalize_input(dx, dy)
	# Standing on a between-level ('B') tile grants deck-agnostic access —
	# that is how a walker changes decks. Mirrors character.step exactly.
	var gate := "" if cls.char_at(int(floor(x)), int(floor(y))) == "B" else deck
	var candidate_x := x + input.x * WALK_SPEED * delta
	var out_x := candidate_x if _circle_walkable(cls, gate, candidate_x, y) else x
	var candidate_y := y + input.y * WALK_SPEED * delta
	var out_y := candidate_y if _circle_walkable(cls, gate, out_x, candidate_y) else y
	# Corner un-stick (#11): if a tick STARTS already overlapping a wall (a
	# server snap into tight geometry, a plan swap, a hard reconciliation pull),
	# per-axis rejection can never escape -- every small step still overlaps, so
	# the body wedges into the corner permanently. Detect that stuck state and
	# push the circle out along the shortest separation so the player always
	# slides free. A strict no-op whenever the resolved position is already
	# clear, so normal walking stays byte-for-byte identical to the server step.
	if not _circle_walkable(cls, gate, out_x, out_y):
		var freed := _unstick(cls, gate, out_x, out_y)
		out_x = freed.x
		out_y = freed.y
	return Vector2(out_x, out_y)


## Push a circle centred at `(cx, cy)` out of any non-walkable tiles it
## overlaps, back toward open floor (#11). Sums a separation vector from each
## penetrated tile (the minimum-translation direction * penetration depth); if
## the centre sits dead inside a wall (no separation direction), nudges toward
## the first walkable cardinal neighbour. Convergent: while still overlapping,
## step_walk calls this again next tick until the body is clear.
static func _unstick(cls: ShipClassData, deck: String, cx: float, cy: float) -> Vector2:
	var push := Vector2.ZERO
	var tx0 := int(floor(cx - CHARACTER_RADIUS))
	var tx1 := int(floor(cx + CHARACTER_RADIUS))
	var ty0 := int(floor(cy - CHARACTER_RADIUS))
	var ty1 := int(floor(cy + CHARACTER_RADIUS))
	for tx in range(tx0, tx1 + 1):
		for ty in range(ty0, ty1 + 1):
			if cls.walkable_for(deck, tx, ty):
				continue
			if not _tile_overlaps_circle(tx, ty, cx, cy):
				continue
			var closest_x := clampf(cx, float(tx), float(tx) + 1.0)
			var closest_y := clampf(cy, float(ty), float(ty) + 1.0)
			var away := Vector2(cx - closest_x, cy - closest_y)
			var dist := away.length()
			if dist > 0.0001:
				push += away / dist * (CHARACTER_RADIUS - dist)
	if push == Vector2.ZERO:
		# Centre is inside a wall tile: escape toward the nearest open cardinal.
		for dir in EDGE_DELTAS:
			var probe := Vector2(cx, cy) + Vector2(dir) * (CHARACTER_RADIUS * 2.0)
			if _circle_walkable(cls, deck, probe.x, probe.y):
				return probe
		return Vector2(cx, cy)
	push = push.normalized() * (push.length() + 0.001)
	return Vector2(cx + push.x, cy + push.y)


## Scales `(dx, dy)` down to magnitude 1 if it exceeds 1, leaving it
## unchanged otherwise -- mirrors `normalize` in character.gleam.
static func _normalize_input(dx: float, dy: float) -> Vector2:
	var magnitude_sq := dx * dx + dy * dy
	if magnitude_sq > 1.0:
		var magnitude := sqrt(magnitude_sq)
		return Vector2(dx / magnitude, dy / magnitude)
	return Vector2(dx, dy)


## Whether every tile overlapped by the character collision circle centered
## at `(cx, cy)` is walkable for a body on `deck` ("" = deck-agnostic, the
## between-level rule) -- mirrors `circle_walkable` in character.gleam
## (out-of-bounds tiles are non-walkable, via walkable_for).
static func _circle_walkable(cls: ShipClassData, deck: String, cx: float, cy: float) -> bool:
	var tx0 := int(floor(cx - CHARACTER_RADIUS))
	var tx1 := int(floor(cx + CHARACTER_RADIUS))
	var ty0 := int(floor(cy - CHARACTER_RADIUS))
	var ty1 := int(floor(cy + CHARACTER_RADIUS))
	for tx in range(tx0, tx1 + 1):
		for ty in range(ty0, ty1 + 1):
			if _tile_overlaps_circle(tx, ty, cx, cy) and not cls.walkable_for(deck, tx, ty):
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
