extends Node2D
class_name WorldView
## Draws the world in a viewport centered on a supplied focus point (normally
## the local player's own ship) with adjustable zoom.
##
## M3.5: the space layer is textured. `_draw()` keeps only the vector pass
## (parallax star tiles, orbit paths, dock rings, labels); everything with a
## texture lives on managed child sprites — Classic body sprites, generated
## station exteriors (with docked ships parked at berth anchors), and lit
## ship sprites from the composer pipeline (CanvasTexture albedo+normal +
## the quantize shader), lit by one DirectionalLight2D per star. Suns light
## ONLY pipeline sprites (cull mask 1); hand-drawn art has no normals and
## opts out via light_mask 2 (docs/visuals.md, The void).
##
## All world/ship data arrives as typed objects (WorldData, ShipState);
## the rail math lives on WorldData.

const PIXELS_PER_UNIT := 1.0

const ORBIT_PATH_COLOR := Color(1.0, 1.0, 1.0, 0.12)
const STATION_LABEL_COLOR := Color(0.75, 0.95, 0.8, 0.9)
const DOCK_RING_COLOR := Color(0.6, 0.95, 0.7, 0.35)
const OTHER_SHIP_LABEL_COLOR := Color(0.8, 0.8, 0.85, 0.7)

const FONT_SIZE := 13

## Fallback vectors (assets missing / first frame) — the pre-M3.5 look.
const STAR_COLOR := Color(1.0, 0.78, 0.35)
const STATION_COLOR := Color(0.6, 0.95, 0.7)
const OWN_SHIP_COLOR := Color(0.55, 0.85, 1.0)
const OTHER_SHIP_COLOR := Color(0.55, 0.85, 1.0, 0.45)
const SHIP_SIZE := 8.0
const STATION_MARKER_SIZE := 6.0
const PLANET_PALETTE := [
	Color(0.45, 0.7, 0.45),
	Color(0.8, 0.55, 0.35),
	Color(0.55, 0.6, 0.85),
	Color(0.8, 0.4, 0.6),
]

## Scale constants (eyeball-tuned; ships are sim points, so their visual
## size is a presentation choice).
const SHIP_WORLD_UNITS_PER_PX := 1.33   # Mockingbird 45 px -> ~60 world units
const SHIP_MIN_SCREEN_SCALE := 0.5      # readability clamp when zoomed out
const STATION_SPAN_FACTOR := 1.6        # station sprite width ~= 1.6 * dock_radius
const BODY_SPRITE_PX := 500.0           # Classic body sprites are 500x500
const PLANET_KINDS := ["barren", "desert", "flowerforest", "forest",
	"gasgiant", "ice", "lava", "ocean", "terran", "tundra"]

## Parallax (restraint per docs/visuals.md: dim layers, no nebula soup).
const PARALLAX_FACTORS := [0.05, 0.12, 0.25]
const PARALLAX_ALPHA := 0.55

## Thruster plumes: the plume is the speedometer.
const PLUME_RAMP_PER_SEC := 6.0
const OTHER_SHIP_BURN_DELTA_V := 2.0    # snapshot |dv| that reads as a burn
const OTHER_SHIP_BURN_HOLD_MSEC := 400

## Set every frame by main.gd before queue_redraw().
var world: WorldData = null
var t: float = 0.0
var ships: Array[ShipState] = []
var own_ship_id: int = -1
var zoom: float = 1.0
var focus_pos: Vector2 = Vector2.ZERO
var own_undocked: bool = true
var own_throttle: float = 0.0

var _font: Font
var _lib: AssetLibrary = null
var _plume_tex: GradientTexture2D = null
var _star_tiles: Array[Texture2D] = []

var _body_sprites: Node2D
var _station_sprites: Node2D
var _ship_sprites: Node2D
var _suns: Node2D

## Per-ship plume intensity 0..1, ramped toward the throttle read.
var _plume_level: Dictionary = {}
## Per-ship burn estimation for OTHER ships: {id: {"v": Vector2, "until": int}}.
var _burn_state: Dictionary = {}
var _last_update_msec: int = 0


