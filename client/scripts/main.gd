extends Node2D
## M2 scene: flies one player-controlled ship around the pinned system, and
## (new in M2) walks its interior deck as a character.
##
## Networking/protocol lives in the NetworkClient autoload; rail + ship
## rendering lives in the WorldView child node (world_view.gd); deck-plan +
## character rendering lives in the InteriorView child node
## (interior_view.gd). This script wires it all together: it owns login
## bookkeeping, helm/dock/move/sit input, the view-mode state machine
## (SYSTEM at the helm <-> INTERIOR standing, with an animated zoom +
## crossfade between them), camera zoom, and the status label.
##
## Snapshots and interior updates arrive at 15 Hz; between messages ship and
## character positions (and rail positions, via sim time `t`) are
## extrapolated at render framerate the same way M0 did for its dot-cloud,
## capped so a stalled connection doesn't fling anything off into the void.

const BACKGROUND_COLOR := Color(0.03, 0.04, 0.08)

## THE WINDOW (M3.5): while on foot, the system view stays visible under the
## deck plan at this cool dim tint — space through hull glass.
const WINDOW_DIM := Color(0.42, 0.47, 0.58)
const MAX_EXTRAPOLATION_SEC := 0.5
const TICKS_PER_SEC := 60.0

const ZOOM_MIN := 0.02
const ZOOM_MAX := 2.0
const ZOOM_STEP := 1.15
const DEFAULT_ZOOM := 0.5  # M3.5: sprites read at this height (ships clamp to full px)

## Event feed (trades, failures, eventual player chat) lives in the ChatLog
## label at the bottom-left, scrolling upward, so it never overlays the
## status label (top-left) or the trade panel (top-right). Oldest lines are
## dropped past this cap.
const CHAT_LOG_MAX_LINES := 8

## Chat/log messages fade out over time so the feed self-clears (issue #16).
## A message stays fully opaque for CHAT_MESSAGE_HOLD_SEC after it arrives,
## then its opacity ramps to 0 over the next CHAT_MESSAGE_FADE_SEC, after
## which it's dropped from the log. Ages are wall-clock (Time.get_ticks_msec,
## the same source as the interior-history arrival stamps), so the fade is
## time-based and independent of how many messages arrive or the framerate.
const CHAT_MESSAGE_HOLD_SEC := 10.0
const CHAT_MESSAGE_FADE_SEC := 2.5

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

## Rails (stations/planets) are drawn at a *smoothed* sim time rather than
## the raw `_sim_time()`: the raw clock hard-resets to the server tick on
## every snapshot arrival, so network jitter makes it non-monotonic and
## rail-riding bodies visibly stutter — most obviously next to the own
## docked ship, which is dead-reckoned from its snapshot velocity and so
## stays smooth. Each frame the smoothed clock advances by wall-clock delta
## and is pulled toward the raw clock by this fraction (the same soft-
## correction idiom as OWN_PREDICTION_CORRECTION), or hard-snapped if it
## has drifted more than SIM_TIME_SNAP_SEC (e.g. a reconnect or a long
## stall — no point easing across seconds).
const SIM_TIME_CORRECTION := 0.1
const SIM_TIME_SNAP_SEC := 0.5

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

var _characters: Array[CharacterState] = []  # latest walkers message's crew

## Recent `walkers` messages for our current space, each tagged with the
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

## The walkable space we're currently in (M3.1): mirror of NetworkClient.space,
## kept locally like _ship_id. Null until the first `space` message arrives.
var _space: SpaceData = null
## Latest cargo state for our ship (wallet/hold/transfers), null pre-M3
## server or before the first message.
var _cargo: CargoState = null
## Latest market for the station we're at (null until one arrives).
var _market: MarketData = null

## Smoothed sim time for rail rendering (see SIM_TIME_CORRECTION). Invalid
## until the first frame after a snapshot has arrived.
var _render_sim_time: float = 0.0
var _render_sim_time_valid: bool = false

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

## Chat/log feed, oldest first. Each entry is `{"text": String,
## "arrival_msec": int}`; arrival_msec (Time.get_ticks_msec at append) drives
## the time-based fade in _update_chat_fade. Capped to CHAT_LOG_MAX_LINES.
var _chat_messages: Array[Dictionary] = []

