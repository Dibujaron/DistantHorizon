extends Node
## Debug-only automation hook (M1 Task 7). See DESIGN.md "Letting Claude see
## and drive the UI": a local newline-delimited-JSON control socket that
## lets an external harness (harness/automation.py) drive and inspect a
## real, running client -- inject input events, dump scene/game state as
## text, and grab screenshots.
##
## Only starts when OS.is_debug_build() AND "--automation" is present in
## OS.get_cmdline_user_args() -- inert in release exports (is_debug_build()
## is false there) and in ordinary debug runs without the flag, so this
## never ships live or opens a socket a player didn't ask for.
##
## This is a *separate* channel from the game's own WebSocket protocol
## (network_client.gd talks to the DH server on 8484); this one talks to
## the client process itself, on 127.0.0.1:8486.
##
## Wire format: one JSON object per line, request and response both.
##   {"cmd":"ping"}                                  -> {"ok":true,"pong":true}
##   {"cmd":"screenshot","path":"C:/abs/path.png"}   -> {"ok":true,"path":...}
##   {"cmd":"dump"}                                  -> {"ok":true,"state":{...}}
##   {"cmd":"action","action":"thrust","pressed":true} -> {"ok":true}
##   {"cmd":"key","keycode":"SPACE","pressed":true}    -> {"ok":true}
## Unknown cmd -> {"ok":false,"error":"unknown_cmd"}; parse failure ->
## {"ok":false,"error":"bad_json"}.

const HOST := "127.0.0.1"
const PORT := 8486

var _server: TCPServer
var _peer: StreamPeerTCP
## Raw bytes, split on newline *before* UTF-8 decoding: a multi-byte
## character split across two TCP reads would be corrupted if each chunk
## were decoded independently.
var _recv_buffer: PackedByteArray = PackedByteArray()
## True while a command handler is in flight. _cmd_screenshot awaits a
## rendered frame, so without this guard a second buffered command would be
## handled (and answered) before the pending screenshot's response.
var _handling: bool = false

## Latest snapshot's ships (ShipState), tracked independently of the game
## scene so this hook only depends on the NetworkClient autoload's public
## signals/fields, not on main.gd's private render-loop state.
var _latest_ships: Array[ShipState] = []
## Latest `walkers` message's crew (CharacterState), tracked the same way.
var _latest_characters: Array[CharacterState] = []
## Latest `cargo` message for our own ship (M3), tracked the same way.
var _latest_cargo: CargoState = null

func _ready() -> void:
	if not OS.is_debug_build():
		set_process(false)
		return
	if not "--automation" in OS.get_cmdline_user_args():
		set_process(false)
		return
	_server = TCPServer.new()
	var err := _server.listen(PORT, HOST)
	if err != OK:
		push_error("[automation] listen on %s:%d failed: %s" % [HOST, PORT, error_string(err)])
		set_process(false)
		return
	NetworkClient.snapshot_received.connect(_on_snapshot_received)
	NetworkClient.walkers_received.connect(_on_walkers_received)
	NetworkClient.cargo_received.connect(_on_cargo_received)
	print("[automation] listening on %s:%d" % [HOST, PORT])

func _on_snapshot_received(_tick: int, ships: Array[ShipState]) -> void:
	_latest_ships = ships

## Crew updates for our current space, mirroring main.gd's
## `_on_walkers_received` guard: frames tagged with another space or a
## previous epoch (in flight across a dock/undock rebuild) are dropped.
func _on_walkers_received(_tick: int, space_id: String, epoch: int, characters: Array[CharacterState]) -> void:
	if NetworkClient.space == null or space_id != NetworkClient.space.id or epoch != NetworkClient.space.epoch:
		return
	_latest_characters = characters

func _on_cargo_received(cargo: CargoState) -> void:
	if cargo.ship_id == NetworkClient.ship_id:
		_latest_cargo = cargo

