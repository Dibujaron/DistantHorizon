extends Node2D
## M1 scene: flies one player-controlled ship around the pinned system.
##
## Networking/protocol lives in the NetworkClient autoload; rail + ship
## rendering lives in the WorldView child node (world_view.gd). This script
## wires the two together: it owns login bookkeeping, helm/dock input,
## camera follow + zoom, and the status label.
##
## Snapshots arrive at 15 Hz; between snapshots ship positions (and rail
## positions, via sim time `t`) are extrapolated at render framerate the
## same way M0 did for its dot-cloud, capped so a stalled connection doesn't
## fling anything off into the void.

const BACKGROUND_COLOR := Color(0.03, 0.04, 0.08)
const MAX_EXTRAPOLATION_SEC := 0.5
const TICKS_PER_SEC := 60.0

const ZOOM_MIN := 0.02
const ZOOM_MAX := 2.0
const ZOOM_STEP := 1.15
const DEFAULT_ZOOM := 0.2

const TRANSIENT_MESSAGE_SEC := 3.0

var _ships: Array = []               # latest snapshot's ship dicts
var _snapshot_tick: int = 0
var _snapshot_ticks_msec: int = 0

var _world: Dictionary = {}
var _dt: float = 0.016666666666666666
var _ship_id: int = -1

var _zoom: float = DEFAULT_ZOOM
var _last_sent_rotate: float = 0.0
var _last_sent_thrust: float = 0.0

var _transient_message: String = ""
var _transient_expire_msec: int = 0

@onready var _status_label: Label = %StatusLabel
@onready var _world_view: WorldView = %WorldView

func _ready() -> void:
	RenderingServer.set_default_clear_color(BACKGROUND_COLOR)
	NetworkClient.snapshot_received.connect(_on_snapshot_received)
	NetworkClient.connection_state_changed.connect(_on_connection_state_changed)
	NetworkClient.welcome_received.connect(_on_welcome_received)
	NetworkClient.dock_result_received.connect(_on_dock_result_received)
	NetworkClient.error_received.connect(_on_error_received)
	_update_status_label()

func _physics_process(_delta: float) -> void:
	_poll_helm_input()

func _process(_delta: float) -> void:
	_update_status_label()
	_update_world_view()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_dock"):
		_toggle_dock()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom = clampf(_zoom * ZOOM_STEP, ZOOM_MIN, ZOOM_MAX)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom = clampf(_zoom / ZOOM_STEP, ZOOM_MIN, ZOOM_MAX)

## Composes rotate in {-1,0,1} (turn_left = +1, counter-clockwise, matching
## the wire protocol's "rotate positive = counter-clockwise") and thrust in
## {0,1}, sending `helm` only when the pair actually changed so we don't
## spam the server at input-poll rate.
func _poll_helm_input() -> void:
	if not NetworkClient.logged_in:
		return
	var rotate := 0.0
	if Input.is_action_pressed("turn_left"):
		rotate += 1.0
	if Input.is_action_pressed("turn_right"):
		rotate -= 1.0
	var thrust := 1.0 if Input.is_action_pressed("thrust") else 0.0
	if rotate != _last_sent_rotate or thrust != _last_sent_thrust:
		NetworkClient.send_message({"type": "helm", "rotate": rotate, "thrust": thrust})
		_last_sent_rotate = rotate
		_last_sent_thrust = thrust

func _toggle_dock() -> void:
	if not NetworkClient.logged_in:
		return
	var own: Variant = _own_ship()
	if own != null and own.get("docked") != null:
		NetworkClient.send_message({"type": "undock"})
	else:
		NetworkClient.send_message({"type": "dock"})

func _own_ship() -> Variant:
	for ship: Dictionary in _ships:
		if int(ship.get("id", -1)) == _ship_id:
			return ship
	return null

## Seconds of wall-clock time elapsed since the latest snapshot, capped so a
## stalled connection can't extrapolate forever.
func _seconds_since_snapshot() -> float:
	return minf(float(Time.get_ticks_msec() - _snapshot_ticks_msec) / 1000.0, MAX_EXTRAPOLATION_SEC)

## Sim time for rail math: last snapshot's tick, advanced by the (capped)
## wall-clock time elapsed since it arrived, converted to seconds via dt.
func _sim_time() -> float:
	return (float(_snapshot_tick) + TICKS_PER_SEC * _seconds_since_snapshot()) * _dt

