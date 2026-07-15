extends Node2D
## M2 scene: flies one player-controlled ship around the pinned system, and
## (new in M2) walks its interior deck as a character.
##
## Networking/protocol lives in the NetworkClient autoload; rail + ship
## rendering lives in the WorldView child node (world_view.gd); deck-plan +
## character rendering lives in the InteriorView child node
## (interior_view.gd). This script wires it all together: it owns login
## bookkeeping, helm/dock/move/sit/board input, the view-mode state machine
## (SYSTEM at the helm <-> INTERIOR standing, with an animated zoom +
## crossfade between them), camera zoom, and the status label.
##
## Snapshots and interior updates arrive at 15 Hz; between messages ship and
## character positions (and rail positions, via sim time `t`) are
## extrapolated at render framerate the same way M0 did for its dot-cloud,
## capped so a stalled connection doesn't fling anything off into the void.

const BACKGROUND_COLOR := Color(0.03, 0.04, 0.08)
const MAX_EXTRAPOLATION_SEC := 0.5
const TICKS_PER_SEC := 60.0

const ZOOM_MIN := 0.02
const ZOOM_MAX := 2.0
const ZOOM_STEP := 1.15
const DEFAULT_ZOOM := 0.2

const TRANSIENT_MESSAGE_SEC := 3.0

## Duration of the animated zoom + crossfade between INTERIOR and SYSTEM
## views (spec: M2 ship interior design, "Client", ~0.6s).
const ZOOM_TRANSITION_SEC := 0.6

## Sit range shown in the status-label prompt; the server is the authority
## on whether a `sit` actually lands (spec: character sim, "Sit").
const SIT_RANGE_TILES := 1.2

## Client-side prediction of the OWN character only (fixes the stop
## snap-back: walkers halt instantly server-side on key release, but the old
## velocity-extrapolation render lagged behind at the stale speed until the
## next `interior` corrected it). Each physics tick the predicted position
## is advanced with ShipClassData.step_walk using the currently-held input,
## then softly pulled toward each accepted `interior`'s reported position by
## this fraction, or hard-snapped if it has drifted more than
## OWN_PREDICTION_SNAP_TILES away.
const OWN_PREDICTION_CORRECTION := 0.15
const OWN_PREDICTION_SNAP_TILES := 1.0

## Every OTHER character (not our own) is rendered via delayed
## interpolation between buffered `interior` messages rather than velocity
## extrapolation: their true (server) velocity also changes instantly on
## stop/turn, so extrapolating a stale one would produce the same
## snap-back the own-character prediction above fixes. Interpolating
## between two known positions instead never overshoots -- it only needs
## the render time held a little behind the newest message so there's
## (usually) a bracketing pair to interpolate between. ~100ms of headroom
## comfortably covers the ~66ms interior interval (15 Hz) plus jitter.
const OTHER_CHAR_INTERP_DELAY_SEC := 0.1
const INTERIOR_HISTORY_SIZE := 3

## Driven by seat state: SYSTEM is seated at a helm-kind console (the M1
## view); INTERIOR is everything else (standing, or seated elsewhere, e.g.
## the cargo console).
enum ViewMode { INTERIOR, SYSTEM }

var _ships: Array[ShipState] = []    # latest snapshot's ships
var _snapshot_tick: int = 0
var _snapshot_ticks_msec: int = 0

var _characters: Array[CharacterState] = []  # latest interior message's crew

## Recent `interior` messages for our own ship, each tagged with the
## wall-clock time it arrived: `{"arrival_msec": int, "characters":
## Array[CharacterState]}`, oldest first, capped to INTERIOR_HISTORY_SIZE.
## Feeds _interpolated_other_position, which renders every character but
## our own at a small render delay, interpolated between the two buffered
## messages that bracket it -- see that function's docstring for why (the
## snap-back fix for characters other than the local player).
var _interior_history: Array[Dictionary] = []

