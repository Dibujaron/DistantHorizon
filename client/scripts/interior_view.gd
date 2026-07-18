extends Node2D
class_name InteriorView
## Draws the walkable interior (deck plan or station composite) and the
## characters aboard, sibling of world_view.gd.
##
## M3.5: the interior reads as a place, not a grid — textured deck plates
## (variants by tile hash, seams in the art, no grid lines), bulkhead caps
## on every floor/void edge, signage (stencil berth digits, worn hazard
## stripes at berth mouths, Semiotic-Standard pictograms), console sprites,
## and FTL-scale character sprites. Void tiles paint NOTHING: main.gd keeps
## the system view visible (dimmed) beneath this node, so space shows
## through everywhere the plan isn't — THE WINDOW.
##
## The view-cone prototype (toggle V) dims walkable tiles without tile
## line-of-sight from the own character and hides characters standing on
## them. It's a layer — default off, may be cut.
##
## Camera: no zoom, but a clamped follow — an axis whose extent fits the
## viewport is centered; an axis that overflows follows the own character,
## clamped to the grid's edges (M3.1 composites outgrow one screen).

const TILE_PIXELS := 64.0

const FLOOR_COLOR := Color(0.16, 0.17, 0.22)      # fallback when art missing
const ROOM_LABEL_COLOR := Color(0.85, 0.85, 0.9, 0.55)
const CONSOLE_HELM_COLOR := Color(0.55, 0.85, 1.0)
const CONSOLE_CARGO_COLOR := Color(0.9, 0.75, 0.35)
const CONSOLE_DEFAULT_COLOR := Color(0.8, 0.8, 0.85)
const OWN_CHARACTER_COLOR := Color(0.55, 0.85, 1.0)
const OTHER_CHARACTER_COLOR := Color(0.85, 0.85, 0.9, 0.7)
const CHARACTER_LABEL_COLOR := Color(0.8, 0.8, 0.85, 0.8)
const CHARACTER_RADIUS_TILES := 0.3
const FONT_SIZE := 13

const ROOM_TINT_ALPHA := 0.10
const ROOM_TINT_PALETTE := [
	Color(0.25, 0.35, 0.45),
	Color(0.35, 0.3, 0.45),
	Color(0.3, 0.4, 0.3),
	Color(0.45, 0.35, 0.3),
]

const WALL_PX := 14.0
const VIEW_CONE_DIM := Color(0.0, 0.0, 0.0, 0.55)
const CHAR_SIZE := Vector2(22, 34)

## Set every frame by main.gd before queue_redraw().
var ship_class: ShipClassData = null
var characters: Array[CharacterState] = []
var own_character_id: int = -1
var focus_tile: Vector2 = Vector2.ZERO

## Toggled by main.gd on the V action.
var view_cone_enabled: bool = false

var _font: Font
var _lib: AssetLibrary = null
var _floor_tex: Array[Texture2D] = []
var _facing: Dictionary = {}        # character id -> -1.0 | 1.0
var _last_char_x: Dictionary = {}   # character id -> last tile x
## LOS cache: Vector2i tile -> bool visible; recomputed when the own tile,
## the plan, or the toggle changes.
var _los: Dictionary = {}
var _los_from: Vector2i = Vector2i(-1000, -1000)
var _los_plan: ShipClassData = null


func _ready() -> void:
	_font = ThemeDB.fallback_font
	_lib = AssetLibrary.load_all()
	for i in 3:
		_floor_tex.append(_lib.interior("floor_%d" % i))


## Called by main.gd once per frame. `p_focus_tile` is the own character's
## position (tile units) — the camera centers on it when the plan is too
## big for the viewport.
func set_frame_data(
	p_ship_class: ShipClassData,
	p_characters: Array[CharacterState],
	p_own_character_id: int,
	p_focus_tile: Vector2
) -> void:
	ship_class = p_ship_class
	characters = p_characters
	own_character_id = p_own_character_id
	focus_tile = p_focus_tile
	queue_redraw()