func _extrapolated_ship(ship: Dictionary, elapsed: float) -> Dictionary:
	var out := ship.duplicate()
	out["x"] = float(ship["x"]) + float(ship["vx"]) * elapsed
	out["y"] = float(ship["y"]) + float(ship["vy"]) * elapsed
	return out

func _update_world_view() -> void:
	var elapsed := _seconds_since_snapshot()
	var t := _sim_time()
	var extrapolated: Array = []
	var own_pos := Vector2.ZERO
	var own_found := false
	var own_undocked := true
	for ship: Dictionary in _ships:
		var e := _extrapolated_ship(ship, elapsed)
		extrapolated.append(e)
		if int(e.get("id", -1)) == _ship_id:
			own_pos = Vector2(float(e["x"]), float(e["y"]))
			own_found = true
			own_undocked = e.get("docked") == null
	if not own_found and not _world.is_empty():
		# No snapshot with our ship yet: center on the spawn station so the
		# view isn't empty while we wait.
		var spawn_station := str(_world.get("spawn_station", ""))
		if spawn_station != "":
			own_pos = WorldView.station_position_at(_world, spawn_station, t)
	_world_view.set_frame_data(_world, t, extrapolated, _ship_id, _zoom, own_pos, own_undocked)

func _on_snapshot_received(tick: int, ships: Array) -> void:
	_ships = ships
	_snapshot_tick = tick
	_snapshot_ticks_msec = Time.get_ticks_msec()

func _on_connection_state_changed(_state: NetworkClient.ConnectionState) -> void:
	_update_status_label()

func _on_welcome_received(ship_id: int, world: Dictionary) -> void:
	_ship_id = ship_id
	_world = world
	_dt = NetworkClient.dt
	# Reset so the next real input still gets sent even if it happens to
	# match whatever was last sent to a previous ship/session.
	_last_sent_rotate = 0.0
	_last_sent_thrust = 0.0

func _on_dock_result_received(ok: bool, reason: Variant) -> void:
	if not ok:
		_show_transient_message("dock failed: %s" % str(reason))

func _on_error_received(code: String, message: String) -> void:
	_show_transient_message("%s: %s" % [code, message])

func _show_transient_message(message: String) -> void:
	_transient_message = message
	_transient_expire_msec = Time.get_ticks_msec() + int(TRANSIENT_MESSAGE_SEC * 1000.0)

func _update_status_label() -> void:
	var lines: PackedStringArray = []
	match NetworkClient.state:
		NetworkClient.ConnectionState.CONNECTING:
			lines.append("connecting…")
		NetworkClient.ConnectionState.CONNECTED:
			if NetworkClient.logged_in:
				lines.append("connected (tick %d)" % NetworkClient.last_tick)
			else:
				lines.append("logging in…")
		NetworkClient.ConnectionState.DISCONNECTED:
			lines.append("disconnected")

	var own: Variant = _own_ship()
	if own != null:
		var speed := Vector2(float(own.get("vx", 0.0)), float(own.get("vy", 0.0))).length()
		lines.append("speed %.1f u/s" % speed)
		var docked: Variant = own.get("docked")
		if docked != null:
			lines.append("docked at %s" % _station_name(str(docked)))
		else:
			var near := _nearest_dockable_station_name()
			if near != "":
				lines.append("SPACE: dock at %s" % near)

	if _transient_message != "" and Time.get_ticks_msec() < _transient_expire_msec:
		lines.append(_transient_message)

	_status_label.text = "\n".join(lines)

func _station_name(station_id: String) -> String:
	for station: Dictionary in _world.get("stations", []):
		if str(station.get("id")) == station_id:
			return str(station.get("name", station_id))
	return station_id

## The name of a station whose dock_radius currently contains our (raw,
## last-snapshot) position, or "" if none. Used only for the status-label
## prompt; the server is the authority on whether a `dock` actually lands.
func _nearest_dockable_station_name() -> String:
	var own: Variant = _own_ship()
	if own == null or own.get("docked") != null:
		return ""
	var own_pos := Vector2(float(own["x"]), float(own["y"]))
	var t := _sim_time()
	for station: Dictionary in _world.get("stations", []):
		var pos := WorldView.station_position_at(_world, str(station.get("id")), t)
		if own_pos.distance_to(pos) <= float(station.get("dock_radius", 0.0)):
			return str(station.get("name", station.get("id")))
	return ""
