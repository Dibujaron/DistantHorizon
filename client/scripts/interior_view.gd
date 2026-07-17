extends Node2D
class_name InteriorView
## Draws the ship's interior deck plan (floor tiles, room tints/labels,
## consoles) and the characters aboard, sibling of world_view.gd.
##
## Unlike WorldView there's no follow/zoom camera: the M2 sparrow class
## (10x6 tiles) always fits comfortably on screen at TILE_PIXELS scale, so
## the whole grid is simply centered in the viewport.
##
## Character positions arrive from `interior` messages (network_client.gd)
## at 15 Hz; main.gd extrapolates between them the same way it dead-reckons
## ship snapshots, using velocity estimated client-side (the wire message
## carries position only, no vx/vy).

const TILE_PIXELS := 64.0

const FLOOR_COLOR := Color(0.16, 0.17, 0.22)
const VOID_COLOR := Color(0.03, 0.04, 0.08)
const GRID_LINE_COLOR := Color(1.0, 1.0, 1.0, 0.05)
const ROOM_LABEL_COLOR := Color(0.85, 0.85, 0.9, 0.8)
const CONSOLE_HELM_COLOR := Color(0.55, 0.85, 1.0)
const CONSOLE_CARGO_COLOR := Color(0.9, 0.75, 0.35)
const CONSOLE_DEFAULT_COLOR := Color(0.8, 0.8, 0.85)
const OWN_CHARACTER_COLOR := Color(0.55, 0.85, 1.0)
const OTHER_CHARACTER_COLOR := Color(0.85, 0.85, 0.9, 0.7)
const CHARACTER_LABEL_COLOR := Color(0.8, 0.8, 0.85, 0.8)
const CHARACTER_RADIUS_TILES := 0.3
const FONT_SIZE := 13

const ROOM_TINT_PALETTE := [
	Color(0.25, 0.35, 0.45, 0.35),
	Color(0.35, 0.3, 0.45, 0.35),
	Color(0.3, 0.4, 0.3, 0.35),
	Color(0.45, 0.35, 0.3, 0.35),
]

## Docking collar: the tile beyond the airlock, drawn while something is
## connected on the other side (the station concourse seen from a docked
## ship's deck, or the docked ship seen from the concourse).
const DOCK_COLLAR_FILL := Color(0.6, 0.95, 0.7, 0.15)
const DOCK_COLLAR_EDGE := Color(0.6, 0.95, 0.7, 0.7)
const DOCK_COLLAR_LABEL := Color(0.75, 0.95, 0.8, 0.9)

## Set every frame by main.gd before queue_redraw().
var ship_class: ShipClassData = null
var characters: Array[CharacterState] = []
var own_character_id: int = -1
var dock_label: String = ""

var _font: Font

func _ready() -> void:
	_font = ThemeDB.fallback_font

## Called by main.gd once per frame with everything needed to render.
## `p_dock_label` names what the plan's airlock is connected to ("" = draw
## no docking collar).
func set_frame_data(
	p_ship_class: ShipClassData,
	p_characters: Array[CharacterState],
	p_own_character_id: int,
	p_dock_label: String = ""
) -> void:
	ship_class = p_ship_class
	characters = p_characters
	own_character_id = p_own_character_id
	dock_label = p_dock_label
	queue_redraw()

func _draw() -> void:
	if ship_class == null:
		return
	var origin := _grid_origin()
	_draw_floor(origin)
	_draw_dock_link(origin)
	_draw_room_labels(origin)
	_draw_consoles(origin)
	_draw_characters(origin)

## Top-left screen pixel of tile (0,0): centers the whole grid in the
## viewport (the M2 deck always fits on screen, so no follow camera).
func _grid_origin() -> Vector2:
	var viewport_size := get_viewport_rect().size
	var grid_size_px := Vector2(ship_class.grid_width, ship_class.grid_height) * TILE_PIXELS
	return (viewport_size - grid_size_px) * 0.5

func _tile_to_screen(tile: Vector2, origin: Vector2) -> Vector2:
	return origin + tile * TILE_PIXELS