var _world: WorldData = null
var _ship_class: ShipClassData = null
var _dt: float = 0.016666666666666666
var _ship_id: int = -1
var _character_id: int = -1

var _zoom: float = DEFAULT_ZOOM
var _last_sent_rotate: float = 0.0
var _last_sent_thrust: float = 0.0
var _last_sent_dx: float = 0.0
var _last_sent_dy: float = 0.0

var _view_mode: ViewMode = ViewMode.SYSTEM
var _transitioning: bool = false
var _transition_from: ViewMode = ViewMode.SYSTEM
var _transition_to: ViewMode = ViewMode.SYSTEM
var _transition_elapsed: float = 0.0

var _transient_message: String = ""
var _transient_expire_msec: int = 0

## Predicted position of the own character while standing (tile units,
## ship-local -- same frame as CharacterState.position()). Valid only while
## _predicting is true; reset to the server position outright whenever
## prediction (re)starts, e.g. right after login/board/stand, since there's
## no continuity to build on then.
var _predicted_pos: Vector2 = Vector2.ZERO
var _predicting: bool = false

@onready var _status_label: Label = %StatusLabel
@onready var _world_view: WorldView = %WorldView
@onready var _interior_view: InteriorView = %InteriorView

func _ready() -> void:
	RenderingServer.set_default_clear_color(BACKGROUND_COLOR)
	NetworkClient.snapshot_received.connect(_on_snapshot_received)
	NetworkClient.connection_state_changed.connect(_on_connection_state_changed)
	NetworkClient.welcome_received.connect(_on_welcome_received)
	NetworkClient.dock_result_received.connect(_on_dock_result_received)
	NetworkClient.error_received.connect(_on_error_received)
	NetworkClient.interior_received.connect(_on_interior_received)
	NetworkClient.seat_result_received.connect(_on_seat_result_received)
	NetworkClient.board_result_received.connect(_on_board_result_received)
	_snap_view_visuals()
	_update_status_label()

func _physics_process(delta: float) -> void:
	_poll_helm_input()
	var move_input := _poll_move_input()
	_update_own_prediction(move_input, delta)

func _process(delta: float) -> void:
	_update_view_mode(delta)
	_update_status_label()
	_update_world_view()
	_update_interior_view()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_dock"):
		_toggle_dock()
	elif event.is_action_pressed("interact"):
		_handle_interact()
	elif event.is_action_pressed("board"):
		_handle_board()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom = clampf(_zoom * ZOOM_STEP, ZOOM_MIN, ZOOM_MAX)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom = clampf(_zoom / ZOOM_STEP, ZOOM_MIN, ZOOM_MAX)

## Composes rotate in {-1,0,1} (turn_left = +1, counter-clockwise, matching
## the wire protocol's "rotate positive = counter-clockwise") and thrust in
## {0,1}, sending `helm` only when the pair actually changed so we don't
## spam the server at input-poll rate. Gated on *live* seat state, not the
## animated view mode (which lags a seat change by the transition
## duration): W/A/D fly the ship the instant the server seats us at the
## helm, exactly as in M1, and double as move intents the instant we stand.
func _poll_helm_input() -> void:
	if not NetworkClient.logged_in or not _seated_at_helm():
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

## Composes dx,dy in {-1,0,1} (y+ is down, matching tile coords), sends
## `move` only on change, and returns the currently-held input (regardless
## of whether it changed) for _update_own_prediction to integrate every
## tick. Skipped while seated (move input is ignored server-side while
## seated, so there's nothing useful to send or predict). dx/dy are floats,
## like the helm poller's rotate/thrust: the server decodes these fields as
## floats, and a GDScript int would serialize as a bare JSON int (`1`, not
## `1.0`) and be rejected.
func _poll_move_input() -> Vector2:
	if not NetworkClient.logged_in:
		return Vector2.ZERO
	var own_char := _own_character()
	if own_char == null or own_char.is_seated():
		return Vector2.ZERO
	var dx := 0.0
	var dy := 0.0
	if Input.is_action_pressed("move_left"):
		dx -= 1.0
	if Input.is_action_pressed("move_right"):
		dx += 1.0
	if Input.is_action_pressed("move_up"):
		dy -= 1.0
	if Input.is_action_pressed("move_down"):
		dy += 1.0
	if dx != _last_sent_dx or dy != _last_sent_dy:
		NetworkClient.send_message({"type": "move", "dx": dx, "dy": dy})
		_last_sent_dx = dx
		_last_sent_dy = dy
	return Vector2(dx, dy)

