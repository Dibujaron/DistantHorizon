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
			{"glyph": "f", "id": "fountain", "tile": "floor", "sprite": "fountain"},
			{"glyph": "l", "id": "flowerbed", "tile": "floor", "sprite": "flowerbed"},
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
	# 'p', colour '4'. Tile1/Tile2 share a 'w' window fixture edge. Tile2 (now
	# 'x'): a Stairs tile at (7,1), matched by an 'x' at the SAME (tx,ty) on
	# the two extra decks below (T3, #36) — a 3-deck stack exercising all
	# three hatchway directions: deck0's stair only connects down (deck1) so
	# it draws stairs_down; deck1 connects both up (deck0) and down (deck2)
	# so it draws stairs_updown; deck2 only connects up (deck1) so it draws
	# stairs_up. NW/SW/SE corner cells are never read by the parser (only NE
	# carries colour) — filled with '#' as inert padding.
	# Rows 3-8 append a separate 2x2 'f' fountain block at (tx0-1, ty1-2)
	# (T4, #36), walled off from the row-0 content so it's independent —
	# exercises InteriorNeighbors.mask4 + the fountain merge branch of
	# _draw_decor under --headless.
	# Rows 9-14 append a walled-off 4x4 'l' flowerbed field (T5, #36):
	# exercises InteriorNeighbors.popcount + plant_variant — the interior
	# cells (tx=2/3, ty=11/12) have >=3 same-type neighbours so trees can
	# appear there deterministically, while the outer ring stays plant/base.
	_cls = ShipClassData.from_dict({
		"id": "probe", "name": "Probe",
		"decks": [
			{"name": "main", "grid": [
				"##a##4## ",
				"#d  pwwx#",
				"#########",
				"#########",
				"#f  f##.#",
				"# ## ####",
				"# ## ####",
				"#f  f##.#",
				"#########",
				"#########",
				"#llll####",
				"#llll####",
				"#llll####",
				"#llll####",
				"#########",
			]},
			{"name": "mid", "grid": [
				"#########",
				"#      x#",
				"#########",
			]},
			{"name": "bottom", "grid": [
				"#########",
				"#      x#",
				"#########",
			]},
		],
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
	# Cycle through every deck (~4/sec) so the stacked-stairs case (T3, #36)
	# exercises _draw_stairs' up/down/updown branches under --headless,
	# proving the draw path is error-free on all three even though only
	# deck0 is ever screenshotted via DH_SHOT.
	var deck := int(_t * 4.0) % _cls.deck_count()
	_view.set_frame_data(_cls, [_own] as Array[CharacterState], 1,
		_own.position(), deck, [] as Array[InteriorView.Backdrop])
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