func _draw() -> void:
	if ship_class == null:
		return
	var origin := _grid_origin()
	_refresh_los()
	_draw_floor(origin)
	_draw_signage(origin)
	_draw_room_labels(origin)
	_draw_view_cone(origin)
	_draw_consoles(origin)
	_draw_characters(origin)


func _grid_origin() -> Vector2:
	var viewport_size := get_viewport_rect().size
	var grid_size_px := Vector2(ship_class.grid_width, ship_class.grid_height) * TILE_PIXELS
	var origin := (viewport_size - grid_size_px) * 0.5
	if grid_size_px.x > viewport_size.x:
		origin.x = clampf(
			viewport_size.x * 0.5 - focus_tile.x * TILE_PIXELS,
			viewport_size.x - grid_size_px.x, 0.0)
	if grid_size_px.y > viewport_size.y:
		origin.y = clampf(
			viewport_size.y * 0.5 - focus_tile.y * TILE_PIXELS,
			viewport_size.y - grid_size_px.y, 0.0)
	return origin


func _tile_to_screen(tile: Vector2, origin: Vector2) -> Vector2:
	return origin + tile * TILE_PIXELS


# ---------------------------------------------------------------- floors --
func _draw_floor(origin: Vector2) -> void:
	var wall_tex := _lib.interior("wall_n")
	for ty in ship_class.grid_height:
		for tx in ship_class.grid_width:
			if not ship_class.is_walkable(tx, ty):
				continue  # void paints NOTHING — the window shows through
			var pos := _tile_to_screen(Vector2(tx, ty), origin)
			var rect := Rect2(pos, Vector2(TILE_PIXELS, TILE_PIXELS))
			var tex := _floor_tex[absi(hash(Vector2i(tx, ty))) % 3]
			if tex != null:
				draw_texture_rect(tex, rect, false)
			else:
				draw_rect(rect, FLOOR_COLOR, true)
			var room := ship_class.room_at(tx, ty)
			if room != null:
				var tint_index := ship_class.rooms.find(room) % ROOM_TINT_PALETTE.size()
				var tint: Color = ROOM_TINT_PALETTE[tint_index]
				tint.a = ROOM_TINT_ALPHA
				draw_rect(rect, tint, true)
			if wall_tex != null:
				_draw_bulkheads(pos, tx, ty, wall_tex)


## Bulkhead cap on each edge of a floor tile that borders void/out-of-grid.
func _draw_bulkheads(pos: Vector2, tx: int, ty: int, wall_tex: Texture2D) -> void:
	var t := TILE_PIXELS
	var strip := Vector2(t, WALL_PX)
	if not _walkable(tx, ty - 1):   # north
		draw_texture_rect(wall_tex, Rect2(pos, strip), false)
	if not _walkable(tx, ty + 1):   # south: flip vertically
		draw_set_transform(pos + Vector2(t, t), PI, Vector2.ONE)
		draw_texture_rect(wall_tex, Rect2(Vector2.ZERO, strip), false)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if not _walkable(tx + 1, ty):   # east
		draw_set_transform(pos + Vector2(t, 0), PI / 2, Vector2.ONE)
		draw_texture_rect(wall_tex, Rect2(Vector2.ZERO, strip), false)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if not _walkable(tx - 1, ty):   # west
		draw_set_transform(pos + Vector2(0, t), -PI / 2, Vector2.ONE)
		draw_texture_rect(wall_tex, Rect2(Vector2.ZERO, strip), false)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _walkable(tx: int, ty: int) -> bool:
	if tx < 0 or ty < 0 or tx >= ship_class.grid_width or ty >= ship_class.grid_height:
		return false
	return ship_class.is_walkable(tx, ty)


