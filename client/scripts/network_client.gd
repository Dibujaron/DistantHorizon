extends Node
## Autoload wrapping WebSocketPeer for the Distant Horizon wire protocol (v1).
##
## Connects to the server, polls the socket every frame, parses snapshot
## messages and re-emits them as typed signals. Reconnects automatically
## when the connection drops. All protocol knowledge for the client lives
## here so the rendering layer never touches raw JSON.

## `ships` is an Array[ShipState] parsed off the wire.
signal snapshot_received(tick: int, ships: Array[ShipState])
signal connection_state_changed(state: ConnectionState)
## Sent on successful login: `world` is the full world document (schema in
## m1-shared-context.md) - star/planets/stations with rail parameters -
## parsed into typed objects.
signal welcome_received(ship_id: int, world: WorldData)
## Reply to a `dock`/`undock` request. `reason` is null when `ok`, otherwise
## one of "out_of_range" | "too_fast" | "already_docked" | "not_docked" |
## "not_at_helm" | "berths_full" | "no_berths" | "transfer_in_progress".
signal dock_result_received(ok: bool, reason: Variant)
## Login rejected (or a storage error). Connection stays open; caller may
## retry login.
signal error_received(code: String, message: String)
## Reply to a `sit`/`stand` request. `reason` is null when `ok`, otherwise
## one of "unknown_console" | "occupied" | "too_far" | "already_seated" |
## "not_seated". `seat` is the console id (or null) after the attempt.
signal seat_result_received(ok: bool, reason: Variant, seat: Variant)
## Reply to a `buy`/`sell` request. `price` is the locked unit price on
## success, 0 on failure.
signal trade_result_received(ok: bool, reason: Variant, commodity: String, quantity: int, price: int)
## A station's market (reply to `get_market`, and pushed at 15 Hz while
## standing in that station's concourse).
signal market_received(market: MarketData)
## Our ship's wallet/hold/transfers, at 15 Hz to crew wherever they stand.
signal cargo_received(cargo: CargoState)
## The walkable space we're now in (M3.1): pushed on login and whenever a
## dock/undock/despawn rebuilds the plan under our feet. The renderer must
## adopt the plan and reset prediction/interpolation.
signal space_received(space: SpaceData)
## Everyone in our current space, 15 Hz - replaces M2 `interior` and M3
## `concourse`. Consumers drop frames whose space/epoch don't match the
## current SpaceData.
signal walkers_received(tick: int, space_id: String, epoch: int, characters: Array[CharacterState])

enum ConnectionState { CONNECTING, CONNECTED, DISCONNECTED }

const SERVER_URL := "ws://127.0.0.1:8484/ws"
const PROTOCOL_VERSION := 1
const RECONNECT_DELAY_SEC := 2.0
## A 500-ship snapshot is ~40 KB of JSON; the WebSocketPeer default inbound
## buffer (64 KiB) leaves little headroom, so raise it well clear of that.
const INBOUND_BUFFER_BYTES := 4 * 1024 * 1024
const DEFAULT_USERNAME := "pilot"
const DEFAULT_PASSWORD := "pilot"

var state: ConnectionState = ConnectionState.DISCONNECTED
var last_tick: int = -1
var snapshot_count: int = 0

## Our crew ship. Populated once `welcome` arrives; -1 until then. NOT
## session-stable: a crew transfer (undocking while standing on another
## crew's ship — the "shanghai") reassigns us server-side, and we adopt the
## new id from the "ship:N" space message it pushes (see `_handle_space`).
var ship_id: int = -1
var account_id: int = -1
var tick_rate: int = 60
var dt: float = 0.016666666666666666
var world: WorldData = null
var logged_in: bool = false
## Our character is our stable identity for the whole session (unlike
## ship_id, which a crew transfer can reassign); routing is by character id.
var character_id: int = -1
var ship_class: ShipClassData = null
## The tile-glyph registry (server/glyphs.json), parsed at welcome (issue #32).
## The interior renderer reads console sprite ids from it. Null until welcome.
var glyphs: GlyphRegistry = null
## The 16-colour tile palette (server/colors.json), parsed at welcome (issue
## #29). The interior renderer looks up a cell's NE-corner colour slot here.
## Null until welcome.
var palette: Palette = null
## The walkable space we're currently in (M3.1); null until the first
## `space` message arrives right after `welcome`.
var space: SpaceData = null
## Station whose concourse our character is standing in; derived from the
## current space; kept for the automation dump. "" while aboard a flying
## ship (i.e. whenever `space` isn't a station space).
var station_id: String = ""

