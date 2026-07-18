class_name MainMenu
extends CanvasLayer
## The Rijay flight-shell login terminal (M3.5 UI shell). The game shell
## speaks Rijay — 90s terminal, amber-on-dark — and is fixed per run
## (docs/visuals.md, Interface). Shown only when no --username= cmdline
## credential exists (automation and dev launches skip it entirely).
##
## Built in code: full-rect dark ground, centered column — logo, stencil
## title, terminal flavor line, CALLSIGN/PASSKEY fields, [F1] CONNECT.
## Hides on welcome_received; reshows the status line on error_received.

var _callsign: LineEdit
var _passkey: LineEdit
var _status: Label
var _connect_button: Button


func _ready() -> void:
	layer = 10
	var ground := ColorRect.new()
	ground.color = Color(0.04, 0.031, 0.023)
	ground.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(ground)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var column := VBoxContainer.new()
	column.custom_minimum_size = Vector2(460, 0)
	column.add_theme_constant_override("separation", 10)
	center.add_child(column)

	var logo := TextureRect.new()
	var logo_img := Image.load_from_file(
		ProjectSettings.globalize_path("res://assets/ui/logo.png"))
	if logo_img != null:
		logo.texture = ImageTexture.create_from_image(logo_img)
	logo.custom_minimum_size = Vector2(128, 128)
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	column.add_child(logo)

	var title := Label.new()
	title.text = "DISTANT HORIZON"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_override("font", UiTheme.stencil_font())
	title.add_theme_font_size_override("font_size", 36)
	title.add_theme_color_override("font_color", UiTheme.AMBER)
	column.add_child(title)

	var flavor := Label.new()
	flavor.text = "RIJAY DRIVE YARDS // ALOFT OS 2.4"
	flavor.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UiTheme.skin_label(flavor, 18, UiTheme.AMBER_DIM)
	column.add_child(flavor)

	column.add_child(_spacer(8))
	_callsign = _terminal_field("CALLSIGN")
	column.add_child(_callsign)
	_passkey = _terminal_field("PASSKEY")
	_passkey.secret = true
	column.add_child(_passkey)

	_status = Label.new()
	_status.text = "AWAITING CREDENTIALS"
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UiTheme.skin_label(_status, 16, UiTheme.AMBER_DIM)
	column.add_child(_status)

	_connect_button = Button.new()
	_connect_button.text = "[ F1 ]  CONNECT"
	_connect_button.add_theme_font_override("font", UiTheme.pixel_font())
	_connect_button.add_theme_font_size_override("font_size", 22)
	_connect_button.add_theme_color_override("font_color", UiTheme.AMBER)
	_connect_button.add_theme_stylebox_override("normal", UiTheme.panel(UiTheme.AMBER_DIM))
	_connect_button.add_theme_stylebox_override("hover", UiTheme.panel(UiTheme.AMBER))
	_connect_button.add_theme_stylebox_override("pressed", UiTheme.panel(UiTheme.AMBER))
	_connect_button.pressed.connect(_submit)
	column.add_child(_connect_button)

	NetworkClient.welcome_received.connect(_on_welcome)
	NetworkClient.error_received.connect(_on_error)
	_callsign.grab_focus()


func _spacer(px: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, px)
	return c


func _terminal_field(placeholder: String) -> LineEdit:
	var field := LineEdit.new()
	field.placeholder_text = placeholder
	field.add_theme_font_override("font", UiTheme.pixel_font())
	field.add_theme_font_size_override("font_size", 22)
	field.add_theme_color_override("font_color", UiTheme.AMBER)
	field.add_theme_color_override("font_placeholder_color", UiTheme.AMBER_DIM)
	field.add_theme_color_override("caret_color", UiTheme.AMBER)
	field.add_theme_stylebox_override("normal", UiTheme.panel(UiTheme.AMBER_DIM))
	field.add_theme_stylebox_override("focus", UiTheme.panel(UiTheme.AMBER))
	field.text_submitted.connect(func(_t: String) -> void: _submit())
	return field


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and event.physical_keycode == KEY_F1:
		_submit()


func _submit() -> void:
	var callsign := _callsign.text.strip_edges()
	if callsign == "":
		_status.text = "CALLSIGN REQUIRED"
		_status.add_theme_color_override("font_color", UiTheme.ALERT)
		return
	_status.text = "CONNECTING ..."
	_status.add_theme_color_override("font_color", UiTheme.AMBER_DIM)
	NetworkClient.request_login(callsign, _passkey.text)


func _on_welcome(_ship_id: int, _world: WorldData) -> void:
	visible = false


func _on_error(_code: String, message: String) -> void:
	if NetworkClient.logged_in:
		return
	visible = true
	_status.text = message.to_upper()
	_status.add_theme_color_override("font_color", UiTheme.ALERT)