func _draw_floor(origin: Vector2) -> void:
	for ty in ship_class.grid_height:
		for tx in ship_class.grid_width:
			var rect := Rect2(_tile_to_screen(Vector2(tx, ty), origin), Vector2(TILE_PIXELS, TILE_PIXELS))
			if ship_class.is_walkable(tx, ty):
				var color := FLOOR_COLOR
				var room := ship_class.room_at(tx, ty)
				if room != null:
					var tint_index := ship_class.rooms.find(room) % ROOM_TINT_PALETTE.size()
					color = FLOOR_COLOR.blend(ROOM_TINT_PALETTE[tint_index])
				draw_rect(rect, color, true)
			else:
				draw_rect(rect, VOID_COLOR, true)
			draw_rect(rect, GRID_LINE_COLOR, false, 1.0)

## The direction the airlock (spawn tile) opens outward: its first
## non-walkable neighbor, preferring down (every bundled plan's airlock
## sits on its bottom edge today).
func _airlock_outward_dir() -> Vector2i:
	var airlock := ship_class.spawn_tile
	for dir: Vector2i in [Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 0), Vector2i(-1, 0)]:
		if not ship_class.is_walkable(airlock.x + dir.x, airlock.y + dir.y):
			return dir
	return Vector2i(0, 1)

## Draws the docking collar just outside the airlock: the connecting tube
## your ship (or the concourse) sits on the other end of, labeled with
## what's connected. Rendering only -- crossing is still X at the airlock;
## stitching the two interiors into one walkable space is M3.1.
func _draw_dock_link(origin: Vector2) -> void:
	if dock_label == "":
		return
	var outward := _airlock_outward_dir()
	var collar := ship_class.spawn_tile + outward
	var rect := Rect2(_tile_to_screen(Vector2(collar), origin), Vector2(TILE_PIXELS, TILE_PIXELS))
	draw_rect(rect.grow(-TILE_PIXELS * 0.12), DOCK_COLLAR_FILL, true)
	draw_rect(rect.grow(-TILE_PIXELS * 0.12), DOCK_COLLAR_EDGE, false, 2.0)
	if _font != null:
		var text_size := _font.get_string_size(dock_label, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE)
		var label_pos := Vector2(
			rect.get_center().x - text_size.x * 0.5,
			rect.position.y + rect.size.y + FONT_SIZE + 2.0)
		if outward.y < 0:
			label_pos.y = rect.position.y - 6.0
		draw_string(
			_font, label_pos, dock_label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, DOCK_COLLAR_LABEL)

func _draw_room_labels(origin: Vector2) -> void:
	if _font == null:
		return
	for room in ship_class.rooms:
		var center := _tile_to_screen(Vector2(room.x + room.w * 0.5, room.y + room.h * 0.5), origin)
		var text_size := _font.get_string_size(room.name, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE)
		draw_string(
			_font, center - text_size * 0.5, room.name,
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, ROOM_LABEL_COLOR)

func _draw_consoles(origin: Vector2) -> void:
	for console in ship_class.consoles:
		var center := _tile_to_screen(console.tile_center(), origin)
		var color := CONSOLE_DEFAULT_COLOR
		if console.kind == "helm":
			color = CONSOLE_HELM_COLOR
		elif console.kind == "cargo":
			color = CONSOLE_CARGO_COLOR
		var half := TILE_PIXELS * 0.35
		draw_rect(Rect2(center - Vector2(half, half), Vector2(half, half) * 2.0), color, true)
		if _font != null:
			draw_string(
				_font, center + Vector2(-half, half + FONT_SIZE), console.kind,
				HORIZONTAL_ALIGNMENT_CENTER, int(half * 2.0), FONT_SIZE - 2, color)

func _draw_characters(origin: Vector2) -> void:
	var radius_px := CHARACTER_RADIUS_TILES * TILE_PIXELS
	for character in characters:
		var screen_pos := _tile_to_screen(character.position(), origin)
		var is_own: bool = character.id == own_character_id
		var color := OWN_CHARACTER_COLOR if is_own else OTHER_CHARACTER_COLOR
		draw_circle(screen_pos, radius_px, color)
		if _font != null:
			var label: String = "you" if is_own else character.name
			draw_string(
				_font, screen_pos + Vector2(radius_px + 3.0, 4.0), label,
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, CHARACTER_LABEL_COLOR)