## "buy" or "sell" while a trade request is in flight, so the next
## `trade_result` (which doesn't echo the direction) can be worded
## correctly. Fine as a single slot: trades are request/reply over one
## connection, and a stale verb only ever mislabels a message, never a
## trade.
var _pending_trade_verb: String = ""

## Predicted position of the own character while standing (tile units,
## current-space-local -- same frame as CharacterState.position()). Valid
## only while _predicting is true; reset to the server position outright
## whenever prediction (re)starts, e.g. right after login/stand/a space
## rebuild, since there's no continuity to build on then.
var _predicted_pos: Vector2 = Vector2.ZERO
var _predicting: bool = false
## Predicted deck of the own character (split-level plans): advances with
## step_walk's center-tile rule, seeded from the server on every space
## message, adopted from the server on a hard prediction snap.
var _predicted_deck: int = 0

## 0 = fully system view, 1 = fully interior; eased across the transition.
## Drives THE WINDOW's matched zoom blend and WorldView's interior mode.
var _interior_weight: float = 0.0

## Highlighted row in the trade panel while at a broker (clamped to
## _market.stores' bounds each render; meaningless at the read-only cargo
## console, where the panel draws no cursor).
var _trade_selection: int = 0

@onready var _status_label: Label = %StatusLabel
@onready var _world_view: WorldView = %WorldView
@onready var _interior_view: InteriorView = %InteriorView
@onready var _trade_panel: Label = %TradePanel
@onready var _chat_log: Label = %ChatLog

## The Rijay main menu (null when cmdline creds auto-login, e.g. automation).
var _menu: MainMenu = null

func _ready() -> void:
	RenderingServer.set_default_clear_color(BACKGROUND_COLOR)
	NetworkClient.snapshot_received.connect(_on_snapshot_received)
	NetworkClient.connection_state_changed.connect(_on_connection_state_changed)
	NetworkClient.welcome_received.connect(_on_welcome_received)
	NetworkClient.dock_result_received.connect(_on_dock_result_received)
	NetworkClient.error_received.connect(_on_error_received)
	NetworkClient.seat_result_received.connect(_on_seat_result_received)
	NetworkClient.space_received.connect(_on_space_received)
	NetworkClient.walkers_received.connect(_on_walkers_received)
	NetworkClient.cargo_received.connect(_on_cargo_received)
	NetworkClient.market_received.connect(_on_market_received)
	NetworkClient.trade_result_received.connect(_on_trade_result_received)
	# M3.5 UI shell: the game shell speaks Rijay — amber terminal HUD.
	UiTheme.skin_label(_status_label, 24, UiTheme.AMBER, UiTheme.AMBER_DIM)
	UiTheme.skin_label(_chat_log, 20, UiTheme.AMBER_DIM)
	UiTheme.skin_label(_trade_panel, 20, UiTheme.AMBER, UiTheme.CONSOLE_ORANGE)
	if NetworkClient.manual_login:
		_menu = MainMenu.new()
		add_child(_menu)
	_snap_view_visuals()
	_update_status_label()

func _physics_process(delta: float) -> void:
	if _menu != null and _menu.visible:
		return  # the login terminal owns input until we're aboard
	_poll_helm_input()
	var move_input := _poll_move_input()
	_update_own_prediction(move_input, delta)

func _process(delta: float) -> void:
	_advance_render_sim_time(delta)
	_update_view_mode(delta)
	_update_status_label()
	_update_world_view()
	_update_interior_view()
	_update_trade_panel()
	_update_chat_fade()

