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

# --- side-profile scissor tunables ---
const SIDE_STRIDE := 2  ## px a side-view leg swings fore/aft
const SIDE_BOB := 1     ## px the body rises on a passing frame

# Slice profiles. A config with arm rects of zero width skips arm-cutting, so
# the arms ride with the body (the side view has one arm and no arm-swing yet).
const FRONT_CFG := {
	leg_top = LEG_TOP, split_x = SPLIT_X, arm_l = ARM_L, arm_r = ARM_R,
}
const SIDE_CFG := {
	leg_top = LEG_TOP, split_x = SPLIT_X,
	arm_l = Rect2i(0, 0, 0, 0), arm_r = Rect2i(0, 0, 0, 0),
}

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


# Side scissor: legL is the BACK leg, legR the FRONT leg (split at SPLIT_X).
# They swing on X (fore/aft) instead of lifting; the body bobs on the pass
# frames. Idle (0) matches the rest cell so start/stop never pops.
func _side_poses() -> Array[Dictionary]:
	return [
		{body = Vector2i.ZERO, legL = Vector2i.ZERO, legR = Vector2i.ZERO,
			armL = Vector2i.ZERO, armR = Vector2i.ZERO},
		{body = Vector2i.ZERO, legL = Vector2i(-SIDE_STRIDE, 0), legR = Vector2i(SIDE_STRIDE, 0),
			armL = Vector2i.ZERO, armR = Vector2i.ZERO},
		{body = Vector2i(0, -SIDE_BOB), legL = Vector2i.ZERO, legR = Vector2i.ZERO,
			armL = Vector2i.ZERO, armR = Vector2i.ZERO},
		{body = Vector2i.ZERO, legL = Vector2i(SIDE_STRIDE, 0), legR = Vector2i(-SIDE_STRIDE, 0),
			armL = Vector2i.ZERO, armR = Vector2i.ZERO},
		{body = Vector2i(0, -SIDE_BOB), legL = Vector2i.ZERO, legR = Vector2i.ZERO,
			armL = Vector2i.ZERO, armR = Vector2i.ZERO},
	]


func _initialize() -> void:
	var root := ProjectSettings.globalize_path("res://assets/characters")
	for name in CHARACTERS:
		_bake_view(root, name, "", FRONT_CFG, _poses())
		_bake_view(root, name, "_back", FRONT_CFG, _poses())
		_bake_view(root, name, "_side", SIDE_CFG, _side_poses())
	quit()


## Load <name><suffix>.png, bake it, and write <name><suffix>_walk.png (+ preview).
func _bake_view(root: String, name: String, suffix: String,
		cfg: Dictionary, poses: Array) -> void:
	var src := Image.load_from_file(root + "/" + name + suffix + ".png")
	if src == null:
		push_error("baker: missing " + name + suffix)
		return
	src.convert(Image.FORMAT_RGBA8)
	var frames := _build_frames(src, cfg, poses)
	_save_sheet(frames, root + "/" + name + suffix + "_walk.png")
	_save_preview(frames, root + "/" + name + suffix + "_sheet.png")
	print("baked %s%s: %d frames, cell %dx%d" % [
		name, suffix, frames.size(), frames[0].get_width(), frames[0].get_height()])


## Build one Image per frame from a slice config + pose table. Every frame is
## the same padded cell size so the sheet is a clean horizontal strip.
func _build_frames(src: Image, cfg: Dictionary, poses: Array) -> Array:
	var w := src.get_width()
	var h := src.get_height()
	var leg_top: int = cfg.leg_top
	var split_x: int = cfg.split_x
	var arm_l: Rect2i = cfg.arm_l
	var arm_r: Rect2i = cfg.arm_r
	var cut_arms := arm_l.size.x > 0 and arm_r.size.x > 0
	var cell_w := w + 2 * PAD_X
	var cell_h := h + PAD_TOP
	var body_rect := Rect2i(0, 0, w, leg_top)
	var legL_rect := Rect2i(0, leg_top, split_x, h - leg_top)
	var legR_rect := Rect2i(split_x, leg_top, w - split_x, h - leg_top)
	var body := src.get_region(body_rect)
	var arm_L := Image.new()
	var arm_R := Image.new()
	if cut_arms:
		# Carry the arms as their own pieces so they swing; leave the shoulders.
		# Their vacated slot is the body's outer edge — showing through to
		# nothing there is correct.
		arm_L = src.get_region(arm_l)
		arm_R = src.get_region(arm_r)
		_erase(body, arm_l)
		_erase(body, arm_r)
	var out := []
	for p in poses:
		var cell := Image.create(cell_w, cell_h, false, Image.FORMAT_RGBA8)
		var origin := Vector2i(PAD_X, PAD_TOP)
		# Body (arm-less when cut) first; legs over the pelvis seam; arms over
		# the shoulders. Arms inherit the body's shift so they stay attached.
		cell.blend_rect(body, Rect2i(Vector2i.ZERO, body_rect.size), origin + p.body)
		cell.blend_rect(src, legL_rect, origin + legL_rect.position + p.legL)
		cell.blend_rect(src, legR_rect, origin + legR_rect.position + p.legR)
		if cut_arms:
			cell.blend_rect(arm_L, Rect2i(Vector2i.ZERO, arm_l.size),
				origin + arm_l.position + p.body + p.armL)
			cell.blend_rect(arm_R, Rect2i(Vector2i.ZERO, arm_r.size),
				origin + arm_r.position + p.body + p.armR)
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
