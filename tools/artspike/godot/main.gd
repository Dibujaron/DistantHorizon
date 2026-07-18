extends Node2D
# Verifies the exported pipeline ships: CanvasTexture (albedo + normal) +
# mask-driven livery tints + quantized DirectionalLight2D shading. Rows are
# ships, columns are 8 headings plus a green-c1 tint proof. Run once for one
# sun (shot_1sun.png); run with DH_TWO_SUNS=1 for the double-key
# (shot_2sun.png). Saves the shot and quits.

const SHIPS := ["mockingbird", "mockingbird_stock", "longhorn"]
const HEADINGS := [0, 35, 70, 105, 140, 180, 220, 300]
const SCALE := 3.0


func _ship_dir(ship_name: String) -> String:
	var root := ProjectSettings.globalize_path("res://")
	return (root + "../../../client/assets/ships/" + ship_name).simplify_path()


func _load_ship(ship_name: String) -> Dictionary:
	var dir := _ship_dir(ship_name)
	var tex := CanvasTexture.new()
	tex.diffuse_texture = ImageTexture.create_from_image(
		Image.load_from_file(dir + "/albedo.png"))
	tex.normal_texture = ImageTexture.create_from_image(
		Image.load_from_file(dir + "/normal.png"))
	var mask := ImageTexture.create_from_image(
		Image.load_from_file(dir + "/mask.png"))
	var meta: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string(dir + "/meta.json"))
	return {"tex": tex, "mask": mask, "meta": meta}


func _material(shader: Shader, ship: Dictionary, c1_tint = null) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("mask_tex", ship["mask"])
	var c1b: Array = ship["meta"]["c1_base"]
	var c2b: Array = ship["meta"]["c2_base"]
	var base1 := Color(c1b[0] / 255.0, c1b[1] / 255.0, c1b[2] / 255.0)
	var base2 := Color(c2b[0] / 255.0, c2b[1] / 255.0, c2b[2] / 255.0)
	mat.set_shader_parameter("c1_base", base1)
	mat.set_shader_parameter("c2_base", base2)
	mat.set_shader_parameter("c1_tint", base1 if c1_tint == null else c1_tint)
	mat.set_shader_parameter("c2_tint", base2)
	return mat


func _ready() -> void:
	var shader := Shader.new()
	shader.code = FileAccess.get_file_as_string("res://lit_ship.gdshader")

	for row in SHIPS.size():
		var ship := _load_ship(SHIPS[row])
		var mat := _material(shader, ship)
		var tinted := _material(shader, ship, Color(0.3, 0.75, 0.35))
		for i in HEADINGS.size() + 1:
			var s := Sprite2D.new()
			s.texture = ship["tex"]
			s.material = mat if i < HEADINGS.size() else tinted
			s.rotation_degrees = HEADINGS[i] if i < HEADINGS.size() else 35.0
			s.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			s.scale = Vector2(SCALE, SCALE)
			s.position = Vector2(70 + i * 118, 115 + row * 210)
			add_child(s)

	var two := OS.get_environment("DH_TWO_SUNS") == "1"
	var sun := DirectionalLight2D.new()
	sun.rotation_degrees = -45.0   # light travels to lower-right = sun upper-left
	sun.height = 0.55              # z of the light vector for normal-map math
	sun.blend_mode = Light2D.BLEND_MODE_ADD
	add_child(sun)
	if two:
		var sun2 := DirectionalLight2D.new()
		sun2.rotation_degrees = 150.0
		sun2.height = 0.45
		sun2.color = Color(0.75, 0.8, 1.0)   # cool secondary key
		sun2.energy = 0.7
		sun2.blend_mode = Light2D.BLEND_MODE_ADD
		add_child(sun2)

	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var shot := "res://shot_2sun.png" if two else "res://shot_1sun.png"
	img.save_png(shot)
	print("saved ", shot)
	get_tree().quit()
