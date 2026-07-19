extends Node
## Headless parse probe (decorated-interiors, T5): builds a ShipClassData
## from a small decorated deck and asserts geometry + decor + NE-corner
## colour parse against the server's deckplan.gleam semantics.
##
## Run:  godot --path client --headless res://tools/interior_parse_probe.tscn
##
## Extends Node (run via the paired .tscn) rather than SceneTree run via
## `--script`: a `--script` main-loop-override script's dependency graph
## compiles before autoload singletons are registered as global identifiers,
## so `ship_class_data.gd`'s `NetworkClient.glyphs` reference (needed for
## decor resolution, same as the real client) fails to compile in that mode.
## Running as a normal scene goes through the project's regular boot order
## (autoloads registered first), matching how the client actually runs.
##
## The probe carries no welcome message, so it builds a minimal GlyphRegistry
## inline (rather than reading server/glyphs.json, which res:// cannot reach
## from outside the project root) and assigns it to NetworkClient.glyphs
## before parsing, so decor resolution has a registry to consult.

func _ready() -> void:
	NetworkClient.glyphs = GlyphRegistry.from_dict({
		"centers": [
			{"glyph": " ", "id": "floor", "tile": "floor"},
			{"glyph": ".", "id": "void", "tile": "void"},
			{"glyph": "x", "id": "stairs", "tile": "stairs", "sprite": "stairs"},
			{"glyph": "d", "id": "bed", "tile": "floor", "sprite": "bed"},
		],
		"edges": [],
	})

	var cls := ShipClassData.from_dict({
		"id": "t", "name": "T",
		"decks": [{"name": "d", "grid": ["#=a", " d ", "###"]}],
	})

	var ok := true
	ok = ok and cls.is_walkable(0, 0, 0)
	ok = ok and cls.decor_at(0, 0, 0) == "d"
	ok = ok and cls.color_at(0, 0, 0) == 10

	print("[parse_probe] ", "PASS" if ok else "FAIL")
	get_tree().quit(0 if ok else 1)