## Advances _predicted_pos by one tick of local prediction (60 Hz, delta-
## based -- decoupled from when `move` messages are actually sent) using
## ShipClassData.step_walk, the same per-axis circle-vs-tile math the server
## runs. Only the own character while standing is predicted; seated (move
## input is ignored server-side, and the seated position is a server snap
## to the console tile center anyway) or without character/class data yet,
## prediction is paused and restarts from the server position outright the
## next time it's needed (no continuity across a sit/stand/board gap).
func _update_own_prediction(move_input: Vector2, delta: float) -> void:
	var own_char := _own_character()
	if own_char == null or own_char.is_seated() or _ship_class == null:
		_predicting = false
		return
	if not _predicting:
		_predicted_pos = own_char.position()
		_predicting = true
	_predicted_pos = ShipClassData.step_walk(
		_ship_class, _predicted_pos.x, _predicted_pos.y, move_input.x, move_input.y, delta)

func _toggle_dock() -> void:
	if not NetworkClient.logged_in:
		return
	var own := _own_ship()
	if own != null and own.is_docked():
		NetworkClient.send_message({"type": "undock"})
	else:
		NetworkClient.send_message({"type": "dock"})

## `E`: sit at the nearest in-range console, or stand if already seated.
func _handle_interact() -> void:
	if not NetworkClient.logged_in:
		return
	var own_char := _own_character()
	if own_char == null:
		return
	if own_char.is_seated():
		NetworkClient.send_message({"type": "stand"})
	else:
		var console := _nearest_console_in_range(own_char)
		if console != null:
			NetworkClient.send_message({"type": "sit", "console": console.id})

## `B`: board the first other ship in the latest snapshot docked at the
## same station as ours.
func _handle_board() -> void:
	if not NetworkClient.logged_in:
		return
	var own := _own_ship()
	if own == null:
		return
	var target := _first_boardable_ship(own)
	if target != null:
		NetworkClient.send_message({"type": "board", "ship_id": target.id})

func _own_ship() -> ShipState:
	for ship in _ships:
		if ship.id == _ship_id:
			return ship
	return null

func _own_character() -> CharacterState:
	for character in _characters:
		if character.id == _character_id:
			return character
	return null

## Live seat truth: is our character currently seated at a helm-kind
## console? Falls back to the current view mode while we have no character
## data yet (right after welcome, before the first `interior` message --
## login spawns us seated at the helm, and welcome sets SYSTEM, so helm
## controls work immediately, exactly as in M1).
func _seated_at_helm() -> bool:
	var own_char := _own_character()
	if own_char == null:
		return _view_mode == ViewMode.SYSTEM
	if not own_char.is_seated():
		return false
	var console := _ship_class.find_console(own_char.seat) if _ship_class != null else null
	return console != null and console.kind == "helm"

## The first other ship (by snapshot order) docked at the same station as
## `own`, or null. `own` must itself be docked.
func _first_boardable_ship(own: ShipState) -> ShipState:
	if not own.is_docked():
		return null
	for ship in _ships:
		if ship.id != own.id and ship.docked_at == own.docked_at:
			return ship
	return null

