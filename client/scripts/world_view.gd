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

const FONT_SIZE := 16  # Jersey 15 diegetic slot (UiTheme)

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

## Scale canon (iteration 4): EVERY hull sprite shares one world-units-per-
## texture-px so a ship parked on a station reads at true relative size, while
## bodies render at their TRUE physical radius (see _update_body_sprites).
## SHIP_WORLD_UNITS_PER_PX is the shared base; the two *_RENDER_SCALE knobs
## shrink free-flying ships / stations relative to planets (#15) and are the
## values to tune. Both are folded into the matched-zoom math (matched_zoom_*)
## so THE WINDOW's docked/aboard transition stays seamless.
const SHIP_WORLD_UNITS_PER_PX := 1.33   # Mockingbird 45 px -> ~60 world units (base)
## #15 tunables — apparent size of free-flying ships / stations vs planets.
## 1.0 == the old (too-large) size; smaller reads smaller against planetary
## bodies (Meridian's radius is 600 world units, ~1200 across, for reference).
## Set the two equal to remove the slight size change as a ship undocks.
const SHIP_RENDER_SCALE := 0.4          # flying Mockingbird ~24 world units
const STATION_RENDER_SCALE := 0.6       # Solis Ring ~30 world units (kept mild)
const BODY_SPRITE_PX := 500.0           # Classic body sprites are 500x500
## #17 — a ship/station whose sprite would draw shorter than this many screen
## px (zoomed far out) is hidden and marked with a fixed pip instead.
const SHIP_PIP_SCREEN_PX := 6.0
const STATION_PIP_SCREEN_PX := 6.0
const SHIP_PIP_RADIUS := 2.0            # ship pip marker radius, screen px
const PLANET_KINDS := ["barren", "desert", "flowerforest", "forest",
	"gasgiant", "ice", "lava", "ocean", "terran", "tundra"]

## Parallax (restraint per docs/visuals.md: dim layers, no nebula soup).
const PARALLAX_FACTORS := [0.05, 0.12, 0.25]
const PARALLAX_ALPHA := 0.55

## Thruster plumes: the plume is the speedometer.
const PLUME_RAMP_PER_SEC := 6.0
const OTHER_SHIP_BURN_DELTA_V := 2.0    # snapshot |dv| that reads as a burn
const OTHER_SHIP_BURN_HOLD_MSEC := 400

## #10 — heading is snapped on each snapshot (ShipState carries no angular
## velocity), so raw rotation steps at the ~15 Hz snapshot rate. We ease the
## rendered heading toward the target with lerp_angle every frame instead.
## Higher == snappier / less lag, lower == smoother. Tunable.
const HEADING_SMOOTH_RATE := 14.0

## #12 — engine exhaust persists in WORLD space (not parented to the hull), so
## turning leaves a curved trailing plume. Motes are emitted from the tail,
## carried on the ship's velocity plus an aft kick, and drawn in the vector
## pass (_draw_plume_trails) transformed world->screen every frame. Tunables:
const PLUME_EMIT_PER_SEC := 32.0        # motes/sec at full throttle
const PLUME_LIFETIME := 1.1             # seconds a mote lives
const PLUME_EXHAUST_SPEED := 60.0       # aft ejection speed, world units/sec
const PLUME_SPREAD := 10.0              # lateral jitter, world units/sec
const PLUME_MOTE_WORLD := 6.0           # mote radius at birth, world units
const PLUME_MOTE_GROWTH := 3.0          # world units added over its life

## #18 — projected-trajectory pips: dead-reckon the player ship forward along
## its current velocity (straight-line coast, matching the client's own
## extrapolation) and drop evenly spaced pips. Tunables:
const TRAJECTORY_LOOKAHEAD_SEC := 6.0   # how far ahead to predict
const TRAJECTORY_PIP_COUNT := 8         # number of pips along the path
const TRAJECTORY_PIP_RADIUS := 1.6      # pip radius, screen px
const TRAJECTORY_PIP_COLOR := Color(0.55, 0.85, 1.0, 0.5)
const TRAJECTORY_MIN_SPEED := 1.0       # below this |v|, no path to show

