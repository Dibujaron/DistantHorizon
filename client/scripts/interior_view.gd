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
## M3.5 iteration 3 — the interior FITS ITS HULL: every hull in the current
## space (station concourse, moored ships, or the flying ship) gets its
## exterior sprite drawn as a to-scale backdrop under the tiles (pooled
## child sprites, show_behind_parent), scaled TILE_PIXELS / px_per_tile
## from the export's interior-fit meta. Hull skin shows wherever the plan
## has no floor inside the silhouette; space shows outside it.
##
## Split-level decks: the walkable alphabet (see ShipClassData.char_at)
## stacks two floors on one grid. Only the deck the own character is on
## renders ('2' tiles show their current-deck floor, 'B' between-levels
## and '#' generic tiles always show); characters on the other deck of a
## stacked region are hidden.
##
## The view-cone prototype (V toggles, OFF by default — parked for a
## revisit now that hull fit landed): full-viewport directional tile
## occlusion, rays never re-enter a hull.
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
const FONT_SIZE := 16  # Jersey 15 diegetic slot (UiTheme)

const ROOM_TINT_ALPHA := 0.10
const ROOM_TINT_PALETTE := [
	Color(0.25, 0.35, 0.45),
	Color(0.35, 0.3, 0.45),
	Color(0.3, 0.4, 0.3),
	Color(0.45, 0.35, 0.3),
]

const WALL_PX := 14.0
const VIEW_CONE_DIM := Color(0.0, 0.0, 0.0, 0.55)
const VIEW_CONE_DARK := Color(0.02, 0.025, 0.045, 0.92)
const VIEW_RANGE_TILES := 5.5   # how far you can make out PEOPLE outside
## Draw size for the 22x34 character art ("a touch too small" at native).
const CHAR_SIZE := Vector2(27, 42)


## One hull exterior drawn under the tiles: `asset` names a ship kind or
## station archetype in the AssetLibrary (use the *_interior 2x renders);
## `tile_origin` is where the hull's deckplan tile (0,0) sits in the
## current space's frame. `rotated` = moored side-on (90 CCW: nose west,
## port flank south — the composite rotates the plan the same way).
class Backdrop:
	var kind: String       ## "ship" | "station"
	var asset: String
	var tile_origin: Vector2
	var rotated: bool

	static func make(p_kind: String, p_asset: String, p_tile_origin: Vector2,
			p_rotated: bool = false) -> Backdrop:
		var b := Backdrop.new()
		b.kind = p_kind
		b.asset = p_asset
		b.tile_origin = p_tile_origin
		b.rotated = p_rotated
		return b


## Set every frame by main.gd before queue_redraw().
var ship_class: ShipClassData = null
var characters: Array[CharacterState] = []
var own_character_id: int = -1
var focus_tile: Vector2 = Vector2.ZERO
var view_deck: String = "upper"
var backdrops: Array[Backdrop] = []

## Toggled by main.gd on the V action. OFF is the walking experience for
## now; ON is the parked view-cone prototype (revisit post hull-fit).
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
	_font = UiTheme.pixel_font()  # in-world text speaks the diegetic slot
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
	p_focus_tile: Vector2,
	p_view_deck: String = "upper",
	p_backdrops: Array[Backdrop] = []
) -> void:
	ship_class = p_ship_class
	characters = p_characters
	own_character_id = p_own_character_id
	focus_tile = p_focus_tile
	view_deck = p_view_deck
	backdrops = p_backdrops
	queue_redraw()


func _draw() -> void:
	if ship_class == null:
		return
	var origin := _grid_origin()
	_refresh_los()
	_update_backdrops(origin)
	_draw_floor(origin)
	_draw_signage(origin)
	_draw_room_labels(origin)
	_draw_consoles(origin)
	_draw_view_cone(origin)
	_draw_characters(origin)


