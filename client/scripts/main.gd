extends Node2D
## Main M0 scene: renders every ship in the latest snapshot as a small dot.
##
## Snapshots arrive at 15 Hz; between snapshots each dot is extrapolated
## along its server-reported velocity (pos + vel * time_since_snapshot) so
## motion stays smooth at render framerate. This mirrors the design doc's
## client-side interpolation plan in its simplest form.

const WORLD_EXTENT := 10000.0  # ship coords are within +/- this on both axes
const SCREEN_MARGIN := 24.0
const DOT_RADIUS := 2.0
const DOT_COLOR := Color(0.55, 0.85, 1.0)
const BACKGROUND_COLOR := Color(0.03, 0.04, 0.08)
## If snapshots stall (e.g. server hiccup), stop extrapolating after this
## long so dots don't fly off into the void.
const MAX_EXTRAPOLATION_SEC := 0.5

var _ships: Array = []            # latest snapshot's ship dicts {id,x,y,vx,vy}
var _snapshot_ticks_msec := 0     # Time.get_ticks_msec() when it arrived

@onready var _status_label: Label = %StatusLabel

func _ready() -> void:
	RenderingServer.set_default_clear_color(BACKGROUND_COLOR)
	NetworkClient.snapshot_received.connect(_on_snapshot_received)
	NetworkClient.connection_state_changed.connect(_on_connection_state_changed)
	_update_status_label()

func _process(_delta: float) -> void:
	_update_status_label()
	queue_redraw()

func _draw() -> void:
	if _ships.is_empty():
		return
	var viewport_size := get_viewport_rect().size
	# World is a +/-WORLD_EXTENT square; fit it inside the viewport's shorter
	# axis, centered, with a margin.
	var view_scale := (minf(viewport_size.x, viewport_size.y) - 2.0 * SCREEN_MARGIN) \
			/ (2.0 * WORLD_EXTENT)
	var screen_center := viewport_size * 0.5
	var dt := minf(
		float(Time.get_ticks_msec() - _snapshot_ticks_msec) / 1000.0,
		MAX_EXTRAPOLATION_SEC)
	for ship: Dictionary in _ships:
		var world_pos := Vector2(
			float(ship["x"]) + float(ship["vx"]) * dt,
			float(ship["y"]) + float(ship["vy"]) * dt)
		# Negate y: world y-up -> screen y-down.
		var screen_pos := screen_center + Vector2(world_pos.x, -world_pos.y) * view_scale
		draw_circle(screen_pos, DOT_RADIUS, DOT_COLOR)

func _on_snapshot_received(_tick: int, ships: Array) -> void:
	_ships = ships
	_snapshot_ticks_msec = Time.get_ticks_msec()

func _on_connection_state_changed(_state: NetworkClient.ConnectionState) -> void:
	_update_status_label()

func _update_status_label() -> void:
	match NetworkClient.state:
		NetworkClient.ConnectionState.CONNECTING:
			_status_label.text = "connecting…"
		NetworkClient.ConnectionState.CONNECTED:
			_status_label.text = "connected (tick %d)" % NetworkClient.last_tick
		NetworkClient.ConnectionState.DISCONNECTED:
			_status_label.text = "disconnected"