## Set every frame by main.gd before queue_redraw().
var world: WorldData = null
var t: float = 0.0
var ships: Array[ShipState] = []
var own_ship_id: int = -1
var zoom: float = 1.0
var focus_pos: Vector2 = Vector2.ZERO
var own_undocked: bool = true
var own_throttle: float = 0.0
## THE WINDOW (M3.5 it. 3): while the interior is up, this view is the
## dimmed space outside at the interior's matched zoom. The hull you're
## inside is drawn by InteriorView as a to-scale backdrop instead, so its
## world sprite (and all labels/rings/orbits — wrong scale) is suppressed.
var interior_mode: bool = false
var suppress_station_id: String = ""
var suppress_ship_id: int = -1

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
## #10 smoothed per-ship world heading (radians), eased toward the snapshot.
var _render_heading: Dictionary = {}
## #12 per-ship world-space exhaust motes: {id: Array[{p, v, age, level}]},
## plus a fractional emission carry so sub-frame emit counts aren't lost.
var _plume_trails: Dictionary = {}
var _plume_emit_carry: Dictionary = {}


func _ready() -> void:
	_font = UiTheme.pixel_font()  # in-world text speaks the diegetic slot
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
	p_own_throttle: float = 0.0,
	p_interior_mode: bool = false,
	p_suppress_station_id: String = "",
	p_suppress_ship_id: int = -1
) -> void:
	world = p_world
	t = p_t
	ships = p_ships
	own_ship_id = p_own_ship_id
	zoom = p_zoom
	focus_pos = p_focus_pos
	own_undocked = p_own_undocked
	own_throttle = p_own_throttle
	interior_mode = p_interior_mode
	suppress_station_id = p_suppress_station_id
	suppress_ship_id = p_suppress_ship_id
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
	_advance_plume_trails(delta)  # #12: age world-space exhaust before emitting
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


## World-units-per-texture-px for a station sprite: the shared scale canon
## (same as ships) so moored traffic reads at true relative size.
func _station_units_per_px(_station: WorldData.Station, _sset: AssetLibrary.SpriteSet) -> float:
	return SHIP_WORLD_UNITS_PER_PX


## The zoom at which this station's sprite renders at the interior's tile
## scale (its 1.5-px tiles under 64-px interior tiles) — THE WINDOW's
## matched zoom while docked. `fallback` when the station/asset is unknown.
func matched_zoom_station(station_id: String, fallback: float) -> float:
	if world == null:
		return fallback
	for station in world.stations:
		if station.id != station_id:
			continue
		var sset := _lib.station(_station_archetype(station))
		if sset == null or not sset.has_interior_fit():
			return fallback
		# STATION_RENDER_SCALE (#15) shrinks the exterior sprite, so the matched
		# zoom must compensate to keep THE WINDOW's crossfade seamless.
		return InteriorView.TILE_PIXELS / (sset.px_per_tile() \
			* SHIP_WORLD_UNITS_PER_PX * STATION_RENDER_SCALE * PIXELS_PER_UNIT)
	return fallback


## Ship-scale matched zoom (aboard a flying hull).
func matched_zoom_ship(fallback: float) -> float:
	var sset := _lib.ship("mockingbird")
	if sset == null or not sset.has_interior_fit():
		return fallback
	# SHIP_RENDER_SCALE (#15) shrinks the flying hull sprite, so the matched
	# zoom must compensate to keep THE WINDOW's crossfade seamless.
	return InteriorView.TILE_PIXELS / (sset.px_per_tile() \
		* SHIP_WORLD_UNITS_PER_PX * SHIP_RENDER_SCALE * PIXELS_PER_UNIT)


## True when a hull sprite of `sset` would draw sub-pixel at `view_scale` and
## should be replaced by a pip (#17).
func _ship_is_pip(sset: AssetLibrary.SpriteSet, view_scale: float) -> bool:
	var px := Vector2(sset.px_size())
	var s := SHIP_WORLD_UNITS_PER_PX * SHIP_RENDER_SCALE * view_scale
	return maxf(px.x, px.y) * s < SHIP_PIP_SCREEN_PX


## True when a station sprite of `sset` would draw sub-pixel at `view_scale`.
func _station_is_pip(sset: AssetLibrary.SpriteSet, view_scale: float) -> bool:
	var px := Vector2(sset.px_size())
	var s := SHIP_WORLD_UNITS_PER_PX * STATION_RENDER_SCALE * view_scale
	return maxf(px.x, px.y) * s < STATION_PIP_SCREEN_PX