## Pooled exterior-sprite children under the tiles. Each sprite is a
## DIRECT child of this node with show_behind_parent, so it renders
## beneath this node's own floor/character drawing (the same trick the
## plumes use under ship sprites — behind-parent only counts against the
## sprite's immediate parent). Scaled so the hull's deckplan grid px map
## 1:1 onto TILE_PIXELS tiles, positioned via each hull's interior-fit
## meta + its tile offset in the current space.
func _update_backdrops(origin: Vector2) -> void:
	var touched := {}
	for i in backdrops.size():
		var spec := backdrops[i]
		var sset := _lib.ship(spec.asset) if spec.kind == "ship" \
			else _lib.station(spec.asset)
		if sset == null or not sset.has_interior_fit():
			continue
		var key := "bd_%d_%s" % [i, spec.asset]
		touched[key] = true
		var s: Sprite2D = get_node_or_null(NodePath(key))
		if s == null:
			s = Sprite2D.new()
			s.name = key
			s.texture = sset.texture
			s.material = sset.material
			s.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			s.light_mask = 2       # never sun-lit through the window
			s.show_behind_parent = true
			add_child(s)
		s.visible = true
		var px_scale := TILE_PIXELS / sset.px_per_tile()
		if spec.rotated:
			# Side-on mooring: the sprite rotates 90 CCW about its center.
			# For a full-width grid anchored at the sprite's top-left (the
			# Mockingbird contract), the rotated grid's (0,0) corner lands
			# at the rotated bounding box's top-left, so the box just swaps
			# its dimensions.
			var top_left_r := origin + spec.tile_origin * TILE_PIXELS
			s.rotation = -PI / 2
			s.position = top_left_r + Vector2(
				float(sset.px_size().y), float(sset.px_size().x)) * px_scale * 0.5
		else:
			var top_left := origin + spec.tile_origin * TILE_PIXELS \
				- sset.interior_origin_px() * px_scale
			s.rotation = 0.0
			s.position = top_left + Vector2(sset.px_size()) * px_scale * 0.5
		s.scale = Vector2.ONE * px_scale
	for child in get_children():
		if String(child.name).begins_with("bd_") \
				and not touched.has(String(child.name)):
			child.visible = false


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
## A floor tile is drawn iff it exists on the CURRENT view deck. Tiles of
## the other deck paint nothing: the hull backdrop shows there (you're
## looking at hull skin over the other floor, not through it).
func _vis(tx: int, ty: int) -> bool:
	return ship_class.visible_floor(view_deck, tx, ty)


## The first room containing the tile that belongs to the view deck (or to
## both). Stacked regions author one room per deck (hold under mess).
func _room_for_tile(tx: int, ty: int) -> ShipClassData.Room:
	for room in ship_class.rooms:
		if room.contains_tile(tx, ty) \
				and (room.deck == "" or room.deck == view_deck):
			return room
	return null


func _draw_floor(origin: Vector2) -> void:
	var wall_tex := _lib.interior("wall_n")
	for ty in ship_class.grid_height:
		for tx in ship_class.grid_width:
			if not _vis(tx, ty):
				continue  # void/other-deck paints NOTHING — hull or window
			var pos := _tile_to_screen(Vector2(tx, ty), origin)
			var rect := Rect2(pos, Vector2(TILE_PIXELS, TILE_PIXELS))
			var tex := _floor_tex[absi(hash(Vector2i(tx, ty))) % 3]
			if tex != null:
				draw_texture_rect(tex, rect, false)
			else:
				draw_rect(rect, FLOOR_COLOR, true)
			var room := _room_for_tile(tx, ty)
			if room != null:
				var tint_index := ship_class.rooms.find(room) % ROOM_TINT_PALETTE.size()
				var tint: Color = ROOM_TINT_PALETTE[tint_index]
				tint.a = ROOM_TINT_ALPHA
				draw_rect(rect, tint, true)
			if wall_tex != null:
				_draw_bulkheads(pos, tx, ty, wall_tex)


