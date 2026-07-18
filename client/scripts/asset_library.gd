class_name AssetLibrary
extends RefCounted
## Runtime loader for client/assets (the tree is .gdignore'd — no import pass;
## same Image.load_from_file recipe the artspike toy scene proved). One
## instance is built by WorldView._ready; a SpriteSet bundles the lit
## CanvasTexture, the per-type ShaderMaterial (livery masks + base colors from
## meta.json), and the meta itself (anchors, px size).

const SHADER_PATH := "res://shaders/lit_sprite.gdshader"

const SHIP_KINDS := ["mockingbird", "mockingbird_stock", "longhorn"]
const STATION_ARCHETYPES := ["ring_3berth_crane", "ring_1berth"]
const STAR_LAYER_NAMES := ["small", "medium", "large"]


class SpriteSet:
	var texture: CanvasTexture
	var material: ShaderMaterial
	var meta: Dictionary

	func px_size() -> Vector2i:
		return Vector2i(int(meta.get("px_w", 0)), int(meta.get("px_h", 0)))

	## Texture-pixel positions of every anchor of `kind` from meta.json
	## (e.g. "nozzle" on ships, "berth" on stations).
	func anchors(kind: String) -> Array[Vector2]:
		var out: Array[Vector2] = []
		for a: Variant in meta.get("anchors", []):
			if a is Dictionary and str(a.get("kind", "")) == kind:
				out.append(Vector2(float(a["x_px"]), float(a["y_px"])))
		return out


var _ships: Dictionary = {}
var _stations: Dictionary = {}
var _bodies: Dictionary = {}
var _star_layers: Dictionary = {}
var _shader: Shader = null


static func load_all() -> AssetLibrary:
	var lib := AssetLibrary.new()
	lib._shader = Shader.new()
	lib._shader.code = FileAccess.get_file_as_string(SHADER_PATH)
	var root := ProjectSettings.globalize_path("res://assets")
	for kind: String in SHIP_KINDS:
		lib._ships[kind] = lib._load_set(root + "/ships/" + kind)
	for archetype: String in STATION_ARCHETYPES:
		lib._stations[archetype] = lib._load_set(root + "/stations/" + archetype)
	for f in DirAccess.get_files_at(root + "/bodies"):
		if f.ends_with(".png"):
			lib._bodies[f.trim_suffix(".png")] = _load_tex(root + "/bodies/" + f)
	for layer_name: String in STAR_LAYER_NAMES:
		lib._star_layers[layer_name] = _load_tex(
			root + "/background/stars_" + layer_name + ".png")
	return lib


static func _load_tex(path: String) -> ImageTexture:
	var img := Image.load_from_file(path)
	if img == null:
		push_error("AssetLibrary: missing " + path)
		return null
	return ImageTexture.create_from_image(img)


func _load_set(dir: String) -> SpriteSet:
	var albedo := AssetLibrary._load_tex(dir + "/albedo.png")
	if albedo == null:
		return null
	var s := SpriteSet.new()
	s.texture = CanvasTexture.new()
	s.texture.diffuse_texture = albedo
	s.texture.normal_texture = AssetLibrary._load_tex(dir + "/normal.png")
	var meta: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(dir + "/meta.json"))
	s.meta = meta if meta is Dictionary else {}
	s.material = ShaderMaterial.new()
	s.material.shader = _shader
	s.material.set_shader_parameter(
		"mask_tex", AssetLibrary._load_tex(dir + "/mask.png"))
	var c1: Array = s.meta.get("c1_base", [255, 255, 255])
	var c2: Array = s.meta.get("c2_base", [255, 255, 255])
	var base1 := Color(c1[0] / 255.0, c1[1] / 255.0, c1[2] / 255.0)
	var base2 := Color(c2[0] / 255.0, c2[1] / 255.0, c2[2] / 255.0)
	# tints default to bases = ship renders in its stock livery; player
	# livery arrives when customization lands (M4+): set c1_tint/c2_tint.
	s.material.set_shader_parameter("c1_base", base1)
	s.material.set_shader_parameter("c1_tint", base1)
	s.material.set_shader_parameter("c2_base", base2)
	s.material.set_shader_parameter("c2_tint", base2)
	return s


func ship(kind: String) -> SpriteSet:
	return _ships.get(kind)


func station(archetype: String) -> SpriteSet:
	return _stations.get(archetype)


func body(kind_id: String) -> Texture2D:
	return _bodies.get(kind_id)


func star_layer(layer_name: String) -> Texture2D:
	return _star_layers.get(layer_name)