func _update_station_sprites(screen_center: Vector2, view_scale: float, touched: Dictionary) -> void:
	# Docked ships park at berth anchors, in docking order per station.
	var docked_by_station: Dictionary = {}
	for ship in ships:
		if ship.is_docked():
			var list: Array = docked_by_station.get_or_add(ship.docked_at, [])
			list.append(ship)
	for station in world.stations:
		if interior_mode and station.id == suppress_station_id:
			continue  # InteriorView draws this hull as the tile backdrop
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
		if _station_is_pip(sset, view_scale):
			s.visible = false  # #17: _draw_stations marks it with a diamond pip
			continue           # (hides parked-ship children with it)
		# #15: STATION_RENDER_SCALE shrinks the station (and its parked ships,
		# which are children) relative to planets.
		s.scale = Vector2.ONE * (units_per_px * STATION_RENDER_SCALE * view_scale)
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
	# Moored ships lie side-on: 90 CCW, nose west, port flank to the bar.
	s.rotation = -PI / 2
	s.scale = Vector2.ONE * (SHIP_WORLD_UNITS_PER_PX / station_units_per_px)


func _update_ship_sprites(screen_center: Vector2, view_scale: float,
		delta: float, touched: Dictionary) -> void:
	var sset := _lib.ship("mockingbird")  # every hull is a Mockingbird until M4
	if sset == null:
		return
	var is_pip := _ship_is_pip(sset, view_scale)
	for ship in ships:
		if ship.is_docked():
			continue  # parked at a berth by the station pass
		if interior_mode and ship.id == suppress_ship_id:
			continue  # InteriorView draws this hull as the tile backdrop
		# #10: ease the rendered heading toward the snapshot's target — the
		# wire carries no angular velocity, so a raw assign steps at ~15 Hz.
		var target: float = ship.heading
		var cur: float = _render_heading.get(ship.id, target)
		cur = lerp_angle(cur, target, clampf(HEADING_SMOOTH_RATE * delta, 0.0, 1.0))
		_render_heading[ship.id] = cur
		# #12: exhaust is emitted into world space from the tail this frame.
		_emit_plume_trail(ship, cur, delta)
		var key := "ship_%d" % ship.id
		var s := _pool_sprite(_ship_sprites, key, touched)
		if s.texture == null:
			s.texture = sset.texture
			s.material = sset.material
			s.light_mask = 1
		if is_pip:
			s.visible = false  # #17: _draw_ships marks it with a pip instead
			continue
		s.position = _world_to_screen(ship.position(), screen_center, view_scale)
		s.rotation = -cur + PI / 2
		# #15/#17: SHIP_RENDER_SCALE shrinks the hull vs planets; the scale now
		# follows the zoom all the way down (no floor) into the pip regime.
		s.scale = Vector2.ONE * (SHIP_WORLD_UNITS_PER_PX * SHIP_RENDER_SCALE * view_scale)


## #12 — advance and expire every ship's world-space exhaust motes. Runs each
## frame before emission (including for ships that just despawned, so their
## trails still age out) — keys() is a copy, so erasing mid-loop is safe.
func _advance_plume_trails(delta: float) -> void:
	for id: int in _plume_trails.keys():
		var motes: Array = _plume_trails[id]
		var kept: Array = []
		for m: Dictionary in motes:
			m["age"] = float(m["age"]) + delta
			if m["age"] < PLUME_LIFETIME:
				m["p"] = m["p"] + m["v"] * delta
				kept.append(m)
		if kept.is_empty():
			_plume_trails.erase(id)
		else:
			_plume_trails[id] = kept


## #12 — spit new exhaust motes from `ship`'s tail into world space, scaled by
## the ramped throttle level. `heading` is the smoothed world heading so the
## plume points where the hull visually points.
func _emit_plume_trail(ship: ShipState, heading: float, delta: float) -> void:
	var throttle := own_throttle if ship.id == own_ship_id \
		else _estimate_throttle(ship)
	var level: float = move_toward(_plume_level.get(ship.id, 0.0),
		clampf(throttle, 0.0, 1.0), PLUME_RAMP_PER_SEC * delta)
	_plume_level[ship.id] = level
	if level <= 0.02:
		return
	# Fractional accumulator so low throttle still trickles whole motes.
	var carry: float = float(_plume_emit_carry.get(ship.id, 0.0)) \
		+ level * PLUME_EMIT_PER_SEC * delta
	var n := int(carry)
	_plume_emit_carry[ship.id] = carry - n
	if n <= 0:
		return
	# Aft is opposite the nose; nose points along `heading` (world y-up).
	var aft := -Vector2(cos(heading), sin(heading))
	var lateral := Vector2(-aft.y, aft.x)
	var tail := ship.position() + aft * (PLUME_MOTE_WORLD * 1.5)
	var motes: Array = _plume_trails.get_or_add(ship.id, [])
	for _i in n:
		var kick := aft * PLUME_EXHAUST_SPEED \
			+ lateral * randf_range(-PLUME_SPREAD, PLUME_SPREAD)
		motes.append({"p": tail, "v": ship.velocity() + kick,
			"age": 0.0, "level": level})


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
	_draw_plume_trails(screen_center, view_scale)  # #12: world-space exhaust
	_draw_bodies(screen_center, view_scale)
	_draw_stations(screen_center, view_scale)
	_draw_ships(screen_center, view_scale)
	_draw_trajectory(screen_center, view_scale)    # #18: predicted path pips