func _unhandled_input(event: InputEvent) -> void:
	if _menu != null and _menu.visible:
		return  # the login terminal owns input until we're aboard
	if _at_broker() and event is InputEventKey and event.pressed and not event.echo:
		if _handle_trade_input(event):
			get_viewport().set_input_as_handled()
			return
	if event.is_action_pressed("toggle_dock"):
		_toggle_dock()
	elif event.is_action_pressed("interact"):
		_handle_interact()
	elif event.is_action_pressed("toggle_viewcone"):
		_interior_view.view_cone_enabled = not _interior_view.view_cone_enabled
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
## next time it's needed (no continuity across a sit/stand/space-rebuild gap).
func _update_own_prediction(move_input: Vector2, delta: float) -> void:
	var own_char := _own_character()
	var plan := _current_plan()
	if own_char == null or own_char.is_seated() or plan == null:
		_predicting = false
		return
	if not _predicting:
		_predicted_pos = own_char.position()
		_predicted_deck = own_char.deck
		_predicting = true
	var stepped := ShipClassData.step_walk(
		plan, _predicted_deck, _predicted_pos.x, _predicted_pos.y,
		move_input.x, move_input.y, delta)
	_predicted_pos = stepped["pos"]
	_predicted_deck = stepped["deck"]

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

## Returns true if the key drove the trade panel. W/S move the selection,
## D buys 1, A sells 1, Shift multiplies by 10. Quantities are JSON ints
## (the server decoder rejects floats here).
func _handle_trade_input(event: InputEventKey) -> bool:
	if _market == null or _market.stores.is_empty():
		return false
	var quantity := 10 if event.shift_pressed else 1
	match event.physical_keycode:
		KEY_W, KEY_UP:
			_trade_selection = maxi(0, _trade_selection - 1)
			return true
		KEY_S, KEY_DOWN:
			_trade_selection = mini(_market.stores.size() - 1, _trade_selection + 1)
			return true
		KEY_D, KEY_RIGHT:
			var store := _market.stores[_trade_selection]
			_pending_trade_verb = "buy"
			NetworkClient.send_message({"type": "buy", "commodity": store.commodity, "quantity": quantity})
			return true
		KEY_A, KEY_LEFT:
			var sell_store := _market.stores[_trade_selection]
			_pending_trade_verb = "sell"
			NetworkClient.send_message({"type": "sell", "commodity": sell_store.commodity, "quantity": quantity})
			return true
	return false

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

## The deck plan under our feet: whatever the last `space` message said.
## Falls back to the ship class before the first space arrives (welcome
## and space race by one frame at login).
func _current_plan() -> ShipClassData:
	if _space != null and _space.plan != null:
		return _space.plan
	return _ship_class

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
	var plan := _current_plan()
	var console := plan.find_console(own_char.seat) if plan != null else null
	return console != null and console.kind == "helm"

## The kind of console our character is seated at on the current plan, or
## "" while standing / before data arrives.
func _seated_console_kind() -> String:
	var own_char := _own_character()
	var plan := _current_plan()
	if own_char == null or not own_char.is_seated() or plan == null:
		return ""
	var console := plan.find_console(own_char.seat)
	return console.kind if console != null else ""


## Interactive trading: seated at a broker on a concourse.
func _at_broker() -> bool:
	return _seated_console_kind() == "broker"


## The trade panel is visible at a broker (interactive) and at the ship's
## cargo console (read-only manifest -- M3's binding of the M2 console).
func _trade_panel_open() -> bool:
	var kind := _seated_console_kind()
	return kind == "broker" or kind == "cargo"

## The nearest console to `own_char` within SIT_RANGE_TILES, or null. Used
## both to decide what `E` sits at and to show the sit prompt; the server
## re-checks range authoritatively.
func _nearest_console_in_range(own_char: CharacterState) -> ShipClassData.Console:
	var plan := _current_plan()
	if plan == null:
		return null
	var pos := own_char.position()
	var nearest: ShipClassData.Console = null
	var nearest_dist := SIT_RANGE_TILES
	for console in plan.consoles:
		# Only consoles on the same deck are reachable, and a docking port is
		# an airlock, not a seat — skip both (the server rejects them anyway).
		if console.deck != own_char.deck or console.kind == "dock":
			continue
		var dist := pos.distance_to(console.tile_center())
		if dist <= nearest_dist:
			nearest_dist = dist
			nearest = console
	return nearest

## Label for a console in status-label prompts: its kind, capitalized
## (e.g. "Helm", "Cargo", "Broker", "Dock").
func _console_label(console: ShipClassData.Console) -> String:
	return console.kind.capitalize()

## Seconds of wall-clock time elapsed since the latest snapshot, capped so a
## stalled connection can't extrapolate forever.
func _seconds_since_snapshot() -> float:
	return minf(float(Time.get_ticks_msec() - _snapshot_ticks_msec) / 1000.0, MAX_EXTRAPOLATION_SEC)