func _ready() -> void:
	_font = ThemeDB.fallback_font
	light_mask = 2  # the vector pass (incl. starfield) is never sun-lit
	_lib = AssetLibrary.load_all()
	for layer_name: String in ["small", "medium", "large"]:
		_star_tiles.append(_lib.star_layer(layer_name))
	_plume_tex = GradientTexture2D.new()
	_plume_tex.width = 8
	_plume_tex.height = 8
	_plume_tex.fill = GradientTexture2D.FILL_RADIAL
	_plume_tex.fill_from = Vector2(0.5, 0.5)
	_plume_tex.fill_to = Vector2(0.5, 1.0)
	var grad := Gradient.new()
	grad.set_color(0, Color(1.0, 0.89, 0.69, 0.95))  # GLOW_CORE warm
	grad.set_color(1, Color(1.0, 0.62, 0.30, 0.0))   # GLOW_MID -> transparent
	_plume_tex.gradient = grad
	for holder in ["_body_sprites", "_station_sprites", "_ship_sprites", "_suns"]:
		var node := Node2D.new()
		node.name = holder.trim_prefix("_")
		add_child(node)
		set(holder, node)


## Called by main.gd once per frame with everything needed to render.
func set_frame_data(
	p_world: WorldData,
	p_t: float,
	p_ships: Array[ShipState],
	p_own_ship_id: int,
	p_zoom: float,
	p_focus_pos: Vector2,
	p_own_undocked: bool,
	p_own_throttle: float = 0.0
) -> void:
	world = p_world
	t = p_t
	ships = p_ships
	own_ship_id = p_own_ship_id
	zoom = p_zoom
	focus_pos = p_focus_pos
	own_undocked = p_own_undocked
	own_throttle = p_own_throttle
	_update_sprites()
	queue_redraw()


func _world_to_screen(world_pos: Vector2, screen_center: Vector2, view_scale: float) -> Vector2:
	# World is y-up, screen is y-down: negate the relative y before scaling.
	var rel := world_pos - focus_pos
	return screen_center + Vector2(rel.x, -rel.y) * view_scale


# ------------------------------------------------------------ sprite pass --
func _update_sprites() -> void:
	if world == null:
		return
	var now := Time.get_ticks_msec()
	var delta := clampf((now - _last_update_msec) / 1000.0, 0.0, 0.1)
	_last_update_msec = now
	var view_scale := PIXELS_PER_UNIT * zoom
	var screen_center := get_viewport_rect().size * 0.5
	var touched_bodies := {}
	var touched_stations := {}
	var touched_ships := {}
	var touched_suns := {}
	_update_body_sprites(screen_center, view_scale, touched_bodies)
	_update_station_sprites(screen_center, view_scale, touched_stations)
	_update_ship_sprites(screen_center, view_scale, delta, touched_ships)
	_update_suns(touched_suns)
	_hide_untouched(_body_sprites, touched_bodies)
	_hide_untouched(_station_sprites, touched_stations)
	_hide_untouched(_ship_sprites, touched_ships)
	_hide_untouched(_suns, touched_suns)


## Reuse-or-create a child sprite keyed by name; anything not touched this
## frame is hidden (not freed — entity counts are small and stable).
func _pool_sprite(parent: Node2D, key: String, touched: Dictionary) -> Sprite2D:
	touched[key] = true
	var s: Sprite2D = parent.get_node_or_null(NodePath(key))
	if s == null:
		s = Sprite2D.new()
		s.name = key
		s.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		s.light_mask = 2
		parent.add_child(s)
	s.visible = true
	return s


func _hide_untouched(parent: Node2D, touched: Dictionary) -> void:
	for child in parent.get_children():
		if not touched.has(String(child.name)):
			child.visible = false


func _planet_kind(body_id: String) -> String:
	return PLANET_KINDS[abs(body_id.hash()) % PLANET_KINDS.size()]


func _update_body_sprites(screen_center: Vector2, view_scale: float, touched: Dictionary) -> void:
	for body in world.bodies:
		var tex := _lib.body("star_yellow" if body.kind == "star"
			else _planet_kind(body.id))
		if tex == null:
			continue
		var s := _pool_sprite(_body_sprites, "body_" + body.id, touched)
		if s.texture == null:
			s.texture = tex
		s.position = _world_to_screen(world.body_position(body.id, t),
			screen_center, view_scale)
		s.scale = Vector2.ONE * maxf(
			body.radius * 2.0 * view_scale / BODY_SPRITE_PX, 3.0 / BODY_SPRITE_PX)