# --------------------------------------------------------------- signage --
func _draw_signage(origin: Vector2) -> void:
	var hazard := _lib.interior("hazard")
	var airlock := _lib.interior("picto_airlock")
	for room in ship_class.rooms:
		if not room.id.begins_with("berth_"):
			continue
		var n := int(room.id.trim_prefix("berth_"))
		var center := _tile_to_screen(
			Vector2(room.x + room.w * 0.5, room.y + room.h * 0.5), origin)
		var digit := _lib.interior("digit_%d" % (n % 10))
		if digit != null:
			draw_texture(digit, center - Vector2(13, 20),
				Color(1, 1, 1, 0.8))
		if airlock != null:
			draw_texture(airlock,
				_tile_to_screen(Vector2(room.x, room.y), origin) + Vector2(3, 3),
				Color(1, 1, 1, 0.45))
		if hazard != null:
			_draw_berth_hazards(room, hazard, origin)
	# faded trade pictogram on the floor beside each broker console
	var trade := _lib.interior("picto_trade")
	if trade != null:
		for console in ship_class.consoles:
			if console.kind != "broker":
				continue
			var tile := Vector2i(int(console.tile_center().x), int(console.tile_center().y))
			var spot := tile + Vector2i(-1, 0) if _walkable(tile.x - 1, tile.y) else tile
			draw_texture(trade,
				_tile_to_screen(Vector2(spot) + Vector2(0.19, 0.19), origin),
				Color(1, 1, 1, 0.35))


## Hazard strips along every edge where a berth-room tile meets walkable
## floor OUTSIDE the room — the berth mouth gets striped.
func _draw_berth_hazards(room, hazard: Texture2D, origin: Vector2) -> void:
	var t := TILE_PIXELS
	var strip := Vector2(t, WALL_PX)
	for ty in range(room.y, room.y + room.h):
		for tx in range(room.x, room.x + room.w):
			if not _walkable(tx, ty):
				continue
			var pos := _tile_to_screen(Vector2(tx, ty), origin)
			for dir: Vector2i in [Vector2i(0, -1), Vector2i(0, 1), Vector2i(1, 0), Vector2i(-1, 0)]:
				var nx := tx + dir.x
				var ny := ty + dir.y
				if not _walkable(nx, ny):
					continue
				if _room_contains(room, nx, ny):
					continue
				if dir == Vector2i(0, -1):
					draw_texture_rect(hazard, Rect2(pos, strip), false)
				elif dir == Vector2i(0, 1):
					draw_texture_rect(hazard,
						Rect2(pos + Vector2(0, t - WALL_PX), strip), false)
				elif dir == Vector2i(1, 0):
					draw_set_transform(pos + Vector2(t, 0), PI / 2, Vector2.ONE)
					draw_texture_rect(hazard, Rect2(Vector2.ZERO, strip), false)
					draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
				else:
					draw_set_transform(pos + Vector2(WALL_PX, 0), PI / 2, Vector2.ONE)
					draw_texture_rect(hazard, Rect2(Vector2.ZERO, strip), false)
					draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _room_contains(room, tx: int, ty: int) -> bool:
	return tx >= room.x and tx < room.x + room.w \
		and ty >= room.y and ty < room.y + room.h


func _draw_room_labels(origin: Vector2) -> void:
	if _font == null:
		return
	for room in ship_class.rooms:
		if room.id.begins_with("berth_"):
			continue  # berths carry stencil digits instead
		var center := _tile_to_screen(Vector2(room.x + room.w * 0.5, room.y + room.h * 0.5), origin)
		var text_size := _font.get_string_size(room.name, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE)
		draw_string(
			_font, center - text_size * 0.5, room.name,
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, ROOM_LABEL_COLOR)


# -------------------------------------------------------------- consoles --
func _draw_consoles(origin: Vector2) -> void:
	for console in ship_class.consoles:
		var center := _tile_to_screen(console.tile_center(), origin)
		var tex := _lib.interior("console_" + console.kind)
		if tex != null:
			draw_texture(tex, center - Vector2(22, 22))
			continue
		var color := CONSOLE_DEFAULT_COLOR
		if console.kind == "helm":
			color = CONSOLE_HELM_COLOR
		elif console.kind == "cargo":
			color = CONSOLE_CARGO_COLOR
		var half := TILE_PIXELS * 0.35
		draw_rect(Rect2(center - Vector2(half, half), Vector2(half, half) * 2.0), color, true)