func _process(_delta: float) -> void:
	if _server == null:
		return
	if _peer == null:
		if _server.is_connection_available():
			_peer = _server.take_connection()
			_recv_buffer = PackedByteArray()
			print("[automation] client connected")
		return
	_peer.poll()
	match _peer.get_status():
		StreamPeerTCP.STATUS_CONNECTED:
			if not _handling:
				_drain_peer()
		StreamPeerTCP.STATUS_NONE, StreamPeerTCP.STATUS_ERROR:
			print("[automation] control connection closed")
			_peer = null
			_recv_buffer = PackedByteArray()

func _drain_peer() -> void:
	var available := _peer.get_available_bytes()
	if available > 0:
		var chunk: Array = _peer.get_data(available)
		if chunk[0] == OK:
			_recv_buffer.append_array(chunk[1])
	while true:
		var newline_index := _recv_buffer.find(10)  # "\n"
		if newline_index < 0:
			break
		var line := _recv_buffer.slice(0, newline_index).get_string_from_utf8().strip_edges()
		_recv_buffer = _recv_buffer.slice(newline_index + 1)
		if line != "":
			_handling = true
			await _handle_line(line)
			_handling = false

func _handle_line(line: String) -> void:
	var json := JSON.new()
	if json.parse(line) != OK:
		_respond({"ok": false, "error": "bad_json"})
		return
	var parsed: Variant = json.get_data()
	if not parsed is Dictionary:
		_respond({"ok": false, "error": "bad_json"})
		return
	var request: Dictionary = parsed
	match str(request.get("cmd", "")):
		"ping":
			_respond({"ok": true, "pong": true})
		"screenshot":
			await _cmd_screenshot(request)
		"dump":
			_respond({"ok": true, "state": _dump_state()})
		"action":
			_cmd_action(request)
		"key":
			_cmd_key(request)
		_:
			_respond({"ok": false, "error": "unknown_cmd"})

func _respond(response: Dictionary) -> void:
	if _peer == null:
		return
	_peer.put_data((JSON.stringify(response) + "\n").to_utf8_buffer())

func _cmd_screenshot(request: Dictionary) -> void:
	var path := str(request.get("path", ""))
	if path.is_empty():
		_respond({"ok": false, "error": "missing_path"})
		return
	# Wait for a fully rendered frame before grabbing the viewport texture
	# (mirrors screenshot_helper.gd's approach).
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var err := image.save_png(path)
	if err != OK:
		_respond({"ok": false, "error": "save_failed:%s" % error_string(err)})
		return
	_respond({"ok": true, "path": path})

func _cmd_action(request: Dictionary) -> void:
	var action_name := str(request.get("action", ""))
	var pressed := bool(request.get("pressed", true))
	if action_name.is_empty() or not InputMap.has_action(action_name):
		_respond({"ok": false, "error": "unknown_action"})
		return
	if pressed:
		Input.action_press(action_name)
	else:
		Input.action_release(action_name)
	_respond({"ok": true})

func _cmd_key(request: Dictionary) -> void:
	var keycode_name := str(request.get("keycode", ""))
	var pressed := bool(request.get("pressed", true))
	var keycode := OS.find_keycode_from_string(keycode_name)
	if keycode == KEY_NONE:
		_respond({"ok": false, "error": "unknown_keycode"})
		return
	var event := InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.pressed = pressed
	Input.parse_input_event(event)
	_respond({"ok": true})