func _station_archetype(station: WorldData.Station) -> String:
	return "ring_3berth_crane" if station.crane else "ring_1berth"


## World-units-per-texture-px for a station sprite, sized so the whole
## structure spans ~STATION_SPAN_FACTOR x dock_radius.
func _station_units_per_px(station: WorldData.Station, sset: AssetLibrary.SpriteSet) -> float:
	return STATION_SPAN_FACTOR * station.dock_radius / maxf(float(sset.px_size().x), 1.0)


func _update_station_sprites(screen_center: Vector2, view_scale: float, touched: Dictionary) -> void:
	# Docked ships park at berth anchors, in docking order per station.
	var docked_by_station: Dictionary = {}
	for ship in ships:
		if ship.is_docked():
			var list: Array = docked_by_station.get_or_add(ship.docked_at, [])
			list.append(ship)
	for station in world.stations:
		var sset := _lib.station(_station_archetype(station))
		if sset == null:
			continue
		var s := _pool_sprite(_station_sprites, "station_" + station.id, touched)
		if s.texture == null:
			s.texture = sset.texture
			s.material = sset.material
		var units_per_px := _station_units_per_px(station, sset)
		s.position = _world_to_screen(world.station_position(station.id, t),
			screen_center, view_scale)
		s.scale = Vector2.ONE * (units_per_px * view_scale)
		_update_parked_ships(s, station, sset,
			docked_by_station.get(station.id, []))


## Children of the station sprite live in station-texture-px space, so a
## parked ship's local scale converts ship px to station px.
func _update_parked_ships(station_sprite: Sprite2D, station: WorldData.Station,
		sset: AssetLibrary.SpriteSet, docked: Array) -> void:
	var berth_anchors := sset.anchors("berth")
	var units_per_px := _station_units_per_px(station, sset)
	var half := Vector2(sset.px_size()) * 0.5
	var used := {}
	for i in range(mini(docked.size(), berth_anchors.size())):
		var ship: ShipState = docked[i]
		used["parked_%d" % ship.id] = true
		_park_sprite(station_sprite, "parked_%d" % ship.id, "mockingbird",
			berth_anchors[i] - half, units_per_px)
	# Flavor: on the crane station, a workaday Longhorn holds the last berth
	# when no real ship does (DESIGN.md M3.5: Longhorn as parked traffic).
	if station.crane and docked.size() < berth_anchors.size():
		used["parked_longhorn"] = true
		_park_sprite(station_sprite, "parked_longhorn", "longhorn",
			berth_anchors[berth_anchors.size() - 1] - half, units_per_px)
	for child in station_sprite.get_children():
		child.visible = used.has(String(child.name))


func _park_sprite(parent: Sprite2D, key: String, kind: String,
		local_px: Vector2, station_units_per_px: float) -> void:
	var sset := _lib.ship(kind)
	if sset == null:
		return
	var s: Sprite2D = parent.get_node_or_null(NodePath(key))
	if s == null:
		s = Sprite2D.new()
		s.name = key
		s.texture = sset.texture
		s.material = sset.material
		s.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		s.light_mask = 1  # pipeline art: sun-lit
		parent.add_child(s)
	s.visible = true
	s.position = local_px
	s.scale = Vector2.ONE * (SHIP_WORLD_UNITS_PER_PX / station_units_per_px)


func _update_ship_sprites(screen_center: Vector2, view_scale: float,
		delta: float, touched: Dictionary) -> void:
	var sset := _lib.ship("mockingbird")  # every hull is a Mockingbird until M4
	if sset == null:
		return
	for ship in ships:
		if ship.is_docked():
			continue  # parked at a berth by the station pass
		var key := "ship_%d" % ship.id
		var s := _pool_sprite(_ship_sprites, key, touched)
		if s.texture == null:
			s.texture = sset.texture
			s.material = sset.material
			s.light_mask = 1
			_spawn_plumes(s, sset)
		s.position = _world_to_screen(ship.position(), screen_center, view_scale)
		s.rotation = -ship.heading + PI / 2
		s.scale = Vector2.ONE * maxf(SHIP_WORLD_UNITS_PER_PX * view_scale,
			SHIP_MIN_SCREEN_SCALE)
		_update_plumes(s, ship, delta)