# ------------------------------------------------------------- view-cone --
func _refresh_los() -> void:
	if not view_cone_enabled:
		return
	var from := Vector2i(int(focus_tile.x), int(focus_tile.y))
	if from == _los_from and ship_class == _los_plan:
		return
	_los_from = from
	_los_plan = ship_class
	_los.clear()
	for ty in ship_class.grid_height:
		for tx in ship_class.grid_width:
			if ship_class.is_walkable(tx, ty):
				_los[Vector2i(tx, ty)] = _line_of_sight(from, Vector2i(tx, ty))


func _tile_visible(tile: Vector2i) -> bool:
	return not view_cone_enabled or bool(_los.get(tile, true))


func _draw_view_cone(origin: Vector2) -> void:
	if not view_cone_enabled:
		return
	for ty in ship_class.grid_height:
		for tx in ship_class.grid_width:
			if not ship_class.is_walkable(tx, ty):
				continue
			if not _tile_visible(Vector2i(tx, ty)):
				draw_rect(Rect2(_tile_to_screen(Vector2(tx, ty), origin),
					Vector2(TILE_PIXELS, TILE_PIXELS)), VIEW_CONE_DIM, true)


## Bresenham tile walk; blocked by non-walkable tiles between the endpoints.
func _line_of_sight(from_tile: Vector2i, to_tile: Vector2i) -> bool:
	var x0 := from_tile.x
	var y0 := from_tile.y
	var x1 := to_tile.x
	var y1 := to_tile.y
	var dx := absi(x1 - x0)
	var dy := -absi(y1 - y0)
	var sx := 1 if x0 < x1 else -1
	var sy := 1 if y0 < y1 else -1
	var err := dx + dy
	while true:
		if Vector2i(x0, y0) != from_tile and Vector2i(x0, y0) != to_tile \
				and not ship_class.is_walkable(x0, y0):
			return false
		if x0 == x1 and y0 == y1:
			return true
		var e2 := 2 * err
		if e2 >= dy:
			err += dy
			x0 += sx
		if e2 <= dx:
			err += dx
			y0 += sy
	return true


# ------------------------------------------------------------ characters --
func _draw_characters(origin: Vector2) -> void:
	var radius_px := CHARACTER_RADIUS_TILES * TILE_PIXELS
	for character in characters:
		var is_own: bool = character.id == own_character_id
		var tile := Vector2i(int(character.x), int(character.y))
		if not is_own and not _tile_visible(tile):
			continue  # the view-cone hides who you can't see
		var screen_pos := _tile_to_screen(character.position(), origin)
		var tex := _lib.character("player" if is_own
			else "crew_%d" % (absi(hash(character.id)) % 3))
		if tex != null:
			var facing: float = _facing.get(character.id, 1.0)
			var last_x: float = _last_char_x.get(character.id, character.x)
			if character.x - last_x > 0.01:
				facing = 1.0
			elif character.x - last_x < -0.01:
				facing = -1.0
			_facing[character.id] = facing
			_last_char_x[character.id] = character.x
			# feet at the collision circle's bottom edge
			draw_set_transform(screen_pos + Vector2(0, radius_px), 0.0,
				Vector2(facing, 1.0))
			draw_texture(tex, Vector2(-CHAR_SIZE.x * 0.5, -CHAR_SIZE.y))
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		else:
			var color := OWN_CHARACTER_COLOR if is_own else OTHER_CHARACTER_COLOR
			draw_circle(screen_pos, radius_px, color)
		if _font != null:
			var label: String = "you" if is_own else character.name
			draw_string(
				_font, screen_pos + Vector2(radius_px + 3.0, 4.0), label,
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, CHARACTER_LABEL_COLOR)
