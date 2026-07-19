extends SceneTree
## Headless frame-baker for the on-foot walk cycle (ticket #21).
##
## Composites the on-foot walk cycle from per-view layers — a complete armless
## body (torso/head + split legs) plus a separate arm layer — swinging the legs
## and arms a pixel or two per frame. Because the body is already armless-complete,
## the arms never have to be sliced out of it (which mangled the torso). Pure
## Image compositing, no viewport, so it runs headless and is the same code
## whether we're tuning or shipping.
##
## Run:  godot --headless --path client --script res://tools/character_walk_baker.gd
##
## Outputs, next to the source art:
##   <name>_walk.png     horizontal N-frame sprite sheet (the shipped asset)
##   <name>_sheet.png    upscaled contact sheet for eyeballing (not shipped)

# --- tunables (this is the whole knob-board) -------------------------------
const LEG_TOP := 24    ## first row that belongs to the legs
const SPLIT_X := 11    ## x >= SPLIT_X is the right leg / arm; below is the left
const PAD_TOP := 3     ## headroom so a body bob never clips the scalp
const PAD_X := 3       ## side room so a leg or arm can swing out without clipping
const LIFT := 3        ## px a mid-swing leg rises
const TUCK := 1        ## px a mid-swing leg pulls toward centre
const LEAN := 1        ## px the body shifts toward the planted leg
const BOB := 1         ## px the body rises on a passing frame
const ARM_UP := 0      ## px the leading arm lifts (0: a rigid translate of a
                       ## separate arm layer detaches it from the body)
const ARM_SWING := 0   ## px the arms sway (0: any outward sway opens a 1px seam
                       ## at the arm/torso junction; front/back arms ride still)
const PREVIEW_SCALE := 10

# --- side-profile scissor tunables ---
const SIDE_STRIDE := 2      ## px a side-view leg swings fore/aft
const SIDE_BOB := 1         ## px the body rises on a passing frame
const SIDE_ARM_SWING := 2   ## px the near arm swings fore/aft (opposite the front leg)

const CHARACTERS := ["player", "crew_0", "crew_1", "crew_2"]


# Frame 0 is idle/rest; frames 1..4 are the cycle (plant-left / pass /
# plant-right / pass). Idle shares the rest cell geometry so start/stop never
# pops. The lifted leg swings; the body leans over the planted leg; the arms
# swing opposite the legs (contralateral) so the gait doesn't read soldier-stiff.
func _poses() -> Array[Dictionary]:
	return [
		{body = Vector2i.ZERO, legL = Vector2i.ZERO, legR = Vector2i.ZERO,
			armL = Vector2i.ZERO, armR = Vector2i.ZERO},
		{body = Vector2i(LEAN, 0), legL = Vector2i.ZERO, legR = Vector2i(-TUCK, -LIFT),
			armL = Vector2i(-ARM_SWING, -ARM_UP), armR = Vector2i(-ARM_SWING, 0)},
		{body = Vector2i(0, -BOB), legL = Vector2i.ZERO, legR = Vector2i.ZERO,
			armL = Vector2i.ZERO, armR = Vector2i.ZERO},
		{body = Vector2i(-LEAN, 0), legL = Vector2i(TUCK, -LIFT), legR = Vector2i.ZERO,
			armL = Vector2i(ARM_SWING, 0), armR = Vector2i(ARM_SWING, -ARM_UP)},
		{body = Vector2i(0, -BOB), legL = Vector2i.ZERO, legR = Vector2i.ZERO,
			armL = Vector2i.ZERO, armR = Vector2i.ZERO},
	]


# Side scissor: legL is the BACK leg, legR the FRONT leg (split at SPLIT_X). They
# swing on X (fore/aft) instead of lifting; the near arm (armR) swings opposite
# the front leg; the body bobs on the pass frames.
func _side_poses() -> Array[Dictionary]:
	return [
		{body = Vector2i.ZERO, legL = Vector2i.ZERO, legR = Vector2i.ZERO,
			armL = Vector2i.ZERO, armR = Vector2i.ZERO},
		{body = Vector2i.ZERO, legL = Vector2i(-SIDE_STRIDE, 0), legR = Vector2i(SIDE_STRIDE, 0),
			armL = Vector2i.ZERO, armR = Vector2i(-SIDE_ARM_SWING, 0)},
		{body = Vector2i(0, -SIDE_BOB), legL = Vector2i.ZERO, legR = Vector2i.ZERO,
			armL = Vector2i.ZERO, armR = Vector2i.ZERO},
		{body = Vector2i.ZERO, legL = Vector2i(SIDE_STRIDE, 0), legR = Vector2i(-SIDE_STRIDE, 0),
			armL = Vector2i.ZERO, armR = Vector2i(SIDE_ARM_SWING, 0)},
		{body = Vector2i(0, -SIDE_BOB), legL = Vector2i.ZERO, legR = Vector2i.ZERO,
			armL = Vector2i.ZERO, armR = Vector2i.ZERO},
	]