func _spawn_plumes(ship_sprite: Sprite2D, sset: AssetLibrary.SpriteSet) -> void:
	var half := Vector2(sset.px_size()) * 0.5
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	for anchor in sset.anchors("nozzle"):
		var p := Sprite2D.new()
		p.name = "plume"
		p.texture = _plume_tex
		p.material = mat
		p.light_mask = 2  # emissive: never sun-lit
		p.position = anchor - half + Vector2(0, 1.0)
		p.offset = Vector2(0, 3.0)  # glow center trails the nozzle; scaling
		p.modulate.a = 0.0          # y stretches the plume aft (texture +y)
		ship_sprite.add_child(p)


func _update_plumes(ship_sprite: Sprite2D, ship: ShipState, delta: float) -> void:
	var throttle := own_throttle if ship.id == own_ship_id \
		else _estimate_throttle(ship)
	var level: float = move_toward(_plume_level.get(ship.id, 0.0),
		clampf(throttle, 0.0, 1.0), PLUME_RAMP_PER_SEC * delta)
	_plume_level[ship.id] = level
	var flicker := 1.0 + 0.08 * sin(Time.get_ticks_msec() * 0.03 * TAU)
	for child in ship_sprite.get_children():
		if child is Sprite2D and String(child.name).begins_with("plume"):
			child.modulate.a = level
			child.scale = Vector2(0.5 + 0.4 * level,
				(0.2 + 2.8 * level) * flicker)


## Burn detection for ships we don't control: a snapshot-to-snapshot velocity
## jump reads as a burn and holds the plume briefly (snapshots are ~15 Hz).
func _estimate_throttle(ship: ShipState) -> float:
	var now := Time.get_ticks_msec()
	var state: Dictionary = _burn_state.get_or_add(ship.id,
		{"v": ship.velocity(), "until": 0})
	if (ship.velocity() - state["v"]).length() > OTHER_SHIP_BURN_DELTA_V:
		state["until"] = now + OTHER_SHIP_BURN_HOLD_MSEC
	state["v"] = ship.velocity()
	return 1.0 if now < int(state["until"]) else 0.0


func _update_suns(touched: Dictionary) -> void:
	for body in world.bodies:
		if body.kind != "star":
			continue
		var key := "sun_" + body.id
		touched[key] = true
		var sun: DirectionalLight2D = _suns.get_node_or_null(NodePath(key))
		if sun == null:
			sun = DirectionalLight2D.new()
			sun.name = key
			sun.height = 0.55
			sun.blend_mode = Light2D.BLEND_MODE_ADD
			sun.range_item_cull_mask = 1  # lights pipeline sprites only
			_suns.add_child(sun)
		sun.visible = true
		var dir_world := focus_pos - world.body_position(body.id, t)
		if dir_world.length_squared() < 1.0:
			dir_world = Vector2(1, 0)
		# Screen-space travel direction (y flip); the light's base travel
		# direction is +y (toy-scene convention: rotation -45 = lower-right).
		var travel := Vector2(dir_world.x, -dir_world.y).normalized()
		sun.rotation = travel.angle() - PI / 2


# ------------------------------------------------------------ vector pass --
func _draw() -> void:
	if world == null:
		return
	var view_scale := PIXELS_PER_UNIT * zoom
	var screen_center := get_viewport_rect().size * 0.5

	_draw_starfield(view_scale)
	_draw_bodies(screen_center, view_scale)
	_draw_stations(screen_center, view_scale)
	_draw_ships(screen_center, view_scale)


## Three tiled Classic star layers, drifting against flight direction at
## different depths. Drawn in the vector pass so it sits under everything
## (children render above the parent's own drawing).
func _draw_starfield(view_scale: float) -> void:
	var vp := get_viewport_rect().size
	for i in _star_tiles.size():
		var tex := _star_tiles[i]
		if tex == null:
			continue
		var f: float = PARALLAX_FACTORS[i]
		var tile := tex.get_size()
		var off := Vector2(-focus_pos.x, focus_pos.y) * view_scale * f
		off = Vector2(fposmod(off.x, tile.x), fposmod(off.y, tile.y)) - tile
		var y := off.y
		while y < vp.y:
			var x := off.x
			while x < vp.x:
				draw_texture(tex, Vector2(x, y), Color(1, 1, 1, PARALLAX_ALPHA))
				x += tile.x
			y += tile.y


