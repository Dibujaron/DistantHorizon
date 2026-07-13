extends Node2D
class_name WorldView
## Draws the world doc's rails (star, planets, orbit paths, stations) and the
## current ships, in a viewport centered on a supplied focus point (normally
## the local player's own ship) with adjustable zoom.
##
## Rail math mirrors `world.gleam` / `harness/test_m1_flight.py`'s
## `station_rail_position` exactly:
##   angle(t) = phase * TAU + TAU * t / period_s
##   position(t) = parent_position(t) + radius * (cos(angle), sin(angle))
## Parents chain station -> planet -> star; the star (orbit null) is fixed
## at the origin.

const PIXELS_PER_UNIT := 1.0

const STAR_COLOR := Color(1.0, 0.78, 0.35)
const ORBIT_PATH_COLOR := Color(1.0, 1.0, 1.0, 0.12)
const STATION_COLOR := Color(0.6, 0.95, 0.7)
const STATION_LABEL_COLOR := Color(0.75, 0.95, 0.8, 0.9)
const DOCK_RING_COLOR := Color(0.6, 0.95, 0.7, 0.35)
const OWN_SHIP_COLOR := Color(0.55, 0.85, 1.0)
const OTHER_SHIP_COLOR := Color(0.55, 0.85, 1.0, 0.45)
const OTHER_SHIP_LABEL_COLOR := Color(0.8, 0.8, 0.85, 0.7)
const PLANET_PALETTE := [
	Color(0.45, 0.7, 0.45),
	Color(0.8, 0.55, 0.35),
	Color(0.55, 0.6, 0.85),
	Color(0.8, 0.4, 0.6),
]

const OWN_SHIP_SIZE := 10.0
const OTHER_SHIP_SIZE := 6.0
const STATION_MARKER_SIZE := 6.0
const FONT_SIZE := 13

## Set every frame by main.gd before queue_redraw().
var world: Dictionary = {}
var t: float = 0.0
var ships: Array = []
var own_ship_id: int = -1
var zoom: float = 1.0
var focus_pos: Vector2 = Vector2.ZERO
var own_undocked: bool = true

var _font: Font

func _ready() -> void:
	_font = ThemeDB.fallback_font

## Called by main.gd once per frame with everything needed to render.
func set_frame_data(
	p_world: Dictionary,
	p_t: float,
	p_ships: Array,
	p_own_ship_id: int,
	p_zoom: float,
	p_focus_pos: Vector2,
	p_own_undocked: bool
) -> void:
	world = p_world
	t = p_t
	ships = p_ships
	own_ship_id = p_own_ship_id
	zoom = p_zoom
	focus_pos = p_focus_pos
	own_undocked = p_own_undocked
	queue_redraw()

func _draw() -> void:
	if world.is_empty():
		return
	var view_scale := PIXELS_PER_UNIT * zoom
	var screen_center := get_viewport_rect().size * 0.5

	_draw_bodies(screen_center, view_scale)
	_draw_stations(screen_center, view_scale)
	_draw_ships(screen_center, view_scale)

func _world_to_screen(world_pos: Vector2, screen_center: Vector2, view_scale: float) -> Vector2:
	# World is y-up, screen is y-down: negate the relative y before scaling.
	var rel := world_pos - focus_pos
	return screen_center + Vector2(rel.x, -rel.y) * view_scale

func _draw_bodies(screen_center: Vector2, view_scale: float) -> void:
	var bodies: Array = world.get("bodies", [])
	var planet_index := 0
	for body: Dictionary in bodies:
		var parent_pos := _body_position(str(body.get("id")), t)
		var orbit: Variant = body.get("orbit")
		if orbit is Dictionary:
			var parent_id: Variant = body.get("parent")
			var parent_world_pos := Vector2.ZERO
			if parent_id != null:
				parent_world_pos = _body_position(str(parent_id), t)
			var orbit_screen_pos := _world_to_screen(parent_world_pos, screen_center, view_scale)
			var orbit_radius_px := float(orbit["radius"]) * view_scale
			if orbit_radius_px > 1.0:
				draw_arc(orbit_screen_pos, orbit_radius_px, 0.0, TAU, 96, ORBIT_PATH_COLOR, 1.0, true)

		var screen_pos := _world_to_screen(parent_pos, screen_center, view_scale)
		var radius_px := maxf(float(body.get("radius", 0.0)) * view_scale, 1.5)
		var color: Color
		if str(body.get("kind")) == "star":
			color = STAR_COLOR
		else:
			color = PLANET_PALETTE[planet_index % PLANET_PALETTE.size()]
			planet_index += 1
		draw_circle(screen_pos, radius_px, color)