## Bulkhead cap on each edge of a floor tile that borders void/out-of-grid,
## plus corner blocks so junctions read as one welded frame: concave corners
## (two walls on this tile) get a block over the strip overlap, and
## diagonal-void notches (both orthogonal neighbors walkable but the
## diagonal is void) get a block filling the gap between the neighbors'
## strips — the "laid against each other" seams both live at those spots.
func _draw_bulkheads(pos: Vector2, tx: int, ty: int, wall_tex: Texture2D) -> void:
	var t := TILE_PIXELS
	var strip := Vector2(t, WALL_PX)
	var wall_n := not _vis(tx, ty - 1)
	var wall_s := not _vis(tx, ty + 1)
	var wall_e := not _vis(tx + 1, ty)
	var wall_w := not _vis(tx - 1, ty)
	if wall_n:
		draw_texture_rect(wall_tex, Rect2(pos, strip), false)
	if wall_s:
		draw_set_transform(pos + Vector2(t, t), PI, Vector2.ONE)
		draw_texture_rect(wall_tex, Rect2(Vector2.ZERO, strip), false)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if wall_e:
		draw_set_transform(pos + Vector2(t, 0), PI / 2, Vector2.ONE)
		draw_texture_rect(wall_tex, Rect2(Vector2.ZERO, strip), false)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if wall_w:
		draw_set_transform(pos + Vector2(0, t), -PI / 2, Vector2.ONE)
		draw_texture_rect(wall_tex, Rect2(Vector2.ZERO, strip), false)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	var corner_tex := _lib.interior("wall_corner")
	if corner_tex == null:
		return
	var c := Vector2(WALL_PX, WALL_PX)
	# concave: unify the overlap where two of this tile's strips cross
	if wall_n and wall_w:
		draw_texture_rect(corner_tex, Rect2(pos, c), false)
	if wall_n and wall_e:
		draw_texture_rect(corner_tex, Rect2(pos + Vector2(t - WALL_PX, 0), c), false)
	if wall_s and wall_w:
		draw_texture_rect(corner_tex, Rect2(pos + Vector2(0, t - WALL_PX), c), false)
	if wall_s and wall_e:
		draw_texture_rect(corner_tex,
			Rect2(pos + Vector2(t - WALL_PX, t - WALL_PX), c), false)
	# diagonal-void notch: fill the gap between the two neighbors' strips
	if not wall_n and not wall_w and not _vis(tx - 1, ty - 1):
		draw_texture_rect(corner_tex, Rect2(pos - c, c), false)
	if not wall_n and not wall_e and not _vis(tx + 1, ty - 1):
		draw_texture_rect(corner_tex, Rect2(pos + Vector2(t, -WALL_PX), c), false)
	if not wall_s and not wall_w and not _vis(tx - 1, ty + 1):
		draw_texture_rect(corner_tex, Rect2(pos + Vector2(-WALL_PX, t), c), false)
	if not wall_s and not wall_e and not _vis(tx + 1, ty + 1):
		draw_texture_rect(corner_tex, Rect2(pos + Vector2(t, t), c), false)


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
			# hatch-wheel picto centered on the berth stub tile, under the
			# digit — not jammed into the corner against the hazard strips
			draw_texture(airlock, center - Vector2(20, 20),
				Color(1, 1, 1, 0.3))
		if hazard != null:
			_draw_berth_hazards(room, hazard, origin)
	# faded trade pictogram on the floor beside each broker console
	var trade := _lib.interior("picto_trade")
	if trade != null:
		for console in ship_class.consoles:
			if console.kind != "broker":
				continue
			var tile := Vector2i(int(console.tile_center().x), int(console.tile_center().y))
			var spot := tile + Vector2i(-1, 0) if _vis(tile.x - 1, tile.y) else tile
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
			if not _vis(tx, ty):
				continue
			var pos := _tile_to_screen(Vector2(tx, ty), origin)
			for dir: Vector2i in [Vector2i(0, -1), Vector2i(0, 1), Vector2i(1, 0), Vector2i(-1, 0)]:
				var nx := tx + dir.x
				var ny := ty + dir.y
				if not _vis(nx, ny):
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
		if room.deck != "" and room.deck != view_deck:
			continue  # the other floor's room — not visible from this deck
		var center := _tile_to_screen(Vector2(room.x + room.w * 0.5, room.y + room.h * 0.5), origin)
		var text_size := _font.get_string_size(room.name, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE)
		draw_string(
			_font, center - text_size * 0.5, room.name,
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, ROOM_LABEL_COLOR)


