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
var _recv_buffer: String = ""

## Latest snapshot's raw ship list, tracked independently of the game
## scene so this hook only depends on the NetworkClient autoload's public
## signals/fields, not on main.gd's private render-loop state.
var _latest_ships: Array = []

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
	print("[automation] listening on %s:%d" % [HOST, PORT])

func _on_snapshot_received(_tick: int, ships: Array) -> void:
	_latest_ships = ships

func _process(_delta: float) -> void:
	if _server == null:
		return
	if _peer == null:
		if _server.is_connection_available():
			_peer = _server.take_connection()
			_recv_buffer = ""
			print("[automation] client connected")
		return
	_peer.poll()
	match _peer.get_status():
		StreamPeerTCP.STATUS_CONNECTED:
			_drain_peer()
		StreamPeerTCP.STATUS_NONE, StreamPeerTCP.STATUS_ERROR:
			print("[automation] control connection closed")
			_peer = null
			_recv_buffer = ""

func _drain_peer() -> void:
	var available := _peer.get_available_bytes()
	if available <= 0:
		return
	_recv_buffer += _peer.get_utf8_string(available)
	while true:
		var newline_index := _recv_buffer.find("\n")
		if newline_index < 0:
			break
		var line := _recv_buffer.substr(0, newline_index).strip_edges()
		_recv_buffer = _recv_buffer.substr(newline_index + 1)
		if line != "":
			_handle_line(line)

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
			_cmd_screenshot(request)
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
	}
	var own_ship: Variant = _find_own_ship()
	if own_ship != null:
		state["ship_x"] = float(own_ship.get("x", 0.0))
		state["ship_y"] = float(own_ship.get("y", 0.0))
		state["ship_heading"] = float(own_ship.get("heading", 0.0))
		state["ship_speed"] = Vector2(
			float(own_ship.get("vx", 0.0)), float(own_ship.get("vy", 0.0))
		).length()
		state["ship_docked"] = own_ship.get("docked")
	return state

func _find_own_ship() -> Variant:
	if NetworkClient.ship_id < 0:
		return null
	for ship: Dictionary in _latest_ships:
		if int(ship.get("id", -1)) == NetworkClient.ship_id:
			return ship
	return null

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