## The nearest console to `own_char` within SIT_RANGE_TILES, or null. Used
## both to decide what `E` sits at and to show the sit prompt; the server
## re-checks range authoritatively.
func _nearest_console_in_range(own_char: CharacterState) -> ShipClassData.Console:
	if _ship_class == null:
		return null
	var pos := own_char.position()
	var nearest: ShipClassData.Console = null
	var nearest_dist := SIT_RANGE_TILES
	for console in _ship_class.consoles:
		var dist := pos.distance_to(console.tile_center())
		if dist <= nearest_dist:
			nearest_dist = dist
			nearest = console
	return nearest

## Label for a console in status-label prompts: its room's name if it's
## inside one (e.g. "Helm"), else its kind, capitalized.
func _console_label(console: ShipClassData.Console) -> String:
	if _ship_class != null:
		var room := _ship_class.room_at(console.x, console.y)
		if room != null:
			return room.name
	return console.kind.capitalize()

## Seconds of wall-clock time elapsed since the latest snapshot, capped so a
## stalled connection can't extrapolate forever.
func _seconds_since_snapshot() -> float:
	return minf(float(Time.get_ticks_msec() - _snapshot_ticks_msec) / 1000.0, MAX_EXTRAPOLATION_SEC)

## Sim time for rail math: last snapshot's tick, advanced by the (capped)
## wall-clock time elapsed since it arrived, converted to seconds via dt.
func _sim_time() -> float:
	return (float(_snapshot_tick) + TICKS_PER_SEC * _seconds_since_snapshot()) * _dt

func _update_world_view() -> void:
	var elapsed := _seconds_since_snapshot()
	var t := _sim_time()
	var extrapolated: Array[ShipState] = []
	var own_pos := Vector2.ZERO
	var own_found := false
	var own_undocked := true
	for ship in _ships:
		var e := ship.extrapolated(elapsed)
		extrapolated.append(e)
		if e.id == _ship_id:
			own_pos = e.position()
			own_found = true
			own_undocked = not e.is_docked()
	if not own_found and _world != null and _world.spawn_station != "":
		# No snapshot with our ship yet: center on the spawn station so the
		# view isn't empty while we wait.
		own_pos = _world.station_position(_world.spawn_station, t)
	_world_view.set_frame_data(_world, t, extrapolated, _ship_id, _zoom, own_pos, own_undocked)

## Own character (while _predicting, i.e. standing) draws at the locally-
## predicted position; while seated (or before prediction has (re)started)
## it draws at the server position directly, which is exactly right then
## since a seated character doesn't move. Every other character draws at a
## delayed, interpolated position from _interior_history. Neither path
## velocity-extrapolates -- that was the snap-back bug (walkers stop/turn
## instantly server-side, but a stale velocity kept extrapolating until the
## next `interior` corrected it).
func _update_interior_view() -> void:
	var render_msec := Time.get_ticks_msec() - int(OTHER_CHAR_INTERP_DELAY_SEC * 1000.0)
	var rendered: Array[CharacterState] = []
	for character in _characters:
		if character.id == _character_id:
			rendered.append(_predicted_character_state(character) if _predicting else character)
		else:
			rendered.append(_interpolated_character_state(character, render_msec))
	_interior_view.set_frame_data(_ship_class, rendered, _character_id)

## Copy of `server_char` with position replaced by the locally-predicted
## position.
func _predicted_character_state(server_char: CharacterState) -> CharacterState:
	var out := CharacterState.new()
	out.id = server_char.id
	out.name = server_char.name
	out.seat = server_char.seat
	out.x = _predicted_pos.x
	out.y = _predicted_pos.y
	return out

## Copy of `server_char` (latest known name/seat) with position replaced by
## its delayed-interpolated position at `render_msec` -- see
## _interpolated_other_position for the interpolation itself.
func _interpolated_character_state(server_char: CharacterState, render_msec: int) -> CharacterState:
	var out := CharacterState.new()
	out.id = server_char.id
	out.name = server_char.name
	out.seat = server_char.seat
	var pos := _interpolated_other_position(server_char.id, render_msec)
	out.x = pos.x
	out.y = pos.y
	return out

