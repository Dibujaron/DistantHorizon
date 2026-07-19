extends Node2D
## Integration probe (decorated-interiors, T7): drives the REAL
## interior_view.gd draw path (_draw_decor / the fixture-sprite branch of
## _draw_structure) against a small hand-authored decorated deck — a bed 'd'
## and a cargo pallet 'p' with NE-corner palette colours, plus a 'w' window
## fixture edge. No server, no devserver contention. Mirrors
## interior_walk_probe.gd's shape (a real InteriorView child fed via
## set_frame_data each frame) and interior_parse_probe.gd's inline
## GlyphRegistry-before-parse trick (NetworkClient.glyphs must exist before
## ShipClassData.from_dict runs, since decor resolution consults it).
##
## Run:  godot --path client --headless res://tools/interior_render_probe.tscn --quit-after 120
## Env:  DH_SHOT=<path> captures one frame, then quits (controller does the
##       non-headless pixel-capture run; this probe only proves the draw path
##       is runtime-error-free under --headless's dummy renderer).

var _view: InteriorView
var _cls: ShipClassData
var _own: CharacterState
var _t := 0.0


func _ready() -> void:
	NetworkClient.glyphs = GlyphRegistry.from_dict({
		"centers": [
			{"glyph": " ", "id": "floor", "tile": "floor"},
			{"glyph": ".", "id": "void", "tile": "void"},
			{"glyph": "x", "id": "stairs", "tile": "stairs", "sprite": "stairs"},
			{"glyph": "d", "id": "bed", "tile": "floor", "sprite": "bed"},
			{"glyph": "p", "id": "cargo_pallet", "tile": "floor", "sprite": "cargo_pallet"},
		],
		"edges": [
			{"glyph": "w", "id": "window", "sprite": "window"},
		],
	})
	NetworkClient.palette = Palette.from_dict([
		"#1a1a2e", "#16213e", "#0f3460", "#e94560",
		"#f5f5f5", "#00adb5", "#393e46", "#eeeeee",
		"#ff5722", "#4caf50", "#ffc107", "#9c27b0",
		"#3f51b5", "#009688", "#795548", "#1D1D21",
	])

	# 3 tiles wide x 1 tall. Tile0: bed 'd', colour 'a' (10). Tile1: pallet
	# 'p', colour '4'. Tile1/Tile2 share a 'w' window fixture edge. Tile2:
	# plain floor, uncoloured. NW/SW/SE corner cells are never read by the
	# parser (only NE carries colour) — filled with '#' as inert padding.
	_cls = ShipClassData.from_dict({
		"id": "probe", "name": "Probe",
		"decks": [{"name": "main", "grid": [
			"##a##4## ",
			"#d  pww #",
			"#########",
		]}],
		"spawn": {"deck": 0, "tile": [0, 0]},
	})

	_view = InteriorView.new()  # _grid_origin() centers the deck in the viewport
	add_child(_view)

	_own = _make_char(1, "you", 0.5, 0.5)


func _make_char(id: int, cname: String, x: float, y: float) -> CharacterState:
	var c := CharacterState.new()
	c.id = id
	c.name = cname
	c.x = x
	c.y = y
	c.deck = 0
	c.seat = ""
	return c


func _process(delta: float) -> void:
	_t += delta
	_view.set_frame_data(_cls, [_own] as Array[CharacterState], 1,
		_own.position(), 0, [] as Array[InteriorView.Backdrop])
	_maybe_shot()


var _shot_done := false
func _maybe_shot() -> void:
	if _shot_done or _t < 0.3:
		return
	_shot_done = true
	var path := OS.get_environment("DH_SHOT")
	if path.is_empty():
		return
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	print("[probe] shot saved: " + path)
	get_tree().quit()
