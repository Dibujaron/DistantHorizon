extends Node2D
## Integration probe: drives the REAL interior_view.gd walk-render path with a
## synthetic all-walkable deck and moving characters — no server, no devserver
## contention. Verifies frame selection, scaling/anchoring, facing and the
## idle/walk switch actually render. Not shipped; a tools/ harness.
##
## Run:  godot --path client res://tools/interior_walk_probe.tscn   (watch live)
##       Pass the .tscn positionally — a .gd or a --scene flag is ignored and
##       Godot falls back to the project's MAIN scene (the actual game).
##       Add --headless with DH_SHOT to capture without opening a window.
## Env:  DH_SHOT=<path> captures one frame mid-walk, then quits.
## Env:  DH_SHOT_T=<seconds> overrides the default capture time (0.9), so a
##       shot can be taken mid any leg of the own character's box path
##       (leg = fmod(_t * 0.6, 4.0); 0=right, 1=up, 2=left, 3=down).

var _view: InteriorView
var _cls: ShipClassData
var _own: CharacterState
var _crew: CharacterState
var _t := 0.0


func _ready() -> void:
	_view = InteriorView.new()  # _grid_origin() centers the deck in the viewport
	add_child(_view)

	# v3 deck-plan grid: 3 chars per tile (center + N/E/S/W edge-mids), all
	# blank == every tile floor, every edge open -- a fully walkable deck.
	var rows: Array[String] = []
	for _ty in 8:
		for _sub in 3:
			rows.append(" ".repeat(36))  # 12 tiles wide * 3 chars/tile
	_cls = ShipClassData.from_dict({
		"id": "probe", "name": "Probe",
		"decks": [{"name": "upper", "grid": rows}],
	})
	_own = _make_char(1, "you", 2.0, 4.0)
	_crew = _make_char(2, "crew", 8.0, 3.0)


func _make_char(id: int, cname: String, x: float, y: float) -> CharacterState:
	var c := CharacterState.new()
	c.id = id
	c.name = cname
	c.x = x
	c.y = y
	c.deck = 0  # "upper" is decks[0]
	c.seat = ""
	return c


func _process(delta: float) -> void:
	_t += delta
	# Own character walks a box (right -> up -> left -> down) so all four
	# facings render; crew paces north/south to exercise front<->back.
	var leg := fmod(_t * 0.6, 4.0)
	if leg < 1.0:
		_own.x = 4.0 + 4.0 * leg;      _own.y = 4.0
	elif leg < 2.0:
		_own.x = 8.0;                  _own.y = 4.0 - 2.0 * (leg - 1.0)
	elif leg < 3.0:
		_own.x = 8.0 - 4.0 * (leg - 2.0); _own.y = 2.0
	else:
		_own.x = 4.0;                  _own.y = 2.0 + 2.0 * (leg - 3.0)
	_crew.x = 8.0
	_crew.y = 3.0 + 2.0 * sin(_t * 0.7)
	_view.set_frame_data(_cls, [_own, _crew] as Array[CharacterState], 1,
		_own.position(), 0, [] as Array[InteriorView.Backdrop])
	_maybe_shot()


var _shot_done := false
func _maybe_shot() -> void:
	var shot_t := 0.9
	var shot_t_env := OS.get_environment("DH_SHOT_T")
	if not shot_t_env.is_empty():
		shot_t = shot_t_env.to_float()
	if _shot_done or _t < shot_t:
		return
	_shot_done = true
	var path := OS.get_environment("DH_SHOT")
	if path.is_empty():
		return
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	print("[probe] shot saved: " + path)
	get_tree().quit()
