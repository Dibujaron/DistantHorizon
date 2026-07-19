extends Node2D
## Integration probe: drives the REAL interior_view.gd walk-render path with a
## synthetic all-walkable deck and moving characters — no server, no devserver
## contention. Verifies frame selection, scaling/anchoring, facing and the
## idle/walk switch actually render. Not shipped; a tools/ harness.
##
## Run:  godot --path client res://tools/interior_walk_probe.gd
## Env:  DH_SHOT=<path> captures one frame mid-walk, then quits.

var _view: InteriorView
var _cls: ShipClassData
var _own: CharacterState
var _crew: CharacterState
var _t := 0.0


func _ready() -> void:
	_view = InteriorView.new()  # _grid_origin() centers the deck in the viewport
	add_child(_view)

	var rows: Array[String] = []
	for y in 8:
		rows.append("############")
	_cls = ShipClassData.from_dict({
		"id": "probe", "name": "Probe",
		"grid": {"width": 12, "height": 8}, "walkable": rows,
	})
	_own = _make_char(1, "you", 2.0, 4.0)
	_crew = _make_char(2, "crew", 8.0, 3.0)


func _make_char(id: int, cname: String, x: float, y: float) -> CharacterState:
	var c := CharacterState.new()
	c.id = id
	c.name = cname
	c.x = x
	c.y = y
	c.deck = "upper"
	c.seat = ""
	return c


func _process(delta: float) -> void:
	_t += delta
	# Own character strides back and forth (always walking); crew paces slower
	# and pauses (exercises the idle<->walk coast switch).
	_own.x = 6.0 + 3.5 * sin(_t * 1.6)
	_crew.x = 8.0 + 2.0 * sin(_t * 0.5)
	_view.set_frame_data(_cls, [_own, _crew] as Array[CharacterState], 1,
		_own.position(), "upper", [] as Array[InteriorView.Backdrop])
	_maybe_shot()


var _shot_done := false
func _maybe_shot() -> void:
	if _shot_done or _t < 0.9:
		return
	_shot_done = true
	var path := OS.get_environment("DH_SHOT")
	if path.is_empty():
		return
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	print("[probe] shot saved: " + path)
	get_tree().quit()
