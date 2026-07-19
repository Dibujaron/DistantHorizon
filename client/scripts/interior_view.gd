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
## Decks (deck-plan v3): each deck is its own grid; only the deck the own
## character is on renders (`view_deck`, an index). There is NO cross-deck
## sightline — void tiles on the view deck paint nothing (hull or window).
## `x` stairs tiles connect decks; characters on another deck are hidden.
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
const CONSOLE_HELM_COLOR := Color(0.55, 0.85, 1.0)
const CONSOLE_CARGO_COLOR := Color(0.9, 0.75, 0.35)
const CONSOLE_DEFAULT_COLOR := Color(0.8, 0.8, 0.85)
const OWN_CHARACTER_COLOR := Color(0.55, 0.85, 1.0)
const OTHER_CHARACTER_COLOR := Color(0.85, 0.85, 0.9, 0.7)
const CHARACTER_LABEL_COLOR := Color(0.8, 0.8, 0.85, 0.8)
const CHARACTER_RADIUS_TILES := 0.3
const FONT_SIZE := 16  # Jersey 15 diegetic slot (UiTheme)

const WALL_PX := 14.0

## #20: the open deck reads as one continuous surface. A flat FLOOR_COLOR fill
## under every tile is seamless (neighbours share the colour); the plate
## texture is only whispered back on top at this alpha, so the old per-tile
## grid is gone from open floor and structure lives only at the edges. Raise
## toward 1.0 to bring the plate seams back; 0.0 is dead flat.
const FLOOR_TEXTURE_ALPHA := 0.16

## #19 door hatch styling (procedural — no door art yet): a recessed threshold,
## two sliding leaves meeting at a lit centre seam, brass jamb posts at each end.
const DOOR_RECESS := Color(0.05, 0.06, 0.08)
const DOOR_LEAF := Color(0.16, 0.18, 0.22)
const DOOR_FRAME := Color(0.55, 0.42, 0.18)
const DOOR_SEAM := Color(0.75, 0.58, 0.25, 0.85)

const VIEW_CONE_DIM := Color(0.0, 0.0, 0.0, 0.55)
const VIEW_CONE_DARK := Color(0.02, 0.025, 0.045, 0.92)
const VIEW_RANGE_TILES := 5.5   # how far you can make out PEOPLE outside
## Draw size for the 22x34 character art ("a touch too small" at native).
const CHAR_SIZE := Vector2(27, 42)
## Baked walk sheets (see tools/character_walk_baker.gd): each `<name>_walk`
## texture is SHEET_CELLS cells wide — cell 0 idle, cells 1.. the walk cycle.
const SHEET_CELLS := 5
const WALK_FPS := 9.0
const WALK_FRAME_MS := 1000.0 / WALK_FPS
## A character counts as walking if it moved more than MOVE_EPS tiles since the
## last frame; the walk animation then coasts for MOVE_COAST_MS so brief
## sub-threshold frames (or the gap between network updates) don't flicker to
## idle mid-stride.
const MOVE_EPS := 0.01
const MOVE_COAST_MS := 140
const FACE_EPS := 0.01
## Movement must beat the cross-axis by this factor to change facing, so a
## near-diagonal path holds its current facing instead of strobing sheets.
const HYST_RATIO := 1.3
enum Facing { DOWN, UP, LEFT, RIGHT }


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
var view_deck: int = 0
var backdrops: Array[Backdrop] = []

## Toggled by main.gd on the V action. OFF is the walking experience for
## now; ON is the parked view-cone prototype (revisit post hull-fit).
var view_cone_enabled: bool = false

var _font: Font
var _lib: AssetLibrary = null
var _floor_tex: Array[Texture2D] = []
var _facing: Dictionary = {}        # character id -> Facing enum
var _last_pos: Dictionary = {}      # character id -> last drawn Vector2 (tiles)
var _walk_until: Dictionary = {}    # character id -> ms the walk cycle coasts to
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
	p_view_deck: int = 0,
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
	_draw_decor(origin)
	_draw_structure(origin)
	_draw_signage(origin)
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