## Raw sim time: last snapshot's tick, advanced by the (capped) wall-clock
## time elapsed since it arrived, converted to seconds via dt. Non-monotonic
## across snapshot arrivals (network jitter) — render rails at
## _render_sim_time, not this.
func _sim_time() -> float:
	return (float(_snapshot_tick) + TICKS_PER_SEC * _seconds_since_snapshot()) * _dt

## Advances the smoothed rail clock by one frame: forward by wall-clock
## delta, then softly toward the raw clock (or a hard snap past
## SIM_TIME_SNAP_SEC of drift) — see SIM_TIME_CORRECTION for why.
func _advance_render_sim_time(delta: float) -> void:
	var raw := _sim_time()
	if not _render_sim_time_valid:
		_render_sim_time = raw
		_render_sim_time_valid = true
		return
	_render_sim_time += delta
	var drift := raw - _render_sim_time
	if absf(drift) > SIM_TIME_SNAP_SEC:
		_render_sim_time = raw
	else:
		_render_sim_time += drift * SIM_TIME_CORRECTION

func _update_world_view() -> void:
	var elapsed := _seconds_since_snapshot()
	var t := _render_sim_time
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
	# THE WINDOW's matched zoom: while on foot the space outside renders at
	# the interior's scale (interior tiles fit the hull sprite), blended
	# geometrically across the view transition so the crossfade reads as
	# one continuous camera move.
	var w := _interior_weight
	var zoom_now := _zoom
	if w > 0.001:
		var matched := _matched_interior_zoom()
		zoom_now = exp(lerpf(log(_zoom), log(matched), w))
	var interior_mode := w > 0.5
	var suppress_station := ""
	var suppress_ship := -1
	if _space != null and _space.is_station():
		suppress_station = _space.station_id()
	elif _space != null and _space.is_ship():
		suppress_ship = _ship_id
	_world_view.set_frame_data(
		_world, t, extrapolated, _ship_id, zoom_now, own_pos, own_undocked,
		_last_sent_thrust, interior_mode, suppress_station, suppress_ship)


## The world-view zoom at which hull sprites render at the interior's tile
## scale (64 px tiles over 3 px/tile sprites). Station scale while docked,
## ship scale aboard; falls back to the user zoom before data arrives.
func _matched_interior_zoom() -> float:
	if _space != null and _space.is_station():
		return _world_view.matched_zoom_station(_space.station_id(), _zoom)
	return _world_view.matched_zoom_ship(_zoom)

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
			rendered.append(_predicted_character_state(character))
		else:
			rendered.append(_interpolated_character_state(character, render_msec))
	_interior_view.set_frame_data(
		_current_plan(), rendered, _character_id, _own_render_position(),
		_own_view_deck(), _interior_backdrops())


## The deck the interior renders from: predicted while walking, server
## truth otherwise.
func _own_view_deck() -> int:
	if _predicting:
		return _predicted_deck
	var own_char := _own_character()
	if own_char != null:
		return own_char.deck
	return _space.you_deck if _space != null else 0


## Exterior-sprite backdrops for every hull in the current space: the
## station concourse bar (anchored by the space message's concourse
## offset), each moored ship, or the flying ship itself. Every hull is a
## Mockingbird until M4.
func _interior_backdrops() -> Array[InteriorView.Backdrop]:
	var out: Array[InteriorView.Backdrop] = []
	if _space == null:
		if _ship_class != null:
			out.append(InteriorView.Backdrop.make(
				"ship", "mockingbird_interior", Vector2.ZERO))
		return out
	if _space.is_station():
		if _space.has_concourse and _world != null:
			for station in _world.stations:
				if station.id == _space.station_id():
					var archetype := "ring_3berth_crane_interior" \
						if station.crane else "ring_1berth_interior"
					out.append(InteriorView.Backdrop.make("station", archetype,
						Vector2(_space.concourse_dx, _space.concourse_dy)))
		for mooring in _space.moorings:
			# Moored ships lie side-on (the composite rotates their plans).
			out.append(InteriorView.Backdrop.make(
				"ship", "mockingbird_interior",
				Vector2(mooring.dx, mooring.dy), true))
	elif _space.is_ship():
		out.append(InteriorView.Backdrop.make(
			"ship", "mockingbird_interior", Vector2.ZERO))
	return out