## Interpolated position for `character_id` at `render_msec`, from
## _interior_history: finds the two buffered messages bracketing
## render_msec (the last one at or before it, and the first one after) and
## linearly interpolates the character's position between them -- but only
## when both share the character at the same seat state. A sit/stand
## transition snaps to the console tile server-side, so if the seat differs
## between the bracketing pair there was no continuous walk to interpolate;
## that (and a character present in only one side of the bracket -- buffer
## too short, or a fresh board/disconnect) falls through to holding the
## single known position instead of interpolating or extrapolating past it.
func _interpolated_other_position(character_id: int, render_msec: int) -> Vector2:
	var before: Dictionary = {}
	var after: Dictionary = {}
	for entry in _interior_history:
		if int(entry["arrival_msec"]) <= render_msec:
			before = entry
		elif after.is_empty():
			after = entry
	var before_char: CharacterState = (
		_find_character(before["characters"], character_id) if not before.is_empty() else null)
	var after_char: CharacterState = (
		_find_character(after["characters"], character_id) if not after.is_empty() else null)
	if before_char != null and after_char != null and before_char.seat == after_char.seat:
		var before_msec := int(before["arrival_msec"])
		var after_msec := int(after["arrival_msec"])
		var span := float(after_msec - before_msec)
		var t := 1.0 if span <= 0.0 else clampf(float(render_msec - before_msec) / span, 0.0, 1.0)
		return before_char.position().lerp(after_char.position(), t)
	if after_char != null:
		return after_char.position()
	if before_char != null:
		return before_char.position()
	# Not buffered yet (e.g. the very first interior for a new ship, mid-
	# processing) -- fall back to whatever _characters currently has.
	var current := _find_character(_characters, character_id)
	return current.position() if current != null else Vector2.ZERO

## The view mode driven by our own character's seat: seated at a helm-kind
## console is SYSTEM, everything else (standing, or seated at e.g. cargo)
## is INTERIOR. Stays at the current mode if we don't have character data
## yet (`_seated_at_helm()` falls back to the current view mode then).
func _compute_target_mode() -> ViewMode:
	return ViewMode.SYSTEM if _seated_at_helm() else ViewMode.INTERIOR

## Advances the INTERIOR<->SYSTEM crossfade/zoom transition, starting a new
## one when our seat state implies a different mode than the one currently
## shown. A transition in flight runs to completion before reacting to a
## further mode change (good enough for M2; rapid sit/stand spam isn't a
## case we need to handle smoothly).
func _update_view_mode(delta: float) -> void:
	var target := _compute_target_mode()
	if not _transitioning and target != _view_mode:
		_transitioning = true
		_transition_from = _view_mode
		_transition_to = target
		_transition_elapsed = 0.0
	if _transitioning:
		_transition_elapsed += delta
		var progress := clampf(_transition_elapsed / ZOOM_TRANSITION_SEC, 0.0, 1.0)
		_apply_transition_visuals(progress)
		if progress >= 1.0:
			_transitioning = false
			_view_mode = _transition_to
			_snap_view_visuals()
	else:
		_snap_view_visuals()

## `progress` 0 -> fully showing `_transition_from`, 1 -> fully showing
## `_transition_to`. Both views render continuously; a scale ramp on top of
## the alpha crossfade sells the "camera zoom" the spec asks for (DESIGN.md:
## "'zoom' is really a view/control mode switch, presented as a smooth
## camera zoom").
func _apply_transition_visuals(progress: float) -> void:
	var eased := smoothstep(0.0, 1.0, progress)
	var to_interior := _transition_to == ViewMode.INTERIOR
	var interior_alpha := eased if to_interior else 1.0 - eased
	var interior_scale := lerpf(0.85, 1.0, eased) if to_interior else lerpf(1.0, 0.85, eased)
	var system_scale := lerpf(1.0, 1.15, eased) if to_interior else lerpf(1.15, 1.0, eased)
	_set_view_zoom(_interior_view, interior_scale)
	_interior_view.modulate.a = interior_alpha
	_interior_view.visible = interior_alpha > 0.001
	_set_view_zoom(_world_view, system_scale)
	_world_view.modulate.a = 1.0 - interior_alpha
	_world_view.visible = (1.0 - interior_alpha) > 0.001