## The deck grid currently in view (may be null before data arrives).
func _deck() -> ShipClassData.Deck:
	return ship_class.get_deck(view_deck)


func _grid_w() -> int:
	var g := _deck()
	return g.width if g != null else 0


func _grid_h() -> int:
	var g := _deck()
	return g.height if g != null else 0


func _grid_origin() -> Vector2:
	var viewport_size := get_viewport_rect().size
	var grid_size_px := Vector2(_grid_w(), _grid_h()) * TILE_PIXELS
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
	return ship_class.tile_at(view_deck, tx, ty) != ShipClassData.Tile.VOID


## The rendered structure on the boundary between tile (tx,ty) and its `dir`
## neighbour, merging both facing edges (the v3 double-wall model): a
## wall/fixture on either side reads as WALL; otherwise a door on either side
## reads as DOOR; else OPEN. Mirrors edge_blocks' OR-rule.
func _boundary(tx: int, ty: int, dir: int) -> int:
	var g := _deck()
	if g == null:
		return ShipClassData.Edge.OPEN
	var a := g.edge_in(tx, ty, dir)
	var d: Vector2i = ShipClassData.EDGE_DELTAS[dir]
	var b := g.edge_in(tx + d.x, ty + d.y, (dir + 2) % 4)
	if a == ShipClassData.Edge.WALL or a == ShipClassData.Edge.FIXTURE \
			or b == ShipClassData.Edge.WALL or b == ShipClassData.Edge.FIXTURE:
		return ShipClassData.Edge.WALL
	if a == ShipClassData.Edge.DOOR or b == ShipClassData.Edge.DOOR:
		return ShipClassData.Edge.DOOR
	return ShipClassData.Edge.OPEN


## #20: the open deck reads as one continuous surface — a flat fill under every
## floor tile (no seam between neighbours), with only a whisper of plate texture
## on top. Structure (walls, doors) is NOT drawn here: it lives at the edges,
## in _draw_structure, driven by the per-edge data (#19).
func _draw_floor(origin: Vector2) -> void:
	for ty in _grid_h():
		for tx in _grid_w():
			if not _vis(tx, ty):
				continue  # void/other-deck paints NOTHING — hull or window
			var pos := _tile_to_screen(Vector2(tx, ty), origin)
			var rect := Rect2(pos, Vector2(TILE_PIXELS, TILE_PIXELS))
			draw_rect(rect, FLOOR_COLOR, true)
			if FLOOR_TEXTURE_ALPHA > 0.0:
				var tex := _floor_tex[absi(hash(Vector2i(tx, ty))) % 3]
				if tex != null:
					draw_texture_rect(tex, rect, false,
						Color(1, 1, 1, FLOOR_TEXTURE_ALPHA))


## Decor (deck-plan v3.1): a decorative centre glyph (rug/seat/bed/pallet …)
## renders its sprite, tinted by the tile's NE-corner palette colour. Decor
## art doesn't exist yet, so a missing sprite falls back to a centred tinted
## swatch — authored decor + colour is visible NOW, ahead of the art.
func _draw_decor(origin: Vector2) -> void:
	var reg: GlyphRegistry = NetworkClient.glyphs
	if reg == null:
		return
	for ty in _grid_h():
		for tx in _grid_w():
			if not _vis(tx, ty):
				continue
			var glyph := ship_class.decor_at(view_deck, tx, ty)
			if glyph == "":
				continue
			var slot := ship_class.color_at(view_deck, tx, ty)
			var tint := NetworkClient.palette.color(slot) if slot >= 0 \
				and NetworkClient.palette != null else Color.WHITE
			var pos := _tile_to_screen(Vector2(tx, ty), origin)
			var sprite_id := reg.sprite_for_glyph(glyph)
			var tex: Texture2D = _lib.interior(sprite_id) if sprite_id != "" else null
			if tex != null:
				draw_texture_rect(tex, Rect2(pos, Vector2(TILE_PIXELS, TILE_PIXELS)), false, tint)
			else:
				# Placeholder until decor art exists: a centred tinted swatch.
				var m := TILE_PIXELS * 0.22
				draw_rect(Rect2(pos + Vector2(m, m), Vector2(TILE_PIXELS - 2 * m, TILE_PIXELS - 2 * m)),
					tint if slot >= 0 else Color(0.6, 0.6, 0.65), true)