## #12 — draw each world-space exhaust mote transformed to screen this frame,
## so already-emitted gas stays put in the world and a turn leaves a curved
## trailing plume. The motes sit under the ship sprites (children draw above
## the parent's _draw), so the plume pours out from behind the hull.
func _draw_plume_trails(screen_center: Vector2, view_scale: float) -> void:
	if _plume_tex == null:
		return
	for id: int in _plume_trails:
		for m: Dictionary in _plume_trails[id]:
			var life_frac: float = clampf(float(m["age"]) / PLUME_LIFETIME, 0.0, 1.0)
			var r: float = (PLUME_MOTE_WORLD + PLUME_MOTE_GROWTH * life_frac) * view_scale
			if r < 0.5:
				continue
			var center := _world_to_screen(m["p"], screen_center, view_scale)
			var a: float = (1.0 - life_frac) * 0.7 * float(m.get("level", 1.0))
			draw_texture_rect(_plume_tex,
				Rect2(center - Vector2(r, r), Vector2(r, r) * 2.0),
				false, Color(1.0, 0.85, 0.6, a))


## #18 — evenly spaced pips along the player ship's dead-reckoned path
## (straight-line coast on current velocity, matching the client's own
## extrapolation). Chart furniture — suppressed through THE WINDOW.
func _draw_trajectory(screen_center: Vector2, view_scale: float) -> void:
	if interior_mode or own_ship_id < 0:
		return
	var own: ShipState = null
	for ship in ships:
		if ship.id == own_ship_id:
			own = ship
			break
	if own == null or own.is_docked():
		return
	var vel := own.velocity()
	if vel.length() < TRAJECTORY_MIN_SPEED:
		return
	var origin := own.position()
	for i in range(1, TRAJECTORY_PIP_COUNT + 1):
		var t_ahead := TRAJECTORY_LOOKAHEAD_SEC * float(i) / float(TRAJECTORY_PIP_COUNT)
		var screen_pt := _world_to_screen(origin + vel * t_ahead, screen_center, view_scale)
		var c := TRAJECTORY_PIP_COLOR
		c.a *= 1.0 - 0.6 * float(i - 1) / float(TRAJECTORY_PIP_COUNT)
		draw_circle(screen_pt, TRAJECTORY_PIP_RADIUS, c)


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
		# Orbit paths are chart furniture — hidden through THE WINDOW.
		if body.orbit != null and not interior_mode:
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
	if interior_mode:
		return  # rings/labels are chart furniture, wrong scale in THE WINDOW
	for station in world.stations:
		var pos := world.station_position(station.id, t)
		var screen_pos := _world_to_screen(pos, screen_center, view_scale)

		if own_undocked:
			var dock_radius_px := station.dock_radius * view_scale
			if dock_radius_px > 1.0:
				draw_arc(screen_pos, dock_radius_px, 0.0, TAU, 64, DOCK_RING_COLOR, 1.0, true)

		# Diamond marker when there is no sprite, OR (#17) when zoomed so far
		# out that the station sprite went sub-pixel and the sprite pass hid it.
		var sset := _lib.station(_station_archetype(station))
		if sset == null or _station_is_pip(sset, view_scale):
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
	var sset := _lib.ship("mockingbird")
	var have_sprites := sset != null
	# #17: past a zoom-out threshold the hull sprite went sub-pixel and the
	# sprite pass hid it; render every flying ship as a fixed pip instead.
	var pip := have_sprites and _ship_is_pip(sset, view_scale)
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
		elif pip:
			draw_circle(screen_pos, SHIP_PIP_RADIUS,
				OWN_SHIP_COLOR if is_own else OTHER_SHIP_COLOR)
		if not is_own and _font != null and not interior_mode:
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