var _socket: WebSocketPeer
var _reconnect_timer := 0.0
var _login_sent := false

## M3.5 UI shell: without cmdline credentials the main menu owns login —
## the socket connects immediately but no login is sent until
## request_login() delivers what the player typed. Automation and dev
## launches that pass --username= keep the instant auto-login path.
var manual_login := false
var _menu_username := ""
var _menu_password := ""

func _ready() -> void:
	var has_creds := false
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--username="):
			has_creds = true
	manual_login = not has_creds
	_start_connecting()

## Called by the main menu: store credentials and log in now (or as soon as
## the socket opens). Safe to call again after an error_received retry.
func request_login(username: String, password: String) -> void:
	_menu_username = username
	_menu_password = password
	manual_login = false
	_login_sent = false
	if _socket != null and _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_send_login()

func _process(delta: float) -> void:
	if _socket == null:
		# Disconnected: count down, then try again.
		_reconnect_timer -= delta
		if _reconnect_timer <= 0.0:
			_start_connecting()
		return

	_socket.poll()
	match _socket.get_ready_state():
		WebSocketPeer.STATE_CONNECTING:
			pass
		WebSocketPeer.STATE_OPEN:
			if state != ConnectionState.CONNECTED:
				_set_state(ConnectionState.CONNECTED)
				print("[net] connected to %s" % SERVER_URL)
				if not _login_sent and not manual_login:
					_send_login()
			while _socket.get_available_packet_count() > 0:
				_handle_packet(_socket.get_packet())
		WebSocketPeer.STATE_CLOSING:
			pass
		WebSocketPeer.STATE_CLOSED:
			var code := _socket.get_close_code()
			print("[net] disconnected (close code %d), retrying in %.1fs" % [code, RECONNECT_DELAY_SEC])
			_socket = null
			_reconnect_timer = RECONNECT_DELAY_SEC
			_set_state(ConnectionState.DISCONNECTED)

func send_message(message: Dictionary) -> void:
	## Send a client->server message; fills in the protocol version.
	if _socket == null or _socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		push_warning("send_message while not connected; dropped: %s" % message)
		return
	if not message.has("v"):
		message["v"] = PROTOCOL_VERSION
	_socket.send_text(JSON.stringify(message))

func _start_connecting() -> void:
	_login_sent = false
	logged_in = false
	_socket = WebSocketPeer.new()
	_socket.inbound_buffer_size = INBOUND_BUFFER_BYTES
	var err := _socket.connect_to_url(SERVER_URL)
	if err != OK:
		push_error("[net] connect_to_url failed: %s" % error_string(err))
		_socket = null
		_reconnect_timer = RECONNECT_DELAY_SEC
		_set_state(ConnectionState.DISCONNECTED)
		return
	_set_state(ConnectionState.CONNECTING)

func _handle_packet(packet: PackedByteArray) -> void:
	var message: Variant = JSON.parse_string(packet.get_string_from_utf8())
	if not message is Dictionary:
		push_warning("[net] unparseable frame (%d bytes), ignoring" % packet.size())
		return
	if message.get("v") != PROTOCOL_VERSION:
		push_warning("[net] unexpected protocol version %s, ignoring" % str(message.get("v")))
		return
	match message.get("type"):
		"snapshot":
			_handle_snapshot(message)
		"welcome":
			_handle_welcome(message)
		"error":
			_handle_error(message)
		"dock_result":
			_handle_dock_result(message)
		"seat_result":
			_handle_seat_result(message)
		"trade_result":
			_handle_trade_result(message)
		"market":
			_handle_market(message)
		"cargo":
			_handle_cargo(message)
		"space":
			_handle_space(message)
		"walkers":
			_handle_walkers(message)
		_:
			# Other message types (e.g. stats) are fine to ignore.
			pass

## Read `--username=` / `--password=` from `OS.get_cmdline_user_args()`
## (args after `--` when launching Godot), falling back to pilot/pilot.
func _login_credentials() -> Array:
	if _menu_username != "":
		return [_menu_username, _menu_password]
	var username := DEFAULT_USERNAME
	var password := DEFAULT_PASSWORD
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--username="):
			username = arg.substr(len("--username="))
		elif arg.begins_with("--password="):
			password = arg.substr(len("--password="))
	return [username, password]