## Walls and doors from the per-edge tile data (#19/#20). Each visible floor
## tile asks ShipClassData.edge_at for its four edges; a shared edge between
## two floor tiles is stamped once (by its N/W owner) so doors don't double up.
## Corner welds close wall junctions into one frame, exactly as the old
## adjacency bulkheads did — now keyed off the edge kinds instead of raw
## adjacency, so authored interior walls/doors weld correctly too.
func _draw_structure(origin: Vector2) -> void:
	var wall_tex := _lib.interior("wall_n")
	if wall_tex == null:
		return
	var reg: GlyphRegistry = NetworkClient.glyphs
	for ty in _grid_h():
		for tx in _grid_w():
			if not _vis(tx, ty):
				continue
			var pos := _tile_to_screen(Vector2(tx, ty), origin)
			for dir in 4:
				var kind := _boundary(tx, ty, dir)
				if kind == ShipClassData.Edge.OPEN or not _owns_edge(tx, ty, dir):
					continue
				if kind == ShipClassData.Edge.DOOR:
					_draw_edge_door(pos, dir)
				else:
					_draw_edge_wall(pos, dir, wall_tex, _fixture_tex(reg, tx, ty, dir))
			_draw_wall_corners(pos, tx, ty)


## A shared interior edge (floor on both sides) is stamped only from its N/W
## side so the two tiles don't each draw it; a hull edge (void beyond) is
## always owned by its floor tile.
func _owns_edge(tx: int, ty: int, dir: int) -> bool:
	if dir == 0 or dir == 3:  # N, W
		return true
	var d: Vector2i = ShipClassData.EDGE_DELTAS[dir]
	return not _vis(tx + d.x, ty + d.y)


## Whether tile (tx,ty)'s `dir` edge is a solid barrier (wall or edge-mounted
## equipment) — used for the corner welds.
func _edge_is_wall(tx: int, ty: int, dir: int) -> bool:
	return _boundary(tx, ty, dir) == ShipClassData.Edge.WALL


## Sets the draw transform so a local (TILE_PIXELS x WALL_PX) strip at the
## origin maps onto tile edge `dir` (0=N,1=E,2=S,3=W). Caller resets it.
func _begin_edge(pos: Vector2, dir: int) -> void:
	var t := TILE_PIXELS
	match dir:
		1:  # E
			draw_set_transform(pos + Vector2(t, 0), PI / 2, Vector2.ONE)
		2:  # S
			draw_set_transform(pos + Vector2(t, t), PI, Vector2.ONE)
		3:  # W
			draw_set_transform(pos + Vector2(0, t), -PI / 2, Vector2.ONE)
		_:  # N
			draw_set_transform(pos, 0.0, Vector2.ONE)


## A FIXTURE edge (window `w`, viewscreen `v`) draws its own sprite on the
## wall strip instead of a plain plate; `fixture_tex` is null for a plain WALL
## edge, or when the registry has no sprite for the fixture glyph yet — either
## way this falls back to `wall_tex` (today's look).
func _draw_edge_wall(pos: Vector2, dir: int, wall_tex: Texture2D, fixture_tex: Texture2D = null) -> void:
	_begin_edge(pos, dir)
	var tex := fixture_tex if fixture_tex != null else wall_tex
	draw_texture_rect(tex, Rect2(Vector2.ZERO, Vector2(TILE_PIXELS, WALL_PX)), false)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## The sprite texture for a FIXTURE boundary between tile (tx,ty) and its
