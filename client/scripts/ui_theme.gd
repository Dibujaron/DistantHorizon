class_name UiTheme
extends RefCounted
## The Rijay dialect for the game shell (docs/visuals.md, Interface): the
## shell speaks the starter ship's yard — 90s-computing pragmatism, dense
## terminal text, amber-on-dark — and never reskins per run.
##
## Three typography slots (runtime-loaded OFL fonts, client/assets/fonts/):
##   pixel_font()   — VT323: small/diegetic, console readouts, HUD
##   reading_font() — Inter: large/reading, dialogue and menus
##   stencil_font() — Allerta Stencil: markings, titles, hull-stencil copy

const AMBER := Color("ffb46b")
const AMBER_DIM := Color("8a6a45")
const ALERT := Color("e06a4a")
const CONSOLE_ORANGE := Color("d97a28")

static var _fonts: Dictionary = {}


static func _font(file_name: String) -> FontFile:
	if not _fonts.has(file_name):
		var f := FontFile.new()
		f.load_dynamic_font(
			ProjectSettings.globalize_path("res://assets/fonts/" + file_name))
		_fonts[file_name] = f
	return _fonts[file_name]


static func pixel_font() -> FontFile:
	return _font("vt323.ttf")


static func reading_font() -> FontFile:
	return _font("inter.ttf")


static func stencil_font() -> FontFile:
	return _font("allerta_stencil.ttf")


## Terminal panel: near-black warm ground, thin border, tight corners.
static func panel(border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.055, 0.03, 0.92)
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 10.0
	sb.content_margin_right = 10.0
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 6.0
	return sb


## Apply the Rijay terminal voice to a Label.
static func skin_label(label: Label, size: int, color: Color,
		panel_border: Variant = null) -> void:
	label.add_theme_font_override("font", pixel_font())
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	if panel_border != null:
		label.add_theme_stylebox_override("normal", panel(panel_border))
