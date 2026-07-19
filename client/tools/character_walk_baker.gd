extends SceneTree
## Headless frame-baker for the on-foot walk cycle (ticket #21).
##
## Slices a static 22x34 front-facing character sprite into body / left-leg /
## right-leg pieces and composites a short front-view walk cycle by moving the
## leg halves (and the body) a pixel or two per frame. Pure Image compositing —
## no viewport — so it runs headless and is the same code whether we're tuning
## or generating the shipped sheets.
##
## Run:  godot --headless --path client --script res://tools/character_walk_baker.gd
##
## Outputs, next to the source art:
##   <name>_walk.png     horizontal N-frame sprite sheet (the shipped asset)
##   <name>_sheet.png    upscaled contact sheet for eyeballing (not shipped)

# --- tunables (this is the whole knob-board) -------------------------------
const LEG_TOP := 24    ## first row that belongs to the legs
const SPLIT_X := 11    ## x >= SPLIT_X is the right leg; below is the left leg
const PAD_TOP := 3     ## headroom so a body bob never clips the scalp
const PAD_X := 3       ## side room so a leg can swing out without clipping
const ARM_TOP := 15    ## first row treated as swinging arm (shoulders stay on the body)
const ARM_L := Rect2i(2, 15, 3, 9)    ## left arm/hand: cols 2-4, rows 15-23
const ARM_R := Rect2i(15, 15, 5, 9)   ## right arm/hand: cols 15-19, rows 15-23
const LIFT := 3        ## px a mid-swing leg rises
const TUCK := 1        ## px a mid-swing leg pulls toward centre
const LEAN := 1        ## px the body shifts toward the planted leg
const BOB := 1         ## px the body rises on a passing frame
const ARM_UP := 2      ## px the leading arm lifts as it swings
const ARM_SWING := 1   ## px the arms sway sideways (opposite phase to the legs)
const PREVIEW_SCALE := 10

const CHARACTERS := ["player", "crew_0", "crew_1", "crew_2"]


# Frame 0 is the idle/rest pose; frames 1..4 are the walk cycle
# (plant-left / pass / plant-right / pass). Idle shares the rest's cell geometry
# so a character starting or stopping never pops in scale. The lifted leg swings;
# the body leans over the planted leg; the arms swing opposite the legs
# (contralateral) so the gait doesn't read soldier-stiff. Each pose is per-part
# pixel offsets; arms inherit the body's shift, legs stay planted.
const REST_FRAMES := 1

func _poses() -> Array[Dictionary]:
	return [
		# 0: idle / rest
		{body = Vector2i.ZERO, legL = Vector2i.ZERO, legR = Vector2i.ZERO,
			armL = Vector2i.ZERO, armR = Vector2i.ZERO},
		# 1: weight on left, right leg swings up; left arm leads (up/out)
		{body = Vector2i(LEAN, 0), legL = Vector2i.ZERO, legR = Vector2i(-TUCK, -LIFT),
			armL = Vector2i(-ARM_SWING, -ARM_UP), armR = Vector2i(-ARM_SWING, 0)},
		# 2: passing, both legs down, body rises
		{body = Vector2i(0, -BOB), legL = Vector2i.ZERO, legR = Vector2i.ZERO,
			armL = Vector2i.ZERO, armR = Vector2i.ZERO},
		# 3: weight on right, left leg swings up; right arm leads (up/out)
		{body = Vector2i(-LEAN, 0), legL = Vector2i(TUCK, -LIFT), legR = Vector2i.ZERO,
			armL = Vector2i(ARM_SWING, 0), armR = Vector2i(ARM_SWING, -ARM_UP)},
		# 4: passing
		{body = Vector2i(0, -BOB), legL = Vector2i.ZERO, legR = Vector2i.ZERO,
			armL = Vector2i.ZERO, armR = Vector2i.ZERO},
	]


func _initialize() -> void:
	var root := ProjectSettings.globalize_path("res://assets/characters")
	for name in CHARACTERS:
		var src := Image.load_from_file(root + "/" + name + ".png")
		if src == null:
			push_error("baker: missing " + name)
			continue
		src.convert(Image.FORMAT_RGBA8)
		var frames := _build_frames(src)
		_save_sheet(frames, root + "/" + name + "_walk.png")
		_save_preview(frames, root + "/" + name + "_sheet.png")
		print("baked %s: %d frames, cell %dx%d" % [
			name, frames.size(), frames[0].get_width(), frames[0].get_height()])
	quit()


