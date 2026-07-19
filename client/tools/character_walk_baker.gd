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
const LIFT := 3        ## px a mid-swing leg rises
const TUCK := 1        ## px a mid-swing leg pulls toward centre
const LEAN := 1        ## px the body shifts toward the planted leg
const BOB := 1         ## px the body rises on a passing frame
const PREVIEW_SCALE := 10

const CHARACTERS := ["player", "crew_0", "crew_1", "crew_2"]

# Each frame: [body_dx, body_dy, legL_dx, legL_dy, legR_dx, legR_dy].
# Frame 0 is the idle/rest pose (clean neutral); frames 1..4 are the walk cycle
# (plant-left / pass / plant-right / pass). Idle shares the rest's cell geometry
# so a character starting or stopping never pops in scale. The lifted leg is the
# one that swings; the body leans over whichever leg is carrying the weight.
const REST_FRAMES := 1
const FRAMES := [
	[ 0,    0,  0, 0,   0,    0   ],  # 0: idle / rest
	[ LEAN, 0,  0, 0,  -TUCK, -LIFT],   # 1: weight on left, right leg swinging up
	[ 0,   -BOB,  0, 0,   0,    0   ],  # 2: passing, both down, slight rise
	[-LEAN, 0,  TUCK, -LIFT,  0, 0  ],  # 3: weight on right, left leg swinging up
	[ 0,   -BOB,  0, 0,   0,    0   ],  # 4: passing
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
	var out := []
	for f in FRAMES:
		var cell := Image.create(cell_w, cell_h, false, Image.FORMAT_RGBA8)
		# Body first, then legs blended on top so the pelvis seam is hidden.
		var origin := Vector2i(PAD_X, PAD_TOP)
		cell.blend_rect(src, body_rect, origin + Vector2i(f[0], f[1]))
		cell.blend_rect(src, legL_rect,
			origin + Vector2i(legL_rect.position.x + f[2], legL_rect.position.y + f[3]))
		cell.blend_rect(src, legR_rect,
			origin + Vector2i(legR_rect.position.x + f[4], legR_rect.position.y + f[5]))
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