## Scales a view about the *screen center* rather than the node origin:
## both views draw in viewport pixel coordinates with (0,0) at the top-left,
## so a bare `scale` would slide everything toward/away from that corner.
## Offsetting the node position by `center * (1 - scale)` keeps the point
## under the screen center fixed, so the transition reads as a camera zoom.
func _set_view_zoom(view: Node2D, view_scale: float) -> void:
	var center := get_viewport_rect().size * 0.5
	view.scale = Vector2.ONE * view_scale
	view.position = center * (1.0 - view_scale)

## Snaps both views to the steady-state (non-transitioning) visuals for the
## current `_view_mode`: the active view fully opaque at scale 1, the other
## hidden.
func _snap_view_visuals() -> void:
	var interior_active := _view_mode == ViewMode.INTERIOR
	_set_view_zoom(_interior_view, 1.0)
	_interior_view.modulate.a = 1.0 if interior_active else 0.0
	_interior_view.visible = interior_active
	_set_view_zoom(_world_view, 1.0)
	_world_view.modulate.a = 0.0 if interior_active else 1.0
	_world_view.visible = not interior_active

## Current view mode as a string for the automation hook's state dump
## ("interior" | "system" | "transition"). Public so automation_server.gd
## doesn't need to know the ViewMode enum's internal representation.
func view_mode_name() -> String:
	if _transitioning:
		return "transition"
	return "interior" if _view_mode == ViewMode.INTERIOR else "system"

func _on_snapshot_received(tick: int, ships: Array[ShipState]) -> void:
	_ships = ships
	_snapshot_tick = tick
	_snapshot_ticks_msec = Time.get_ticks_msec()

## Stores the latest crew list and buffers it (with wall-clock arrival
## time) into _interior_history for _interpolated_other_position, then
## reconciles the own-character prediction against the freshly-reported
## server position. Interiors for other ships are ignored: a message
## serialized just before our `board` landed can still arrive for the ship
## we just left.
func _on_interior_received(_tick: int, ship_id: int, characters: Array[CharacterState]) -> void:
	if ship_id != _ship_id:
		return
	_characters = characters
	_interior_history.append({"arrival_msec": Time.get_ticks_msec(), "characters": characters})
	while _interior_history.size() > INTERIOR_HISTORY_SIZE:
		_interior_history.pop_front()
	_reconcile_own_prediction()

## Softly pulls the predicted own-character position toward the position
## this `interior` message just reported for it (correction =
## (server - predicted) * OWN_PREDICTION_CORRECTION), or hard-snaps to the
## server position if prediction has drifted more than
## OWN_PREDICTION_SNAP_TILES away -- e.g. a `move` that raced a wall the
## server saw slightly differently. A no-op while prediction isn't running
## (seated, or not yet (re)started after a stand/board): _update_own_prediction
## resets outright from the server position in that case instead, so there's
## nothing to correct.
func _reconcile_own_prediction() -> void:
	if not _predicting:
		return
	var own_char := _own_character()
	if own_char == null or own_char.is_seated():
		return
	var server_pos := own_char.position()
	var diff := server_pos - _predicted_pos
	if diff.length() > OWN_PREDICTION_SNAP_TILES:
		_predicted_pos = server_pos
	else:
		_predicted_pos += diff * OWN_PREDICTION_CORRECTION

func _find_character(list: Array[CharacterState], id: int) -> CharacterState:
	for character in list:
		if character.id == id:
			return character
	return null

