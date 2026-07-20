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

## Set (Dictionary used as a set) of centre glyphs that are decorative floor
## tiles (rug/seat/bed/pallet …): Floor-kind, not a console/dock/spawn, and
## carrying a client sprite. Mirrors `glyphs.is_decor` (glyphs.gleam).
var _decor_glyphs: Dictionary = {}

## Centre glyph -> sprite id, for decor rendering keyed directly on the
## deck-grid centre character (issue #29/#30's renderer, T6/T7). Kept
## separate from `edge_sprite_by_glyph` because centre and edge glyphs share
## the same char set with independent meanings (position disambiguates, e.g.
## centre `d` = floor bed) — a single merged dict would let an edge entry
## clobber a centre entry with the same char (#36 T12: edge `d` = wall bunk).
var center_sprite_by_glyph: Dictionary = {}

## Edge glyph -> sprite id, for wall-fixture rendering keyed directly on the
## deck-grid edge character. See `center_sprite_by_glyph` for why this is a
## separate dict rather than shared.
var edge_sprite_by_glyph: Dictionary = {}


static func from_dict(data: Variant) -> GlyphRegistry:
	var reg := GlyphRegistry.new()
	if data is Dictionary:
		reg._ingest(data.get("centers", []), reg.center_sprite_by_glyph)
		reg._ingest(data.get("edges", []), reg.edge_sprite_by_glyph)
		for c: Variant in data.get("centers", []):
			if c is Dictionary:
				var console: Variant = c.get("console")
				var sprite: Variant = c.get("sprite")
				if console != null and sprite != null:
					reg.console_sprite[str(console)] = str(sprite)
				var tile: Variant = c.get("tile")
				var dock: Variant = c.get("dock")
				var spawn: Variant = c.get("spawn")
				if str(tile) == "floor" and console == null \
						and dock != true and spawn != true and sprite != null:
					reg._decor_glyphs[str(c.get("glyph", ""))] = true
		# Edge-defined console kinds (T8/T9, issue #36) also resolve via
		# sprite_for_console, future-proofing for a wall-only console glyph.
		for e: Variant in data.get("edges", []):
			if e is Dictionary:
				var econsole: Variant = e.get("console")
				var esprite: Variant = e.get("sprite")
				if econsole != null and esprite != null:
					reg.console_sprite[str(econsole)] = str(esprite)
	return reg


func _ingest(entries: Variant, target: Dictionary) -> void:
	if entries is Array:
		for e: Variant in entries:
			if e is Dictionary:
				var sprite: Variant = e.get("sprite")
				if sprite != null:
					sprite_by_id[str(e.get("id", ""))] = str(sprite)
					target[str(e.get("glyph", ""))] = str(sprite)


## The sprite id for a console of `kind`, or "" if the registry maps none (the
## renderer then falls back to a procedural draw).
func sprite_for_console(kind: String) -> String:
	return str(console_sprite.get(kind, ""))


## Whether centre glyph `glyph` is a decorative floor tile (rug/seat/bed/
## pallet …), preserved per-cell and rendered as art rather than bare floor.
## Mirrors `glyphs.is_decor` (glyphs.gleam).
func is_decor(glyph: String) -> bool:
	return _decor_glyphs.has(glyph)


## The sprite id for centre glyph `glyph` (e.g. "d" -> "bed"), or "" if the
## registry maps none.
func sprite_for_center_glyph(glyph: String) -> String:
	return str(center_sprite_by_glyph.get(glyph, ""))


## The sprite id for edge glyph `glyph` (e.g. "w" -> "window", "d" -> "bunk"),
## or "" if the registry maps none.
func sprite_for_edge_glyph(glyph: String) -> String:
	return str(edge_sprite_by_glyph.get(glyph, ""))