func _send_login() -> void:
	_login_sent = true
	var creds := _login_credentials()
	send_message({"type": "login", "username": creds[0], "password": creds[1]})
	print("[net] login sent as %s" % creds[0])

func _handle_welcome(message: Dictionary) -> void:
	ship_id = int(message.get("ship_id", -1))
	account_id = int(message.get("account_id", -1))
	tick_rate = int(message.get("tick_rate", 60))
	dt = float(message.get("dt", dt))
	var w: Variant = message.get("world")
	if w is Dictionary:
		world = WorldData.from_dict(w)
	character_id = int(message.get("character_id", -1))
	station_id = ""
	space = null
	# glyphs/palette must be set before parsing ship_class: Deck.from_grid ->
	# _parse_decor reads NetworkClient.glyphs to resolve decor tiles, so
	# parsing ship_class first would leave the aboard ship's decor unresolved.
	glyphs = GlyphRegistry.from_dict(message.get("glyphs"))
	palette = Palette.from_dict(message.get("palette", []))
	var class_doc: Variant = message.get("ship_class")
	if class_doc is Dictionary:
		ship_class = ShipClassData.from_dict(class_doc)
	logged_in = true
	print("[net] welcome: ship_id=%d account_id=%d character_id=%d" % [ship_id, account_id, character_id])
	welcome_received.emit(ship_id, world)

func _handle_error(message: Dictionary) -> void:
	var code := str(message.get("code", ""))
	var error_message := str(message.get("message", ""))
	push_warning("[net] error from server: %s: %s" % [code, error_message])
	error_received.emit(code, error_message)

func _handle_dock_result(message: Dictionary) -> void:
	var ok := bool(message.get("ok", false))
	var reason: Variant = message.get("reason")
	dock_result_received.emit(ok, reason)

func _handle_seat_result(message: Dictionary) -> void:
	var ok := bool(message.get("ok", false))
	var reason: Variant = message.get("reason")
	var seat: Variant = message.get("seat")
	seat_result_received.emit(ok, reason, seat)

func _handle_trade_result(message: Dictionary) -> void:
	trade_result_received.emit(
		bool(message.get("ok", false)),
		message.get("reason"),
		str(message.get("commodity", "")),
		int(message.get("quantity", 0)),
		int(message.get("price", 0)))

func _handle_market(message: Dictionary) -> void:
	market_received.emit(MarketData.from_dict(message))

func _handle_cargo(message: Dictionary) -> void:
	cargo_received.emit(CargoState.from_dict(message))

func _handle_space(message: Dictionary) -> void:
	space = SpaceData.from_dict(message)
	station_id = space.station_id()
	# A "ship:N" space is authoritative crew membership (a body aboard a
	# flying ship is that ship's crew), so adopt N as our crew ship — this is
	# how a crew transfer reaches us. A station space says nothing about crew,
	# so leave ship_id alone there (mirrors how station_id is derived above).
	if space.is_ship():
		ship_id = space.ship_id()
	space_received.emit(space)

func _handle_walkers(message: Dictionary) -> void:
	var raw_characters: Variant = message.get("characters")
	if not raw_characters is Array:
		push_warning("[net] walkers without characters array, ignoring")
		return
	var characters: Array[CharacterState] = []
	for character_data: Variant in raw_characters:
		if character_data is Dictionary:
			characters.append(CharacterState.from_dict(character_data))
	walkers_received.emit(
		int(message.get("tick", -1)),
		str(message.get("space", "")),
		int(message.get("epoch", 0)),
		characters)

func _handle_snapshot(message: Dictionary) -> void:
	var raw_ships: Variant = message.get("ships")
	if not raw_ships is Array:
		push_warning("[net] snapshot without ships array, ignoring")
		return
	var ships: Array[ShipState] = []
	for ship_data: Variant in raw_ships:
		if ship_data is Dictionary:
			ships.append(ShipState.from_dict(ship_data))
	last_tick = int(message.get("tick", -1))
	snapshot_count += 1
	if snapshot_count == 1:
		print("[net] first snapshot: tick=%d ships=%d" % [last_tick, ships.size()])
	elif snapshot_count % 75 == 0:  # every ~5 s at 15 Hz
		print("[net] snapshots=%d tick=%d" % [snapshot_count, last_tick])
	snapshot_received.emit(last_tick, ships)

func _set_state(new_state: ConnectionState) -> void:
	if state == new_state:
		return
	state = new_state
	connection_state_changed.emit(state)