## `dir` neighbour, or null when this boundary carries no fixture (a plain
## WALL) or the registry maps the fixture glyph to no sprite yet — either way
## the caller falls back to the plain wall plate. The double-wall model means
## the fixture's raw glyph may live on either facing side of the boundary.
func _fixture_tex(reg: GlyphRegistry, tx: int, ty: int, dir: int) -> Texture2D:
	if reg == null:
		return null
	var g := _deck()
	if g == null:
		return null
	var d: Vector2i = ShipClassData.EDGE_DELTAS[dir]
	var ch: String = str(g.fixtures.get("%d,%d,%d" % [tx, ty, dir], ""))
	if ch == "":
		ch = str(g.fixtures.get("%d,%d,%d" % [tx + d.x, ty + d.y, (dir + 2) % 4], ""))
	if ch == "":
		return null
	var sprite_id := reg.sprite_for_glyph(ch)
	return _lib.interior(sprite_id) if sprite_id != "" else null


## A hatch in the same strip footprint as a wall: recessed threshold, two
## sliding leaves meeting at a lit centre seam, brass jamb posts at each end.
func _draw_edge_door(pos: Vector2, dir: int) -> void:
	var t := TILE_PIXELS
	var w := WALL_PX
	var jamb := w * 0.55
	_begin_edge(pos, dir)
	draw_rect(Rect2(Vector2.ZERO, Vector2(t, w)), DOOR_RECESS, true)
	draw_rect(Rect2(Vector2(jamb, 1.0), Vector2(t * 0.5 - jamb, w - 2.0)), DOOR_LEAF, true)
	draw_rect(Rect2(Vector2(t * 0.5, 1.0), Vector2(t * 0.5 - jamb, w - 2.0)), DOOR_LEAF, true)
	draw_rect(Rect2(Vector2.ZERO, Vector2(jamb, w)), DOOR_FRAME, true)
	draw_rect(Rect2(Vector2(t - jamb, 0.0), Vector2(jamb, w)), DOOR_FRAME, true)
	draw_rect(Rect2(Vector2(t * 0.5 - 1.0, 2.0), Vector2(2.0, w - 4.0)), DOOR_SEAM, true)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## Corner blocks so wall junctions read as one welded frame: concave corners
## (two walls meeting on this tile) cap the strip overlap, and diagonal-void
## notches (both orthogonal neighbours floor but the diagonal is void) fill the
## gap between the neighbours' strips — the "laid against each other" seams.
func _draw_wall_corners(pos: Vector2, tx: int, ty: int) -> void:
	var corner_tex := _lib.interior("wall_corner")
	if corner_tex == null:
		return
	var t := TILE_PIXELS
	var c := Vector2(WALL_PX, WALL_PX)
	var wall_n := _edge_is_wall(tx, ty, 0)
	var wall_e := _edge_is_wall(tx, ty, 1)
	var wall_s := _edge_is_wall(tx, ty, 2)
	var wall_w := _edge_is_wall(tx, ty, 3)
	if wall_n and wall_w:
		draw_texture_rect(corner_tex, Rect2(pos, c), false)
	if wall_n and wall_e:
		draw_texture_rect(corner_tex, Rect2(pos + Vector2(t - WALL_PX, 0), c), false)
	if wall_s and wall_w:
		draw_texture_rect(corner_tex, Rect2(pos + Vector2(0, t - WALL_PX), c), false)
	if wall_s and wall_e:
		draw_texture_rect(corner_tex,
			Rect2(pos + Vector2(t - WALL_PX, t - WALL_PX), c), false)
	if not wall_n and not wall_w and not _vis(tx - 1, ty - 1):
		draw_texture_rect(corner_tex, Rect2(pos - c, c), false)
	if not wall_n and not wall_e and not _vis(tx + 1, ty - 1):
		draw_texture_rect(corner_tex, Rect2(pos + Vector2(t, -WALL_PX), c), false)
	if not wall_s and not wall_w and not _vis(tx - 1, ty + 1):
		draw_texture_rect(corner_tex, Rect2(pos + Vector2(-WALL_PX, t), c), false)
	if not wall_s and not wall_e and not _vis(tx + 1, ty + 1):
		draw_texture_rect(corner_tex, Rect2(pos + Vector2(t, t), c), false)


func _walkable(tx: int, ty: int) -> bool:
	return ship_class.is_walkable(view_deck, tx, ty)


