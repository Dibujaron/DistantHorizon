class_name GlyphRegistry
extends RefCounted
## Typed view of the wire protocol's `glyphs` registry (server/glyphs.json),
## parsed once at welcome (network_client.gd). The server is the single source
## of truth for the tile vocabulary (issue #32); the client reads each glyph's
## long-form `id` and `sprite` key from here instead of hardcoding the mapping,
## so art is keyed on ids/kinds, not the single-char encoding.
##
## Today the renderer only looks up CONSOLE sprites by kind (interior_view.gd);
## walls/doors/floor are drawn procedurally, so their sprite keys are carried
## but unused. New tiles become a registry entry + a sprite here, no code edit.

## console kind (e.g. "helm", "broker", "dock") -> sprite id (e.g.
## "console_helm", "picto_airlock"). Only entries whose registry glyph has both
## a `console` kind and a non-null `sprite` are included.
var console_sprite: Dictionary = {}

## long-form id (e.g. "docking_port", "door") -> sprite id, for any future
## renderer that keys on ids rather than console kinds.
var sprite_by_id: Dictionary = {}


static func from_dict(data: Variant) -> GlyphRegistry:
	var reg := GlyphRegistry.new()
	if data is Dictionary:
		reg._ingest(data.get("centers", []))
		reg._ingest(data.get("edges", []))
		for c: Variant in data.get("centers", []):
			if c is Dictionary:
				var console: Variant = c.get("console")
				var sprite: Variant = c.get("sprite")
				if console != null and sprite != null:
					reg.console_sprite[str(console)] = str(sprite)
	return reg


func _ingest(entries: Variant) -> void:
	if entries is Array:
		for e: Variant in entries:
			if e is Dictionary:
				var sprite: Variant = e.get("sprite")
				if sprite != null:
					sprite_by_id[str(e.get("id", ""))] = str(sprite)


## The sprite id for a console of `kind`, or "" if the registry maps none (the
## renderer then falls back to a procedural draw).
func sprite_for_console(kind: String) -> String:
	return str(console_sprite.get(kind, ""))
