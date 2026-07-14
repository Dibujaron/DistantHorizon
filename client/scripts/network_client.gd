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
## one of "out_of_range" | "too_fast" | "already_docked" | "not_docked".
signal dock_result_received(ok: bool, reason: Variant)
## Login rejected (or a storage error). Connection stays open; caller may
## retry login.
signal error_received(code: String, message: String)

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

## Populated once `welcome` arrives; -1 / empty until then.
var ship_id: int = -1
var account_id: int = -1
var tick_rate: int = 60
var dt: float = 0.016666666666666666
var world: WorldData = null
var logged_in: bool = false

var _socket: WebSocketPeer
var _reconnect_timer := 0.0
var _login_sent := false

func _ready() -> void:
	_start_connecting()

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
				if not _login_sent:
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
		_:
			# Other message types (e.g. stats) are fine to ignore.
			pass

## Read `--username=` / `--password=` from `OS.get_cmdline_user_args()`
## (args after `--` when launching Godot), falling back to pilot/pilot.
func _login_credentials() -> Array:
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
	logged_in = true
	print("[net] welcome: ship_id=%d account_id=%d" % [ship_id, account_id])
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