## Build one Image per frame. Every frame is the same padded cell size so the
## sheet is a clean horizontal strip and the runtime can index it by width.
func _build_frames(src: Image) -> Array:
	var w := src.get_width()
	var h := src.get_height()
	var cell_w := w + 2 * PAD_X
	var cell_h := h + PAD_TOP
	var body_rect := Rect2i(0, 0, w, LEG_TOP)
	var legL_rect := Rect2i(0, LEG_TOP, SPLIT_X, h - LEG_TOP)
	var legR_rect := Rect2i(SPLIT_X, LEG_TOP, w - SPLIT_X, h - LEG_TOP)
	# The arms swing independently, so cut them out of the body (leaving the
	# shoulders) and carry them as their own pieces. Their vacated slot is the
	# body's outer edge — showing through to nothing there is correct.
	var arm_L := src.get_region(ARM_L)
	var arm_R := src.get_region(ARM_R)
	var body := src.get_region(body_rect)
	_erase(body, ARM_L)
	_erase(body, ARM_R)
	var out := []
	for p in _poses():
		var cell := Image.create(cell_w, cell_h, false, Image.FORMAT_RGBA8)
		var origin := Vector2i(PAD_X, PAD_TOP)
		# Body (arm-less) first; legs over the pelvis seam; arms over the
		# shoulders. Arms inherit the body's shift so they stay attached.
		cell.blend_rect(body, Rect2i(Vector2i.ZERO, body_rect.size), origin + p.body)
		cell.blend_rect(src, legL_rect, origin + legL_rect.position + p.legL)
		cell.blend_rect(src, legR_rect, origin + legR_rect.position + p.legR)
		cell.blend_rect(arm_L, Rect2i(Vector2i.ZERO, ARM_L.size),
			origin + ARM_L.position + p.body + p.armL)
		cell.blend_rect(arm_R, Rect2i(Vector2i.ZERO, ARM_R.size),
			origin + ARM_R.position + p.body + p.armR)
		out.append(cell)
	return out


## Clear a rectangle of an image to fully transparent (in place).
func _erase(img: Image, rect: Rect2i) -> void:
	for y in range(rect.position.y, rect.position.y + rect.size.y):
		for x in range(rect.position.x, rect.position.x + rect.size.x):
			img.set_pixel(x, y, Color(0, 0, 0, 0))


func _save_sheet(frames: Array, path: String) -> void:
	var cw: int = frames[0].get_width()
	var ch: int = frames[0].get_height()
	var sheet := Image.create(cw * frames.size(), ch, false, Image.FORMAT_RGBA8)
	for i in frames.size():
		sheet.blit_rect(frames[i], Rect2i(0, 0, cw, ch), Vector2i(i * cw, 0))
	sheet.save_png(path)


## Contact sheet: each frame on a mid-grey card, nearest-scaled, with a magenta
## baseline so foot heights are easy to compare by eye.
func _save_preview(frames: Array, path: String) -> void:
	var cw: int = frames[0].get_width()
	var ch: int = frames[0].get_height()
	var gap := 2
	var s := PREVIEW_SCALE
	var card_w := cw + gap
	var img := Image.create(card_w * frames.size() * s, (ch + gap) * s, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.25, 0.25, 0.28))
	for i in frames.size():
		var scaled: Image = frames[i].duplicate()
		scaled.resize(cw * s, ch * s, Image.INTERPOLATE_NEAREST)
		img.blend_rect(scaled, Rect2i(0, 0, cw * s, ch * s),
			Vector2i((i * card_w + gap / 2) * s, (gap / 2) * s))
	# baseline at the foot row (cell bottom) across the whole strip
	var base_y := (ch - 1 + gap / 2) * s
	for y in range(base_y, base_y + 2):
		for x in range(img.get_width()):
			img.set_pixel(x, y, Color(1, 0, 1, 0.5))
	img.save_png(path)
