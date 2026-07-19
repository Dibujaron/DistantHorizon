class_name ShipClassData
extends RefCounted
## Typed view of the wire protocol's ship-class / concourse deck plan
## (deck-plan format v3, docs/deckplan-format.md), parsed once at welcome
## (network_client.gd) so the interior renderer and input logic never touch
## raw JSON. This mirrors the server's deckplan.gleam + character.gleam: the
## client re-parses the same 3x3 grid rows and runs the same edge collision,
## so local prediction of the own character matches the server bit-for-bit.
##
## Interior coordinates are tile units, y-down; tile (x,y) spans
## [x, x+1) x [y, y+1), center (x+0.5, y+0.5).


## What a tile IS at its center.
enum Tile { VOID, FLOOR, STAIRS }

## What a tile edge carries. OPEN is passable; WALL and FIXTURE (a wall that
## also mounts art) block; DOOR is a passable opening.
enum Edge { OPEN, WALL, DOOR, FIXTURE }

## Edge directions, indexed 0=N, 1=E, 2=S, 3=W.
const EDGE_DELTAS: Array[Vector2i] = [
	Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]

## Walk speed, tiles/s -- mirrors `walk_speed` in character.gleam.
const WALK_SPEED := 3.0
## Character collision radius, tiles -- mirrors `radius` in character.gleam.
const CHARACTER_RADIUS := 0.3


## One deck: a width x height grid of tiles, each with its own four edges.
## `tiles[y][x]` is a Tile; `edges[y][x]` is [n, e, s, w] of Edge. Fixture
## letters (for rendering art) are kept in `fixtures["x,y,dir"] -> String`.
class Deck:
	var name: String
	var width: int
	var height: int
	var tiles: Array = []
	var edges: Array = []
	var fixtures: Dictionary = {}

	## Parse a width x height deck from 3*height rows of 3*width chars.
	static func from_grid(deck_name: String, rows: Array) -> Deck:
		var deck := Deck.new()
		deck.name = deck_name
		var row_count := rows.size()
		if row_count == 0 or row_count % 3 != 0:
			return deck
		var first_len: int = str(rows[0]).length()
		deck.width = first_len / 3
		deck.height = row_count / 3
		for ty in deck.height:
			var tile_row: Array = []
			var edge_row: Array = []
			for tx in deck.width:
				tile_row.append(_parse_center(_cell(rows, 3 * ty + 1, 3 * tx + 1)))
				var n := _parse_edge(_cell(rows, 3 * ty, 3 * tx + 1))
				var e := _parse_edge(_cell(rows, 3 * ty + 1, 3 * tx + 2))
				var s := _parse_edge(_cell(rows, 3 * ty + 2, 3 * tx + 1))
				var w := _parse_edge(_cell(rows, 3 * ty + 1, 3 * tx))
				edge_row.append([n, e, s, w])
				deck._note_fixture(tx, ty, 0, _cell(rows, 3 * ty, 3 * tx + 1))
				deck._note_fixture(tx, ty, 1, _cell(rows, 3 * ty + 1, 3 * tx + 2))
				deck._note_fixture(tx, ty, 2, _cell(rows, 3 * ty + 2, 3 * tx + 1))
				deck._note_fixture(tx, ty, 3, _cell(rows, 3 * ty + 1, 3 * tx))
			deck.tiles.append(tile_row)
			deck.edges.append(edge_row)
		return deck

	func _note_fixture(tx: int, ty: int, dir: int, ch: String) -> void:
		if _parse_edge(ch) == Edge.FIXTURE:
			fixtures["%d,%d,%d" % [tx, ty, dir]] = ch

	func in_bounds(tx: int, ty: int) -> bool:
		return tx >= 0 and tx < width and ty >= 0 and ty < height

	func tile_at(tx: int, ty: int) -> int:
		if not in_bounds(tx, ty):
			return Tile.VOID
		return tiles[ty][tx]

	## The four edges [n, e, s, w] of tile (tx, ty), or [] out of bounds.
	func edges_at(tx: int, ty: int) -> Array:
		if not in_bounds(tx, ty):
			return []
		return edges[ty][tx]

	## True if (tx, ty) is a walkable tile (Floor or Stairs, in bounds).
	func is_walkable(tx: int, ty: int) -> bool:
		var t := tile_at(tx, ty)
		return t == Tile.FLOOR or t == Tile.STAIRS

	## The single edge on tile (tx, ty)'s `dir` side; OPEN out of bounds.
	func edge_in(tx: int, ty: int, dir: int) -> int:
		var e := edges_at(tx, ty)
		if e.is_empty():
			return Edge.OPEN
		return e[dir]

	## Whether a step from (tx, ty) across its `dir` edge is blocked: the
	## double-wall OR-rule -- blocked if EITHER this tile's edge or the
	## neighbour's opposite edge is a wall/fixture. Mirrors edge_blocks in
	## deckplan.gleam.
	func edge_blocks(tx: int, ty: int, dir: int) -> bool:
		var d: Vector2i = EDGE_DELTAS[dir]
		return _blocks(edge_in(tx, ty, dir)) \
			or _blocks(edge_in(tx + d.x, ty + d.y, (dir + 2) % 4))

	static func _blocks(edge: int) -> bool:
		return edge == Edge.WALL or edge == Edge.FIXTURE

	static func _parse_center(ch: String) -> int:
		if ch == ".":
			return Tile.VOID
		if ch == "x":
			return Tile.STAIRS
		return Tile.FLOOR

	static func _parse_edge(ch: String) -> int:
		if ch == " ":
			return Edge.OPEN
		if ch == "#":
			return Edge.WALL
		if ch == "=":
			return Edge.DOOR
		return Edge.FIXTURE

	static func _cell(rows: Array, r: int, c: int) -> String:
		if r < 0 or r >= rows.size():
			return " "
		var row := str(rows[r])
		if c < 0 or c >= row.length():
			return " "
		return row[c]