## Where our own character renders this frame (predicted while walking,
## server truth otherwise) - also the interior camera's focus.
func _own_render_position() -> Vector2:
	if _predicting:
		return _predicted_pos
	var own_char := _own_character()
	return own_char.position() if own_char != null else Vector2.ZERO

## Copy of `server_char` with position replaced by _own_render_position().
func _predicted_character_state(server_char: CharacterState) -> CharacterState:
	var out := CharacterState.new()
	out.id = server_char.id
	out.name = server_char.name
	out.seat = server_char.seat
	out.deck = _predicted_deck if _predicting else server_char.deck
	var pos := _own_render_position()
	out.x = pos.x
	out.y = pos.y
	return out

## Copy of `server_char` (latest known name/seat) with position replaced by
## its delayed-interpolated position at `render_msec` -- see
## _interpolated_other_position for the interpolation itself.
func _interpolated_character_state(server_char: CharacterState, render_msec: int) -> CharacterState:
	var out := CharacterState.new()
	out.id = server_char.id
	out.name = server_char.name
	out.seat = server_char.seat
	out.deck = server_char.deck
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
	_interior_weight = interior_alpha
	var interior_scale := lerpf(0.85, 1.0, eased) if to_interior else lerpf(1.0, 0.85, eased)
	var system_scale := lerpf(1.0, 1.15, eased) if to_interior else lerpf(1.15, 1.0, eased)
	_set_view_zoom(_interior_view, interior_scale)
	_interior_view.modulate.a = interior_alpha
	_interior_view.visible = interior_alpha > 0.001
	_set_view_zoom(_world_view, system_scale)
	# THE WINDOW (M3.5): the system view never fades out — while on foot it
	# stays visible beneath the deck plan, dimmed, and shows through wherever
	# the interior has no floor (void tiles paint nothing). Walking the hold
	# while a station slides past outside is the payoff (docs/visuals.md).
	_world_view.modulate = Color.WHITE.lerp(WINDOW_DIM, interior_alpha)
	_world_view.visible = true

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
	_interior_weight = 1.0 if interior_active else 0.0
	_set_view_zoom(_interior_view, 1.0)
	_interior_view.modulate.a = 1.0 if interior_active else 0.0
	_interior_view.visible = interior_active
	_set_view_zoom(_world_view, 1.0)
	_world_view.modulate = WINDOW_DIM if interior_active else Color.WHITE
	_world_view.visible = true

## Current view mode as a string for the automation hook's state dump
## ("interior" | "system" | "transition"). Public so automation_server.gd
## doesn't need to know the ViewMode enum's internal representation.
func view_mode_name() -> String:
	if _transitioning:
		return "transition"
	return "interior" if _view_mode == ViewMode.INTERIOR else "system"

## Public for the automation hook, like view_mode_name().
func trade_panel_open() -> bool:
	return _trade_panel_open()

func _on_snapshot_received(tick: int, ships: Array[ShipState]) -> void:
	_ships = ships
	_snapshot_tick = tick
	_snapshot_ticks_msec = Time.get_ticks_msec()

## A new plan under our feet (login, dock, undock, or another ship's
## mooring appearing/leaving): adopt it and restart prediction and
## interpolation from scratch. The frame may have shifted, so our own
## position comes from the message's `you` block; the crew list refills
## on the next `walkers`. Seed _characters with ourselves so the renderer
## and input logic never see an empty frame.
func _on_space_received(space: SpaceData) -> void:
	_space = space
	# A "ship:N" space is authoritative crew membership: if a crew transfer
	# carried us onto another crew's ship (undock "shanghai"), adopt N so
	# cargo routing and _own_ship() follow us to the ship we're now aboard.
	if space.is_ship():
		_ship_id = space.ship_id()
	var me := CharacterState.new()
	me.id = _character_id
	me.name = "you"
	me.x = space.you_x
	me.y = space.you_y
	me.deck = space.you_deck
	me.seat = "" if space.you_seat == null else str(space.you_seat)
	_characters = [me]
	_interior_history = []
	_predicting = false
	_predicted_pos = Vector2(space.you_x, space.you_y)
	_predicted_deck = space.you_deck
	# Stale panels from the previous space must not linger.
	_market = null

