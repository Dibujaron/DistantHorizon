extends Node
## Autoload wrapping WebSocketPeer for the Distant Horizon wire protocol (v1).
##
## Connects to the server, polls the socket every frame, parses snapshot
## messages and re-emits them as typed signals. Reconnects automatically
## when the connection drops. All protocol knowledge for the client lives
## here so the rendering layer never touches raw JSON.

signal snapshot_received(tick: int, ships: Array)
signal connection_state_changed(state: ConnectionState)

enum ConnectionState { CONNECTING, CONNECTED, DISCONNECTED }

const SERVER_URL := "ws://127.0.0.1:8484/ws"
const PROTOCOL_VERSION := 1
const RECONNECT_DELAY_SEC := 2.0
## A 500-ship snapshot is ~40 KB of JSON; the WebSocketPeer default inbound
## buffer (64 KiB) leaves little headroom, so raise it well clear of that.
const INBOUND_BUFFER_BYTES := 4 * 1024 * 1024

var state: ConnectionState = ConnectionState.DISCONNECTED
var last_tick: int = -1
var snapshot_count: int = 0

var _socket: WebSocketPeer
var _reconnect_timer := 0.0

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
		_:
			# Other message types (e.g. stats) are fine to ignore in M0.
			pass

func _handle_snapshot(message: Dictionary) -> void:
	var ships: Variant = message.get("ships")
	if not ships is Array:
		push_warning("[net] snapshot without ships array, ignoring")
		return
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