## A console tile on one deck. `kind` "helm" binds flight controls; "cargo"
## opens the manifest; "broker" binds trading on station concourses.
class Console:
	var id: String
	var kind: String
	var deck: int
	var x: int
	var y: int

	static func from_dict(data: Dictionary) -> Console:
		var console := Console.new()
		console.id = str(data.get("id", ""))
		console.kind = str(data.get("kind", ""))
		console.deck = int(data.get("deck", 0))
		console.x = int(data.get("x", 0))
		console.y = int(data.get("y", 0))
		return console

	func tile_center() -> Vector2:
		return Vector2(x + 0.5, y + 0.5)


var schema: int = 3
var id: String = ""
var name: String = ""
var decks: Array[Deck] = []
var consoles: Array[Console] = []
var spawn_deck: int = 0
var spawn_tile: Vector2i = Vector2i.ZERO
## M3 cargo block (ship classes only; concourses leave these at 0/"").
var cargo_capacity: int = 0
var handling: String = ""
## This hull's docking-port outward normal, ship-local radians (0 = nose/+x);
## PI/2 = port flank (side-on mooring, the default).
var dock_port_orientation: float = PI / 2.0


static func from_dict(data: Dictionary) -> ShipClassData:
	var doc := ShipClassData.new()
	doc.schema = int(data.get("schema", 3))
	doc.id = str(data.get("id", ""))
	doc.name = str(data.get("name", doc.id))
	for deck_data: Variant in data.get("decks", []):
		if deck_data is Dictionary:
			var rows: Array = []
			for row: Variant in deck_data.get("grid", []):
				rows.append(str(row))
			doc.decks.append(Deck.from_grid(str(deck_data.get("name", "")), rows))
	for console_data: Variant in data.get("consoles", []):
		if console_data is Dictionary:
			doc.consoles.append(Console.from_dict(console_data))
	var spawn: Variant = data.get("spawn")
	if spawn is Dictionary:
		doc.spawn_deck = int(spawn.get("deck", 0))
		var tile: Variant = spawn.get("tile")
		if tile is Array and tile.size() == 2:
			doc.spawn_tile = Vector2i(int(tile[0]), int(tile[1]))
	var cargo: Variant = data.get("cargo")
	if cargo is Dictionary:
		doc.cargo_capacity = int(cargo.get("capacity", 0))
		doc.handling = str(cargo.get("handling", ""))
	doc.dock_port_orientation = float(
		data.get("dock_port_orientation", PI / 2.0))
	return doc


func deck_count() -> int:
	return decks.size()


## The deck grid at index `i`, or null out of range.
func get_deck(i: int) -> Deck:
	if i < 0 or i >= decks.size():
		return null
	return decks[i]


## True if tile (tx, ty) is walkable on deck `deck`.
func is_walkable(deck: int, tx: int, ty: int) -> bool:
	var g := get_deck(deck)
	return g != null and g.is_walkable(tx, ty)


## The tile type at (tx, ty) on deck `deck`; VOID out of range.
func tile_at(deck: int, tx: int, ty: int) -> int:
	var g := get_deck(deck)
	return Tile.VOID if g == null else g.tile_at(tx, ty)


## The Edge on tile (tx, ty)'s `dir` side of deck `deck`; OPEN out of range.
func edge_at(deck: int, tx: int, ty: int, dir: int) -> int:
	var g := get_deck(deck)
	return Edge.OPEN if g == null else g.edge_in(tx, ty, dir)


## The adjacent deck index a Stairs tile at (tx, ty) on `deck` connects to
## (deck+1, then deck-1), or -1. Strict deck±1 so ladder columns can repeat
## across decks; the composite indexes docked decks by concourse-relative
## level to keep adjacency. Mirrors stairs_target in deckplan.gleam.
func stairs_target(deck: int, tx: int, ty: int) -> int:
	var g := get_deck(deck)
	if g == null or g.tile_at(tx, ty) != Tile.STAIRS:
		return -1
	if _stairs_here(deck + 1, tx, ty):
		return deck + 1
	if _stairs_here(deck - 1, tx, ty):
		return deck - 1
	return -1