func _on_connection_state_changed(_state: NetworkClient.ConnectionState) -> void:
	_update_status_label()

func _on_welcome_received(ship_id: int, world: WorldData) -> void:
	_ship_id = ship_id
	_world = world
	_dt = NetworkClient.dt
	_character_id = NetworkClient.character_id
	_ship_class = NetworkClient.ship_class
	_characters = []
	_interior_history = []
	# No continuity across a fresh login: prediction restarts from the
	# server position outright the next time _update_own_prediction runs.
	_predicting = false
	# Reset so the next real input still gets sent even if it happens to
	# match whatever was last sent to a previous ship/session.
	_last_sent_rotate = 0.0
	_last_sent_thrust = 0.0
	_last_sent_dx = 0.0
	_last_sent_dy = 0.0
	# Login spawns us seated at the helm (spec: M2 ship interior design,
	# "Login embodiment"): start in SYSTEM view exactly like M1, no
	# transition animation.
	_transitioning = false
	_view_mode = ViewMode.SYSTEM
	_snap_view_visuals()

func _on_dock_result_received(ok: bool, reason: Variant) -> void:
	if not ok:
		_show_transient_message("dock failed: %s" % str(reason))

func _on_seat_result_received(ok: bool, reason: Variant, _seat: Variant) -> void:
	if not ok:
		_show_transient_message("seat failed: %s" % str(reason))

## On `ok`, NetworkClient.ship_id has already been updated (it's the wire
## authority); mirror it into our local copy so status-label/board logic
## sees the new ship immediately. Also clear the old ship's crew and
## interior history (same reset `_on_welcome_received` does), since board
## keeps them stale otherwise: the old crew would render on the new deck
## for a frame, and _interpolated_other_position could bracket across the
## ship change and interpolate a spurious lurch between the old seated
## position and the new spawn-tile one.
func _on_board_result_received(ok: bool, reason: Variant, ship_id: int) -> void:
	if ok:
		_ship_id = ship_id
		_characters = []
		_interior_history = []
		# No continuity across a ship change: prediction restarts from the
		# server position outright the next time _update_own_prediction runs.
		_predicting = false
	else:
		_show_transient_message("board failed: %s" % str(reason))

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

	lines.append("view: %s" % view_mode_name())

	var own := _own_ship()
	if own != null:
		lines.append("speed %.1f u/s" % own.velocity().length())
		if own.is_docked():
			lines.append("docked at %s" % _station_name(own.docked_at))
		elif _view_mode == ViewMode.SYSTEM:
			var near := _nearest_dockable_station_name()
			if near != "":
				lines.append("SPACE: dock at %s" % near)

	var own_char := _own_character()
	if own_char != null:
		if own_char.is_seated():
			lines.append("E: stand")
		else:
			var console := _nearest_console_in_range(own_char)
			if console != null:
				lines.append("E: sit at %s" % _console_label(console))

	if own != null:
		var target := _first_boardable_ship(own)
		if target != null:
			lines.append("B: board ship #%d" % target.id)

	if _transient_message != "" and Time.get_ticks_msec() < _transient_expire_msec:
		lines.append(_transient_message)

	_status_label.text = "\n".join(lines)

func _station_name(station_id: String) -> String:
	if _world == null:
		return station_id
	return _world.station_name(station_id)

## The name of a station whose dock_radius currently contains our (raw,
## last-snapshot) position, or "" if none. Used only for the status-label
## prompt; the server is the authority on whether a `dock` actually lands.
func _nearest_dockable_station_name() -> String:
	var own := _own_ship()
	if own == null or own.is_docked() or _world == null:
		return ""
	var own_pos := own.position()
	var t := _sim_time()
	for station in _world.stations:
		var pos := _world.station_position(station.id, t)
		if own_pos.distance_to(pos) <= station.dock_radius:
			return station.name
	return ""