func _draw_bodies(screen_center: Vector2, view_scale: float) -> void:
	var planet_index := 0
	for body in world.bodies:
		# Only planets have an orbit (the star sits fixed at the origin with
		# orbit == null): draw the planet's orbit path around its parent.
		if body.orbit != null:
			var parent_world_pos := Vector2.ZERO
			if body.parent_id != "":
				parent_world_pos = world.body_position(body.parent_id, t)
			var orbit_screen_pos := _world_to_screen(parent_world_pos, screen_center, view_scale)
			var orbit_radius_px := body.orbit.radius * view_scale
			if orbit_radius_px > 1.0:
				draw_arc(orbit_screen_pos, orbit_radius_px, 0.0, TAU, 96, ORBIT_PATH_COLOR, 1.0, true)

		# Fallback discs only when the sprite pass has nothing for this body.
		var kind_id := "star_yellow" if body.kind == "star" else _planet_kind(body.id)
		if _lib.body(kind_id) == null:
			var screen_pos := _world_to_screen(world.body_position(body.id, t), screen_center, view_scale)
			var radius_px := maxf(body.radius * view_scale, 1.5)
			var color: Color
			if body.kind == "star":
				color = STAR_COLOR
			else:
				color = PLANET_PALETTE[planet_index % PLANET_PALETTE.size()]
				planet_index += 1
			draw_circle(screen_pos, radius_px, color)


func _draw_stations(screen_center: Vector2, view_scale: float) -> void:
	for station in world.stations:
		var pos := world.station_position(station.id, t)
		var screen_pos := _world_to_screen(pos, screen_center, view_scale)

		if own_undocked:
			var dock_radius_px := station.dock_radius * view_scale
			if dock_radius_px > 1.0:
				draw_arc(screen_pos, dock_radius_px, 0.0, TAU, 64, DOCK_RING_COLOR, 1.0, true)

		if _lib.station(_station_archetype(station)) == null:
			var half := STATION_MARKER_SIZE
			var diamond := PackedVector2Array([
				screen_pos + Vector2(0, -half),
				screen_pos + Vector2(half, 0),
				screen_pos + Vector2(0, half),
				screen_pos + Vector2(-half, 0),
			])
			draw_colored_polygon(diamond, STATION_COLOR)

		if _font != null:
			draw_string(
				_font, screen_pos + Vector2(STATION_MARKER_SIZE + 4.0, 4.0), station.name,
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, STATION_LABEL_COLOR)


func _draw_ships(screen_center: Vector2, view_scale: float) -> void:
	var have_sprites := _lib.ship("mockingbird") != null
	for ship in ships:
		if ship.is_docked() and have_sprites:
			continue  # parked at a berth by the station sprite pass
		var screen_pos := _world_to_screen(ship.position(), screen_center, view_scale)
		var is_own := ship.id == own_ship_id
		if not have_sprites:
			# World heading is y-up counter-clockwise; screen is y-down, so
			# negate the angle when building the screen-space direction.
			var screen_angle := -ship.heading
			var color := OWN_SHIP_COLOR if is_own else OTHER_SHIP_COLOR
			_draw_ship_triangle(screen_pos, screen_angle, SHIP_SIZE, color)
		if not is_own and _font != null:
			draw_string(
				_font, screen_pos + Vector2(SHIP_SIZE + 3.0, 4.0), str(ship.id),
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, OTHER_SHIP_LABEL_COLOR)


func _draw_ship_triangle(pos: Vector2, angle: float, size: float, color: Color) -> void:
	var local_points := [
		Vector2(size, 0.0),
		Vector2(-size * 0.6, size * 0.55),
		Vector2(-size * 0.6, -size * 0.55),
	]
	var points := PackedVector2Array()
	for p: Vector2 in local_points:
		points.append(pos + p.rotated(angle))
	draw_colored_polygon(points, color)