func _stairs_here(deck: int, tx: int, ty: int) -> bool:
	var g := get_deck(deck)
	return g != null and g.tile_at(tx, ty) == Tile.STAIRS


func find_console(console_id: String) -> Console:
	for console in consoles:
		if console.id == console_id:
			return console
	return null


## Advance a standing character one tick of client-side prediction on deck
## `deck` from `(x, y)` with move input `(dx, dy)` over `delta` seconds.
## Mirrors `step` in character.gleam: per-axis collision honoring wall/fixture
## edges, and a deck change when walking onto a stairs tile. Returns
## { "pos": Vector2, "deck": int }.
static func step_walk(cls: ShipClassData, deck: int, x: float, y: float, dx: float, dy: float, delta: float) -> Dictionary:
	var g := cls.get_deck(deck)
	if g == null:
		return {"pos": Vector2(x, y), "deck": deck}
	var input := _normalize_input(dx, dy)
	var old_tx := int(floor(x))
	var old_ty := int(floor(y))
	var candidate_x := x + input.x * WALK_SPEED * delta
	var out_x := candidate_x if _can_stand(g, candidate_x, y) else x
	var candidate_y := y + input.y * WALK_SPEED * delta
	var out_y := candidate_y if _can_stand(g, out_x, candidate_y) else y
	var new_deck := _deck_after_step(cls, g, deck, old_tx, old_ty, out_x, out_y)
	# On a deck change, snap to the stair tile's center so the collision circle
	# fits cleanly on both decks (mirrors character.gleam).
	var out_pos := Vector2(out_x, out_y)
	if new_deck != deck:
		out_pos = Vector2(floor(out_x) + 0.5, floor(out_y) + 0.5)
	return {"pos": out_pos, "deck": new_deck}


## The deck after a step: walking ONTO a stairs tile from a non-stairs tile
## switches to the aligned adjacent deck; else keep `deck`.
static func _deck_after_step(cls: ShipClassData, g: Deck, deck: int, old_tx: int, old_ty: int, x: float, y: float) -> int:
	var new_tx := int(floor(x))
	var new_ty := int(floor(y))
	var was_stairs := g.tile_at(old_tx, old_ty) == Tile.STAIRS
	var now_stairs := g.tile_at(new_tx, new_ty) == Tile.STAIRS
	if now_stairs and not was_stairs:
		var target := cls.stairs_target(deck, new_tx, new_ty)
		if target != -1:
			return target
	return deck


static func _normalize_input(dx: float, dy: float) -> Vector2:
	var magnitude_sq := dx * dx + dy * dy
	if magnitude_sq > 1.0:
		var magnitude := sqrt(magnitude_sq)
		return Vector2(dx / magnitude, dy / magnitude)
	return Vector2(dx, dy)


## Whether a body centered at (cx, cy) stands clear on `g`: every tile its
## collision circle overlaps is walkable, and it does not poke past a
## blocking edge of the tile its center is in. Mirrors can_stand in
## character.gleam.
static func _can_stand(g: Deck, cx: float, cy: float) -> bool:
	return _circle_tiles_walkable(g, cx, cy) and not _edge_collision(g, cx, cy)


static func _edge_collision(g: Deck, cx: float, cy: float) -> bool:
	var tx := int(floor(cx))
	var ty := int(floor(cy))
	var west := float(tx)
	var east := west + 1.0
	var north := float(ty)
	var south := north + 1.0
	if cx + CHARACTER_RADIUS > east and g.edge_blocks(tx, ty, 1):
		return true
	if cx - CHARACTER_RADIUS < west and g.edge_blocks(tx, ty, 3):
		return true
	if cy - CHARACTER_RADIUS < north and g.edge_blocks(tx, ty, 0):
		return true
	if cy + CHARACTER_RADIUS > south and g.edge_blocks(tx, ty, 2):
		return true
	return false


static func _circle_tiles_walkable(g: Deck, cx: float, cy: float) -> bool:
	var tx0 := int(floor(cx - CHARACTER_RADIUS))
	var tx1 := int(floor(cx + CHARACTER_RADIUS))
	var ty0 := int(floor(cy - CHARACTER_RADIUS))
	var ty1 := int(floor(cy + CHARACTER_RADIUS))
	for tx in range(tx0, tx1 + 1):
		for ty in range(ty0, ty1 + 1):
			if _tile_overlaps_circle(tx, ty, cx, cy) and not g.is_walkable(tx, ty):
				return false
	return true


static func _tile_overlaps_circle(tx: int, ty: int, cx: float, cy: float) -> bool:
	var closest_x := clampf(cx, float(tx), float(tx) + 1.0)
	var closest_y := clampf(cy, float(ty), float(ty) + 1.0)
	var dx := cx - closest_x
	var dy := cy - closest_y
	return dx * dx + dy * dy <= CHARACTER_RADIUS * CHARACTER_RADIUS
