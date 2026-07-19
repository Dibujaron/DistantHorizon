extends Node2D
## Standalone walk-cycle preview for ticket #21 — no server, no game state, just
## the characters walking so the animation can be judged and tuned in isolation.
##
## Run:  godot --path client res://scenes/character_anim_lab.gd  (or the .tscn)
##
## Reads the baked *_walk.png sheets the same runtime way the game loads art
## (Image.load_from_file — the assets tree is .gdignore'd). Frame 0 of a sheet
## is idle; frames 1..N are the walk cycle.
##
## Keys:  SPACE toggle idle/walk · LEFT/RIGHT flip facing · UP/DOWN fps · ESC quit
## Env:   DH_SHOT=<path> — capture one frame after warmup, then quit (for review)

const CHARACTERS := ["player", "crew_0", "crew_1", "crew_2"]
const DISPLAY_SCALE := 7.0
const DEFAULT_FPS := 9.0

var _sprites: Array[AnimatedSprite2D] = []
var _walking := true
var _facing := 1.0
var _fps := DEFAULT_FPS
var _font := ThemeDB.fallback_font


func _ready() -> void:
	var root := ProjectSettings.globalize_path("res://assets/characters")
	var vp := get_viewport().get_visible_rect().size
	var spacing := vp.x / (CHARACTERS.size() + 1)
	for i in CHARACTERS.size():
		var frames := _load_frames(root + "/" + CHARACTERS[i] + "_walk.png")
		if frames == null:
			continue
		var s := AnimatedSprite2D.new()
		s.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		s.sprite_frames = frames
		s.scale = Vector2(DISPLAY_SCALE, DISPLAY_SCALE)
		s.position = Vector2(spacing * (i + 1), vp.y * 0.55)
		add_child(s)
		_sprites.append(s)
	_apply_state()
	_maybe_screenshot()


## Slice a horizontal N-cell sheet into a SpriteFrames with an "idle" animation
## (cell 0) and a looping "walk" animation (cells 1..N-1).
func _load_frames(path: String) -> SpriteFrames:
	var img := Image.load_from_file(path)
	if img == null:
		push_error("lab: missing " + path)
		return null
	var h := img.get_height()
	# The baker emits 5 equal cells per sheet: 1 idle + 4 walk.
	var cells := 5
	var cw := img.get_width() / cells
	var sf := SpriteFrames.new()
	sf.remove_animation("default")
	sf.add_animation("idle")
	sf.set_animation_loop("idle", true)
	sf.add_animation("walk")
	sf.set_animation_loop("walk", true)
	for c in cells:
		var cell := img.get_region(Rect2i(c * cw, 0, cw, h))
		cell.convert(Image.FORMAT_RGBA8)
		var tex := ImageTexture.create_from_image(cell)
		if c == 0:
			sf.add_frame("idle", tex)
		else:
			sf.add_frame("walk", tex)
	return sf


func _apply_state() -> void:
	for s in _sprites:
		s.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		s.flip_h = _facing < 0.0
		var anim := "walk" if _walking else "idle"
		s.sprite_frames.set_animation_speed(anim, _fps)
		s.play(anim)


func _draw() -> void:
	var vp := get_viewport().get_visible_rect().size
	draw_rect(Rect2(Vector2.ZERO, vp), Color(0.16, 0.17, 0.20))  # interior-ish grey
	# ground line under the feet
	var ground := vp.y * 0.55 + (37.0 - 3.0) * 0.5 * DISPLAY_SCALE
	draw_line(Vector2(0, ground), Vector2(vp.x, ground), Color(0.30, 0.31, 0.36), 2.0)
	if _font == null:
		return
	for i in _sprites.size():
		var pos := _sprites[i].position + Vector2(-40, 150)
		draw_string(_font, pos, CHARACTERS[i], HORIZONTAL_ALIGNMENT_CENTER, 120, 20,
			Color(0.8, 0.82, 0.9))
	var hud := "%s  ·  %d fps  ·  SPACE idle/walk  LEFT/RIGHT flip  UP/DOWN fps  ESC quit" % [
		("WALK" if _walking else "IDLE"), int(_fps)]
	draw_string(_font, Vector2(20, 34), hud, HORIZONTAL_ALIGNMENT_LEFT, -1, 18,
		Color(0.7, 0.72, 0.8))


func _process(_dt: float) -> void:
	queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed):
		return
	match event.keycode:
		KEY_SPACE:
			_walking = not _walking
		KEY_LEFT:
			_facing = -1.0
		KEY_RIGHT:
			_facing = 1.0
		KEY_UP:
			_fps = min(_fps + 1.0, 24.0)
		KEY_DOWN:
			_fps = max(_fps - 1.0, 1.0)
		KEY_ESCAPE:
			get_tree().quit()
		_:
			return
	_apply_state()


func _maybe_screenshot() -> void:
	var path := OS.get_environment("DH_SHOT")
	if path.is_empty():
		return
	await get_tree().create_timer(1.2).timeout
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	image.save_png(path)
	print("[lab] shot saved: " + path)
	get_tree().quit()