# -------------------------------------------------------------- consoles --
func _draw_consoles(origin: Vector2) -> void:
	for console in ship_class.consoles:
		if not _vis(console.x, console.y):
			continue  # a console on the other deck is under/over this floor
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
	_los.clear()  # lazy memo — _tile_visible fills it on demand


## Lazy LOS memo over ANY tile coordinate (off-grid = open space). Purely
## directional: no distance cap — light crosses space, your hull is the
## only thing that blocks it.
func _tile_visible(tile: Vector2i) -> bool:
	if not view_cone_enabled:
		return true
	if not _los.has(tile):
		_los[tile] = _line_of_sight(_los_from, tile)
	return _los[tile]


## Directional occlusion over the whole viewport: every screen tile (on the
## plan OR out in space) that has no sight-line from you goes dark. Looking
## out a north plate shows you space to the north — never the planet on the
## far side of your own hull.
func _draw_view_cone(origin: Vector2) -> void:
	if not view_cone_enabled:
		return
	var vp := get_viewport_rect().size
	var t := TILE_PIXELS
	var tx0 := int(floorf(-origin.x / t)) - 1
	var ty0 := int(floorf(-origin.y / t)) - 1
	var tx1 := int(ceilf((vp.x - origin.x) / t)) + 1
	var ty1 := int(ceilf((vp.y - origin.y) / t)) + 1
	for ty in range(ty0, ty1):
		for tx in range(tx0, tx1):
			var tile := Vector2i(tx, ty)
			if _tile_visible(tile):
				continue
			draw_rect(
				Rect2(_tile_to_screen(Vector2(tx, ty), origin), Vector2(t, t)),
				VIEW_CONE_DIM if _walkable(tx, ty) else VIEW_CONE_DARK, true)


## Bresenham tile walk with the window rule: windows are the wall plates at
## the hull edge, so a ray may pass from floor OUT into void and keep going
## (that's looking out the plate next to you) — but once it has been in
## void it can never re-enter a hull (you don't see into other interiors
## across a gap, and interior wall gaps block room-to-room sight).
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
	var seen_void := false
	while true:
		var here := Vector2i(x0, y0)
		if here != from_tile:
			var walkable := ship_class.is_walkable(x0, y0)
			if walkable and seen_void:
				return false  # hull re-entry blocks — no seeing into other interiors
			if not walkable:
				seen_void = true
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
		if not is_own:
			# Split-level: a body on the other deck of this footprint is
			# behind a floor/ceiling — not drawn.
			if not _vis(tile.x, tile.y):
				continue
			if ship_class.char_at(tile.x, tile.y) == "2" \
					and character.deck != view_deck:
				continue
		if not is_own and not _tile_visible(tile):
			continue  # the view-cone hides who you can't see
		if not is_own and view_cone_enabled \
				and character.position().distance_to(focus_tile) > VIEW_RANGE_TILES:
			continue  # beyond the window range
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
			# feet at the collision circle's bottom edge; art is 22x34,
			# drawn at CHAR_SIZE (a touch bigger, user note round 9)
			draw_set_transform(screen_pos + Vector2(0, radius_px), 0.0,
				Vector2(facing, 1.0))
			draw_texture_rect(tex,
				Rect2(Vector2(-CHAR_SIZE.x * 0.5, -CHAR_SIZE.y), CHAR_SIZE),
				false)
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		else:
			var color := OWN_CHARACTER_COLOR if is_own else OTHER_CHARACTER_COLOR
			draw_circle(screen_pos, radius_px, color)
		if _font != null:
			var label: String = "you" if is_own else character.name
			draw_string(
				_font, screen_pos + Vector2(radius_px + 3.0, 4.0), label,
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, CHARACTER_LABEL_COLOR)