func _draw_stations(screen_center: Vector2, view_scale: float) -> void:
	var stations: Array = world.get("stations", [])
	for station: Dictionary in stations:
		var pos := station_position_at(world, str(station.get("id")), t)
		var screen_pos := _world_to_screen(pos, screen_center, view_scale)

		if own_undocked:
			var dock_radius_px := float(station.get("dock_radius", 0.0)) * view_scale
			if dock_radius_px > 1.0:
				draw_arc(screen_pos, dock_radius_px, 0.0, TAU, 64, DOCK_RING_COLOR, 1.0, true)

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
				_font, screen_pos + Vector2(half + 4.0, 4.0), str(station.get("name", "")),
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, STATION_LABEL_COLOR)

func _draw_ships(screen_center: Vector2, view_scale: float) -> void:
	for ship: Dictionary in ships:
		var world_pos := Vector2(float(ship["x"]), float(ship["y"]))
		var screen_pos := _world_to_screen(world_pos, screen_center, view_scale)
		var heading := float(ship.get("heading", 0.0))
		# World heading is y-up counter-clockwise; screen is y-down, so
		# negate the angle when building the screen-space direction.
		var screen_angle := -heading
		var is_own := int(ship.get("id", -1)) == own_ship_id
		var size := OWN_SHIP_SIZE if is_own else OTHER_SHIP_SIZE
		var color := OWN_SHIP_COLOR if is_own else OTHER_SHIP_COLOR
		_draw_ship_triangle(screen_pos, screen_angle, size, color)
		if not is_own and _font != null:
			draw_string(
				_font, screen_pos + Vector2(size + 3.0, 4.0), str(ship.get("id", "")),
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

func _body_position(body_id: String, at_t: float) -> Vector2:
	return body_position_at(world, body_id, at_t)

## Rail position of a body (star or planet) at sim time `at_t`, chaining
## through its parent. Matches `world.body_position` in world.gleam.
static func body_position_at(p_world: Dictionary, body_id: String, at_t: float) -> Vector2:
	var body: Variant = _find_body(p_world, body_id)
	if body == null:
		return Vector2.ZERO
	var orbit: Variant = body.get("orbit")
	if not (orbit is Dictionary):
		return Vector2.ZERO
	var parent_id: Variant = body.get("parent")
	var parent_pos := Vector2.ZERO
	if parent_id != null:
		parent_pos = body_position_at(p_world, str(parent_id), at_t)
	return _orbit_position(parent_pos, orbit, at_t)

## Rail position of a station at sim time `at_t`, chaining through its
## parent body. Matches `world.station_position` in world.gleam.
static func station_position_at(p_world: Dictionary, station_id: String, at_t: float) -> Vector2:
	var station: Variant = _find_station(p_world, station_id)
	if station == null:
		return Vector2.ZERO
	var parent_pos := body_position_at(p_world, str(station.get("parent")), at_t)
	return _orbit_position(parent_pos, station["orbit"], at_t)

static func _orbit_position(parent_pos: Vector2, orbit: Dictionary, at_t: float) -> Vector2:
	var angle: float = float(orbit["phase"]) * TAU + TAU * at_t / float(orbit["period_s"])
	return parent_pos + Vector2(cos(angle), sin(angle)) * float(orbit["radius"])

static func _find_body(p_world: Dictionary, body_id: String) -> Variant:
	for body: Dictionary in p_world.get("bodies", []):
		if str(body.get("id")) == body_id:
			return body
	return null

static func _find_station(p_world: Dictionary, station_id: String) -> Variant:
	for station: Dictionary in p_world.get("stations", []):
		if str(station.get("id")) == station_id:
			return station
	return null
