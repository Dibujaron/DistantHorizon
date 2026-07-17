extends Node2D
# Builds the whole toy scene in code (runtime-loaded textures, no editor
# import pass needed): 8 sprites at the sheet's headings, one
# DirectionalLight2D as the sun from upper-left, quantize shader on each
# sprite. Saves shot.png next to the project and quits.

const HEADINGS := [0, 35, 70, 105, 140, 180, 220, 300]
const SPRITE_SCALE := 0.16


func _ready() -> void:
	var albedo_img := Image.load_from_file("res://kx6_albedo.png")
	var normal_img := Image.load_from_file("res://kx6_normal.png")
	var tex := CanvasTexture.new()
	tex.diffuse_texture = ImageTexture.create_from_image(albedo_img)
	tex.normal_texture = ImageTexture.create_from_image(normal_img)

	var mat := ShaderMaterial.new()
	mat.shader = Shader.new()
	mat.shader.code = FileAccess.get_file_as_string("res://lit_ship.gdshader")

	for i in HEADINGS.size():
		var s := Sprite2D.new()
		s.texture = tex
		s.material = mat
		s.rotation_degrees = HEADINGS[i]
		s.scale = Vector2(SPRITE_SCALE, SPRITE_SCALE)
		s.position = Vector2(110 + i * 140, 215)
		add_child(s)

	var sun := DirectionalLight2D.new()
	sun.rotation_degrees = -45.0   # light travels to lower-right = sun upper-left
	sun.height = 0.55              # z of the light vector for normal-map math
	sun.blend_mode = Light2D.BLEND_MODE_ADD
	add_child(sun)

	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("res://shot.png")
	print("saved shot.png")
	get_tree().quit()