func _initialize() -> void:
	var root := ProjectSettings.globalize_path("res://assets/characters")
	for name in CHARACTERS:
		# out_suffix, body layer, arms layer, split arms into two (else one)
		_bake_view(root, name, "", "_body", "_arms", true, _poses())
		_bake_view(root, name, "_back", "_back_body", "_arms", true, _poses())
		_bake_view(root, name, "_side", "_side_body", "_side_arm", false, _side_poses())
	quit()


## Bake one view from its body + arm layers and write <name><out_suffix>_walk.png.
func _bake_view(root: String, name: String, out_suffix: String,
		body_suffix: String, arms_suffix: String, split_arms: bool,
		poses: Array) -> void:
	var body := Image.load_from_file(root + "/" + name + body_suffix + ".png")
	var arms := Image.load_from_file(root + "/" + name + arms_suffix + ".png")
	if body == null or arms == null:
		push_error("baker: missing layers for " + name + out_suffix)
		return
	body.convert(Image.FORMAT_RGBA8)
	arms.convert(Image.FORMAT_RGBA8)
	var frames := _build_frames(body, arms, split_arms, poses)
	_save_sheet(frames, root + "/" + name + out_suffix + "_walk.png")
	_save_preview(frames, root + "/" + name + out_suffix + "_sheet.png")
	print("baked %s%s: %d frames, cell %dx%d" % [
		name, out_suffix, frames.size(), frames[0].get_width(), frames[0].get_height()])


## Composite each frame: armless body (torso/head + split legs) with the swinging
## arm layer drawn ON TOP. The body is already complete, so a lifting or swinging
## arm always reveals torso beneath — never a hole. Front/back carry two arms
## (split at centre); the side carries one near arm. Every frame is the same
## padded cell so the sheet is a clean strip.
func _build_frames(body: Image, arms: Image, split_arms: bool, poses: Array) -> Array:
	var w := body.get_width()
	var h := body.get_height()
	var cell_w := w + 2 * PAD_X
	var cell_h := h + PAD_TOP
	var upper_rect := Rect2i(0, 0, w, LEG_TOP)   # torso + head, armless
	var legL_rect := Rect2i(0, LEG_TOP, SPLIT_X, h - LEG_TOP)
	var legR_rect := Rect2i(SPLIT_X, LEG_TOP, w - SPLIT_X, h - LEG_TOP)
	var upper := body.get_region(upper_rect)
	# Arm layer(s): front/back split both arms at centre so each swings on its
	# own; the side view keeps its single near arm on the full canvas.
	var arm_l := Image.new()
	var arm_r := arms
	var arm_r_pos := Vector2i.ZERO
	if split_arms:
		var cx := w / 2
		arm_l = arms.get_region(Rect2i(0, 0, cx, h))
		arm_r = arms.get_region(Rect2i(cx, 0, w - cx, h))
		arm_r_pos = Vector2i(cx, 0)
	var out := []
	for p in poses:
		var cell := Image.create(cell_w, cell_h, false, Image.FORMAT_RGBA8)
		var origin := Vector2i(PAD_X, PAD_TOP)
		cell.blend_rect(body, legL_rect, origin + legL_rect.position + p.legL)
		cell.blend_rect(body, legR_rect, origin + legR_rect.position + p.legR)
		cell.blend_rect(upper, Rect2i(Vector2i.ZERO, upper_rect.size), origin + p.body)
		if split_arms:
			cell.blend_rect(arm_l, Rect2i(Vector2i.ZERO, arm_l.get_size()),
				origin + p.body + p.armL)
		cell.blend_rect(arm_r, Rect2i(Vector2i.ZERO, arm_r.get_size()),
			origin + arm_r_pos + p.body + p.armR)
		out.append(cell)
	return out


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