# --------------------------------------------------------------- signage --
## Berth signage is now DATA-free: a berth mouth on a concourse is detected
## structurally — a walkable tile isolated east/west (a 1-wide stub poking up
## from the concourse floor). Only drawn on station spaces (heuristic: the plan
## has a broker console); numbered left to right.
func _draw_signage(origin: Vector2) -> void:
	var hazard := _lib.interior("hazard")
	var airlock := _lib.interior("picto_airlock")
	var stubs := _berth_stubs()
	for i in stubs.size():
		var stub: Vector2i = stubs[i]
		var pos := _tile_to_screen(Vector2(stub), origin)
		var center := pos + Vector2(TILE_PIXELS, TILE_PIXELS) * 0.5
		var digit := _lib.interior("digit_%d" % ((i + 1) % 10))
		if digit != null:
			draw_texture(digit, center - Vector2(13, 20), Color(1, 1, 1, 0.8))
		if airlock != null:
			draw_texture(airlock, center - Vector2(20, 20), Color(1, 1, 1, 0.3))
		if hazard != null:
			# hazard strip on the berth mouth (its south edge into the concourse)
			draw_texture_rect(hazard, Rect2(
				pos + Vector2(0, TILE_PIXELS - WALL_PX),
				Vector2(TILE_PIXELS, WALL_PX)), false)
	# faded trade pictogram on the floor beside each broker console
	var trade := _lib.interior("picto_trade")
	if trade != null:
		for console in ship_class.consoles:
			if console.kind != "broker" or console.deck != view_deck:
				continue
			var tile := Vector2i(int(console.tile_center().x), int(console.tile_center().y))
			var spot := tile + Vector2i(-1, 0) if _vis(tile.x - 1, tile.y) else tile
			draw_texture(trade,
				_tile_to_screen(Vector2(spot) + Vector2(0.19, 0.19), origin),
				Color(1, 1, 1, 0.35))


## Berth-stub tiles on the view deck, sorted left to right. A berth stub is a
## 1-wide tile (void east AND west) poking up from the WIDE concourse floor —
## its south neighbour is itself wide (floor to its east or west). That last
## clause is what excludes the docking tube, whose segments are a 1-wide column
## (each segment's south neighbour is another 1-wide tile). Empty unless the
## plan is a concourse (has a broker console), so ship interiors draw nothing.
func _berth_stubs() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var is_concourse := false
	for console in ship_class.consoles:
		if console.kind == "broker":
			is_concourse = true
			break
	if not is_concourse:
		return out
	for ty in _grid_h():
		for tx in _grid_w():
			var isolated := _vis(tx, ty) and not _vis(tx - 1, ty) and not _vis(tx + 1, ty)
			var wide_south := _vis(tx, ty + 1) \
					and (_vis(tx - 1, ty + 1) or _vis(tx + 1, ty + 1))
			if isolated and wide_south:
				out.append(Vector2i(tx, ty))
	out.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.x < b.x)
	return out


# -------------------------------------------------------------- consoles --
func _draw_consoles(origin: Vector2) -> void:
	# Sprite ids come from the server's glyph registry (issue #32), not a
	# hardcoded "console_<kind>" convention — so art is keyed on the console
	# kind/id, decoupled from the single-char map encoding.
	var reg: GlyphRegistry = NetworkClient.glyphs
	for console in ship_class.consoles:
		if console.deck != view_deck:
			continue  # a console on another deck is under/over this floor
		var center := _tile_to_screen(console.tile_center(), origin)
		var sprite_id := "" if reg == null else reg.sprite_for_console(console.kind)
		# A docking port is an airlock hatch, not a console desk.
		if console.kind == "dock":
			var picto: Texture2D = _lib.interior(sprite_id) if sprite_id != "" else null
			if picto != null:
				draw_texture(picto, center - Vector2(20, 20), Color(1, 1, 1, 0.65))
			continue
		var tex: Texture2D = _lib.interior(sprite_id) if sprite_id != "" else null
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
			var walkable := ship_class.is_walkable(view_deck, x0, y0)
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
## Pick a facing from this frame's movement delta. Sub-threshold movement or a
## near-diagonal (neither axis clearly dominant) holds the previous facing.
static func _facing_from_delta(dx: float, dy: float, prev: int) -> int:
	if abs(dx) < FACE_EPS and abs(dy) < FACE_EPS:
		return prev
	if abs(dx) > HYST_RATIO * abs(dy):
		return Facing.RIGHT if dx > 0.0 else Facing.LEFT
	if abs(dy) > HYST_RATIO * abs(dx):
		return Facing.DOWN if dy > 0.0 else Facing.UP
	return prev