## Crew updates for our current space; frames tagged with another space
## or a previous epoch (in flight across a dock/undock rebuild) would
## place walkers in the wrong coordinate frame, so they're dropped.
func _on_walkers_received(_tick: int, space_id: String, epoch: int, characters: Array[CharacterState]) -> void:
	if _space == null or space_id != _space.id or epoch != _space.epoch:
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
## (seated, or not yet (re)started after a stand/space rebuild):
## _update_own_prediction resets outright from the server position in that
## case instead, so there's nothing to correct.
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
		# A hard snap means prediction diverged — adopt the server's deck
		# too (soft corrections keep the predicted deck: the server just
		# lags a stair crossing by a message interval).
		_predicted_deck = own_char.deck
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
	# A fresh login restarts sim time from the new server's clock: snap the
	# smoothed rail clock rather than easing across the discontinuity.
	_render_sim_time_valid = false
	_character_id = NetworkClient.character_id
	_ship_class = NetworkClient.ship_class
	_space = null
	_cargo = null
	_market = null
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
		_append_chat("dock failed: %s" % str(reason))

func _on_seat_result_received(ok: bool, reason: Variant, _seat: Variant) -> void:
	if not ok:
		_append_chat("seat failed: %s" % str(reason))
		return
	_trade_selection = 0
	if _trade_panel_open():
		NetworkClient.send_message({"type": "get_market"})

func _on_cargo_received(cargo: CargoState) -> void:
	if cargo.ship_id == _ship_id:
		_cargo = cargo


func _on_market_received(market: MarketData) -> void:
	_market = market


## Trade wording mirrors the server's settlement rules (cargo.gleam): a buy
## is paid in full at order time and the goods load aboard over the transfer
## (the "loading N x…" status line tracks it); a sell stages the goods on
## the ramp now and pays per unit as it lands on the dock.
func _on_trade_result_received(ok: bool, reason: Variant, commodity: String, quantity: int, price: int) -> void:
	var verb := _pending_trade_verb
	_pending_trade_verb = ""
	if not ok:
		_append_chat("trade failed: %s" % str(reason))
	elif verb == "sell":
		_append_chat("sold %d %s @ %d cr ea — paid per unit as it unloads" % [
			quantity, _commodity_name(commodity), price])
	else:
		_append_chat("bought %d %s @ %d cr ea (%d cr paid) — loading aboard" % [
			quantity, _commodity_name(commodity), price, quantity * price])

func _on_error_received(code: String, message: String) -> void:
	_append_chat("%s: %s" % [code, message])

## Display name for a commodity id, from the current market if it lists it.
func _commodity_name(commodity: String) -> String:
	if _market != null:
		for store in _market.stores:
			if store.commodity == commodity:
				return store.name
	return commodity

func _append_chat(message: String) -> void:
	_chat_messages.append({"text": message, "arrival_msec": Time.get_ticks_msec()})
	while _chat_messages.size() > CHAT_LOG_MAX_LINES:
		_chat_messages.remove_at(0)
	# A fresh message means the feed is active again: reset the log to fully
	# opaque now rather than waiting a frame for _update_chat_fade.
	_chat_log.modulate.a = 1.0
	_render_chat_log()

