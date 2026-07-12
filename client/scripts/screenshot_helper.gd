extends Node
## Debug-only autoload: when the DH_SCREENSHOT env var is set, saves a PNG of
## the viewport ~3 seconds after the first snapshot arrives, then quits.
## Used by automated verification; inert in normal runs.

const DELAY_AFTER_FIRST_SNAPSHOT_MSEC := 3000
const OUTPUT_PATH := "res://screenshot.png"

var _armed := false
var _first_snapshot_msec := -1

func _ready() -> void:
	_armed = not OS.get_environment("DH_SCREENSHOT").is_empty()
	if not _armed:
		set_process(false)
		return
	print("[screenshot] armed; will capture %d ms after first snapshot" % DELAY_AFTER_FIRST_SNAPSHOT_MSEC)
	NetworkClient.snapshot_received.connect(_on_snapshot_received)

func _on_snapshot_received(_tick: int, _ships: Array) -> void:
	if _first_snapshot_msec < 0:
		_first_snapshot_msec = Time.get_ticks_msec()

func _process(_delta: float) -> void:
	if _first_snapshot_msec < 0:
		return
	if Time.get_ticks_msec() - _first_snapshot_msec < DELAY_AFTER_FIRST_SNAPSHOT_MSEC:
		return
	_armed = false
	set_process(false)
	_capture_and_quit()

func _capture_and_quit() -> void:
	# Wait for a fully rendered frame before grabbing the viewport texture.
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var err := image.save_png(OUTPUT_PATH)
	if err == OK:
		print("[screenshot] saved %s (%dx%d)" % [OUTPUT_PATH, image.get_width(), image.get_height()])
	else:
		push_error("[screenshot] save failed: %s" % error_string(err))
	get_tree().quit()