func _draw_characters(origin: Vector2) -> void:
	var radius_px := CHARACTER_RADIUS_TILES * TILE_PIXELS
	for character in characters:
		var is_own: bool = character.id == own_character_id
		var tile := Vector2i(int(character.x), int(character.y))
		if not is_own:
			# A body on another deck is behind a floor/ceiling — not drawn.
			if character.deck != view_deck:
				continue
			if not _vis(tile.x, tile.y):
				continue
		if not is_own and not _tile_visible(tile):
			continue  # the view-cone hides who you can't see
		if not is_own and view_cone_enabled \
				and character.position().distance_to(focus_tile) > VIEW_RANGE_TILES:
			continue  # beyond the window range
		var screen_pos := _tile_to_screen(character.position(), origin)
		var base_name: String = "player" if is_own \
			else "crew_%d" % (absi(hash(character.id)) % 3)
		var tex := _lib.character(base_name)
		var walk := _lib.character(base_name + "_walk")
		var back_walk := _lib.character(base_name + "_back_walk")
		var side_walk := _lib.character(base_name + "_side_walk")
		if tex != null:
			# Facing + walk state from how far the body moved since last frame.
			var last: Vector2 = _last_pos.get(character.id, character.position())
			var prev_facing: int = _facing.get(character.id, Facing.DOWN)
			var facing := _facing_from_delta(
				character.x - last.x, character.y - last.y, prev_facing)
			var now := Time.get_ticks_msec()
			if character.position().distance_to(last) > MOVE_EPS:
				_walk_until[character.id] = now + MOVE_COAST_MS
			var walking: bool = not character.is_seated() \
				and now < int(_walk_until.get(character.id, 0))
			if character.is_seated():
				facing = Facing.DOWN          # seated at a console: face front
			_facing[character.id] = facing
			_last_pos[character.id] = character.position()
			# Choose the sheet for this facing; side art is drawn facing right,
			# so LEFT flips it. Missing directional sheets fall back to front.
			var sheet := walk
			var flip := 1.0
			match facing:
				Facing.UP:
					if back_walk != null:
						sheet = back_walk
				Facing.RIGHT:
					if side_walk != null:
						sheet = side_walk
				Facing.LEFT:
					if side_walk != null:
						sheet = side_walk
					flip = -1.0
			# feet at the collision circle's bottom edge; flip mirrors the
			# side view for left-facing (or the front fallback, as before).
			draw_set_transform(screen_pos + Vector2(0, radius_px),
				0.0, Vector2(flip, 1.0))
			if sheet != null:
				# Play the baked cycle: idle = cell 0, walking = cells 1.. by
				# wall-clock phase (offset per id so crew don't march in step).
				# The sheet is padded, so scale each cell to keep the body the
				# same on-screen size CHAR_SIZE gives the native art.
				var cell_w := sheet.get_width() / SHEET_CELLS
				var cell_h := sheet.get_height()
				var draw_w := CHAR_SIZE.x * float(cell_w) / float(tex.get_width())
				var draw_h := CHAR_SIZE.y * float(cell_h) / float(tex.get_height())
				var frame := 0
				if walking:
					frame = 1 + (int(now / WALK_FRAME_MS) + character.id) \
						% (SHEET_CELLS - 1)
				draw_texture_rect_region(sheet,
					Rect2(Vector2(-draw_w * 0.5, -draw_h), Vector2(draw_w, draw_h)),
					Rect2(frame * cell_w, 0, cell_w, cell_h))
			else:
				# No baked sheet — fall back to the single static frame.
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