## State dump for text-form assertions ("is the dock prompt showing", "did
## the ship move") that are cheaper and more precise than screenshots.
func _dump_state() -> Dictionary:
	var state_name := "DISCONNECTED"
	match NetworkClient.state:
		NetworkClient.ConnectionState.CONNECTING:
			state_name = "CONNECTING"
		NetworkClient.ConnectionState.CONNECTED:
			state_name = "CONNECTED"
		NetworkClient.ConnectionState.DISCONNECTED:
			state_name = "DISCONNECTED"

	var state: Dictionary = {
		"connection_state": state_name,
		"logged_in": NetworkClient.logged_in,
		"last_tick": NetworkClient.last_tick,
		"snapshot_count": NetworkClient.snapshot_count,
		"ship_id": NetworkClient.ship_id,
		"ship_x": null,
		"ship_y": null,
		"ship_heading": null,
		"ship_speed": null,
		"ship_docked": null,
		"camera_zoom": _camera_zoom(),
		"status_label": _status_label_text(),
		"scene_tree": _dump_scene_tree(),
		"view_mode": _view_mode_name(),
		"character": null,
		"station_id": NetworkClient.station_id if NetworkClient.station_id != "" else null,
		"space": NetworkClient.space.id if NetworkClient.space != null else "",
		"space_epoch": NetworkClient.space.epoch if NetworkClient.space != null else 0,
		"wallet": _latest_cargo.wallet if _latest_cargo != null else null,
		"hold": _latest_cargo.hold if _latest_cargo != null else {},
		"transfers": _latest_cargo.transfers.size() if _latest_cargo != null else 0,
		"trade_panel_open": _trade_panel_open_from_scene(),
		"chat": _chat_lines_from_scene(),
	}
	var own_ship := _find_own_ship()
	if own_ship != null:
		state["ship_x"] = own_ship.x
		state["ship_y"] = own_ship.y
		state["ship_heading"] = own_ship.heading
		state["ship_speed"] = own_ship.velocity().length()
		# null while flying free, matching the wire protocol's `docked` field.
		state["ship_docked"] = own_ship.docked_at if own_ship.is_docked() else null
	var own_character := _find_own_character()
	if own_character != null:
		state["character"] = {
			"id": own_character.id,
			"x": own_character.x,
			"y": own_character.y,
			# null while standing, matching the wire protocol's `seat` field.
			"seat": own_character.seat if own_character.is_seated() else null,
		}
	return state

func _find_own_ship() -> ShipState:
	if NetworkClient.ship_id < 0:
		return null
	for ship in _latest_ships:
		if ship.id == NetworkClient.ship_id:
			return ship
	return null

func _find_own_character() -> CharacterState:
	if NetworkClient.character_id < 0:
		return null
	for character in _latest_characters:
		if character.id == NetworkClient.character_id:
			return character
	return null

## main.gd's view mode is otherwise private render-loop state; it exposes
## one small public method, view_mode_name(), so this hook can read the
## mode as a plain string without knowing the ViewMode enum's internal
## representation.
func _view_mode_name() -> String:
	var main_node := get_tree().current_scene
	if main_node == null or not main_node.has_method("view_mode_name"):
		return ""
	return str(main_node.call("view_mode_name"))

## main.gd's zoom is a private render-loop var (`_zoom`), not exposed via
## the NetworkClient autoload. GDScript has no real property privacy --
## underscore is convention only -- so reading it by name via `get()` off
## the current scene root avoids needing to modify main.gd just for this.
func _camera_zoom() -> float:
	var main_node := get_tree().current_scene
	if main_node == null:
		return 0.0
	var zoom: Variant = main_node.get("_zoom")
	if zoom == null:
		return 0.0
	return float(zoom)

## main.gd's trade panel visibility is otherwise private render-loop state
## (`_trade_panel_open()`); it exposes one small public method,
## trade_panel_open(), mirroring `_view_mode_name()` above.
func _trade_panel_open_from_scene() -> bool:
	var main_node := get_tree().current_scene
	if main_node == null or not main_node.has_method("trade_panel_open"):
		return false
	return bool(main_node.call("trade_panel_open"))

## main.gd's chat log is otherwise private render-loop state; it exposes
## one small public method, chat_lines(), mirroring view_mode_name().
func _chat_lines_from_scene() -> Array:
	var main_node := get_tree().current_scene
	if main_node == null or not main_node.has_method("chat_lines"):
		return []
	var lines: Array = []
	for line: String in main_node.call("chat_lines"):
		lines.append(line)
	return lines

func _status_label_text() -> String:
	var main_node := get_tree().current_scene
	if main_node == null:
		return ""
	var label: Variant = main_node.get_node_or_null("%StatusLabel")
	if label == null:
		return ""
	return str(label.text)

func _dump_scene_tree() -> String:
	var lines: Array[String] = []
	_append_tree_lines(get_tree().root, 0, lines)
	return "\n".join(lines)

func _append_tree_lines(node: Node, depth: int, lines: Array[String]) -> void:
	lines.append("%s%s (%s)" % ["  ".repeat(depth), node.name, node.get_class()])
	for child in node.get_children():
		_append_tree_lines(child, depth + 1, lines)