## Ages the chat feed each frame (see CHAT_MESSAGE_HOLD_SEC/FADE_SEC): drops
## fully-faded messages and drives the log's opacity. ChatLog is a single
## Label (one modulate for the whole node), so opacity is keyed to the NEWEST
## message — it holds fully opaque through the hold window, then ramps to 0
## over the fade window, which is exactly the "newest stays opaque, feed fades
## and clears once quiet" behaviour issue #16 asks for. Messages are removed
## individually by their own age, so removal never depends on message count.
func _update_chat_fade() -> void:
	if _chat_messages.is_empty():
		return
	var now := Time.get_ticks_msec()
	var hold_msec := int(CHAT_MESSAGE_HOLD_SEC * 1000.0)
	var fade_msec := int(CHAT_MESSAGE_FADE_SEC * 1000.0)
	# Messages are appended oldest-first, so ages decrease down the array:
	# the front is always the oldest, hence the first to fully fade. Pop from
	# the front while fully faded (this also rebuilds the visible text).
	var removed := false
	while not _chat_messages.is_empty():
		if now - int(_chat_messages[0]["arrival_msec"]) >= hold_msec + fade_msec:
			_chat_messages.remove_at(0)
			removed = true
		else:
			break
	if removed:
		_render_chat_log()
	if _chat_messages.is_empty():
		_chat_log.modulate.a = 1.0  # nothing left; reset for the next message
		return
	var newest_age := now - int(_chat_messages[-1]["arrival_msec"])
	_chat_log.modulate.a = _chat_alpha_for_age(newest_age, hold_msec, fade_msec)

## Opacity (1..0) for a message of the given age: fully opaque through the
## hold window, a linear ramp across the fade window, then fully transparent.
func _chat_alpha_for_age(age_msec: int, hold_msec: int, fade_msec: int) -> float:
	if age_msec <= hold_msec:
		return 1.0
	if age_msec >= hold_msec + fade_msec:
		return 0.0
	return 1.0 - float(age_msec - hold_msec) / float(fade_msec)

func _render_chat_log() -> void:
	_chat_log.text = "\n".join(_chat_texts())

## The chat feed's lines, oldest first. Backs both the visible label and the
## automation hook chat_lines().
func _chat_texts() -> PackedStringArray:
	var texts: PackedStringArray = []
	for msg in _chat_messages:
		texts.append(String(msg["text"]))
	return texts

## Public for the automation hook, like view_mode_name(): the chat log's
## current lines, newest last.
func chat_lines() -> PackedStringArray:
	return _chat_texts()

## Renders the trade panel: visible whenever _trade_panel_open(), showing
## live prices/stock/hold at a broker (with a selection cursor and the key
## legend) or a read-only manifest at the ship's cargo console.
func _update_trade_panel() -> void:
	var open := _trade_panel_open()
	_trade_panel.visible = open
	if not open:
		return
	var lines: PackedStringArray = []
	var interactive := _at_broker()
	var title := "MARKET" if interactive else "CARGO MANIFEST (read-only)"
	if _market != null and _world != null:
		title += " — %s" % _world.station_name(_market.station_id)
	lines.append(title)
	if _cargo != null:
		lines.append("wallet %d cr   hold %d/%d" % [_cargo.wallet, _cargo.hold_total(), _cargo.capacity])
	lines.append("")
	if _market == null:
		lines.append("(waiting for market data…)")
	else:
		_trade_selection = clampi(_trade_selection, 0, maxi(0, _market.stores.size() - 1))
		for i in _market.stores.size():
			var store := _market.stores[i]
			var cursor := "> " if interactive and i == _trade_selection else "  "
			var held := _cargo.hold_quantity(store.commodity) if _cargo != null else 0
			lines.append("%s%-12s %5d cr   stock %4d   hold %3d" % [
				cursor, store.name, store.price, store.quantity, held])
	lines.append("")
	if interactive:
		lines.append("W/S select   D buy 1   A sell 1   (Shift = x10)   E stand")
	else:
		lines.append("trading happens at station brokers — E stand")
	_trade_panel.text = "\n".join(lines)

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
	if _space != null and _space.is_station():
		lines.append("at %s" % _station_name(_space.station_id()))
		if _space.moorings.size() > 0:
			lines.append("%d ship(s) at the berths" % _space.moorings.size())
	if _cargo != null:
		lines.append("wallet %d cr - hold %d/%d" % [_cargo.wallet, _cargo.hold_total(), _cargo.capacity])
		for transfer in _cargo.transfers:
			var verb := "loading" if transfer["direction"] == "to_ship" else "unloading"
			lines.append("%s %d %s…" % [verb, transfer["remaining"], transfer["commodity"]])

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
	var t := _render_sim_time
	for station in _world.stations:
		var pos := _world.station_position(station.id, t)
		if own_pos.distance_to(pos) <= station.dock_radius:
			return station.name
	return ""
