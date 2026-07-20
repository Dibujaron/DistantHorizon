extends Node
## Headless assert runner for pure interior logic (issue #36). Prints
## `SELFTEST: PASS` or `SELFTEST: FAIL: <msg>` and quits with code 0/1.
## Run: godot --path client --headless res://tools/interior_selftest.tscn --quit-after 240
##
## Extends Node (run via the paired .tscn) rather than SceneTree run via
## `--script`, mirroring interior_parse_probe.gd: the mask fixture's
## ShipClassData.Deck.from_grid resolves decor by consulting the global
## NetworkClient.glyphs autoload, which is only registered on the regular
## scene boot path.

var _fail := ""

const _GOLD_000 := 1648124597  # pinned from the first RED run (Step 3)


func _check(cond: bool, msg: String) -> void:
	if not cond and _fail == "": _fail = msg


func _ready() -> void:
	# Determinism: same inputs -> same hash across calls.
	var a := InteriorNeighbors.interior_hash(0, 3, 7)
	var b := InteriorNeighbors.interior_hash(0, 3, 7)
	_check(a == b, "hash not stable")
	_check(a >= 0, "hash negative")
	# Sensitivity: differing inputs mostly differ.
	_check(InteriorNeighbors.interior_hash(0, 3, 7) != InteriorNeighbors.interior_hash(1, 3, 7), "deck_id ignored")
	_check(InteriorNeighbors.interior_hash(0, 3, 7) != InteriorNeighbors.interior_hash(0, 4, 7), "x ignored")
	# Golden values pin the mix so a refactor can't silently change patterns.
	_check(InteriorNeighbors.interior_hash(0, 0, 0) == _GOLD_000, "golden 0,0,0 changed: got %d" % InteriorNeighbors.interior_hash(0, 0, 0))
	# mask4 on a hand-built 3x3 of fountains around centre (1,1).
	var deck := _mask_fixture()
	_check(InteriorNeighbors.mask4(deck, 1, 1, "f") == (InteriorNeighbors.N|InteriorNeighbors.E|InteriorNeighbors.S|InteriorNeighbors.W), "mask centre")
	_check(InteriorNeighbors.mask4(deck, 0, 0, "f") == (InteriorNeighbors.E|InteriorNeighbors.S), "mask corner")
	# autotile_suffix: pure mask -> sprite-id suffix mapping (fountain merge).
	_check(InteriorNeighbors.autotile_suffix(0) == "", "suffix isolated")
	_check(InteriorNeighbors.autotile_suffix(InteriorNeighbors.N|InteriorNeighbors.E|InteriorNeighbors.S|InteriorNeighbors.W) == "_nesw", "suffix all")
	_check(InteriorNeighbors.autotile_suffix(InteriorNeighbors.E|InteriorNeighbors.W) == "_ew", "suffix ew")
	# popcount
	_check(InteriorNeighbors.popcount(0) == 0, "popcount 0")
	_check(InteriorNeighbors.popcount(InteriorNeighbors.N|InteriorNeighbors.E|InteriorNeighbors.S|InteriorNeighbors.W) == 4, "popcount 4")
	_check(InteriorNeighbors.popcount(InteriorNeighbors.E|InteriorNeighbors.W) == 2, "popcount ew")
	# plant_variant determinism + rules: a corner cell (0 or 1 neighbours) can NEVER be a tree
	var h0 := InteriorNeighbors.interior_hash(0, 2, 2)
	_check(InteriorNeighbors.plant_variant(1, h0, 3, true) != "tree", "corner never tree")
	_check(InteriorNeighbors.plant_variant(4, h0, 3, true) == InteriorNeighbors.plant_variant(4, h0, 3, true), "variant stable")
	# allow_tree=false never trees (Task 7 reuse contract)
	_check(InteriorNeighbors.plant_variant(4, h0, 3, false) != "tree", "no-tree mode")
	# chance() is deterministic (closes the T2 gap)
	_check(InteriorNeighbors.chance(h0, 1, 3) == InteriorNeighbors.chance(h0, 1, 3), "chance stable")
	if _fail == "":
		print("SELFTEST: PASS")
		get_tree().quit(0)
	else:
		print("SELFTEST: FAIL: ", _fail)
		get_tree().quit(1)


func _mask_fixture() -> ShipClassData.Deck:
	# Minimal decor registry so 'f' resolves as a Floor-kind decor centre (no
	# console, has a client sprite) -- mirrors interior_render_probe.gd:23-61.
	NetworkClient.glyphs = GlyphRegistry.from_dict({
		"centers": [
			{"glyph": " ", "id": "floor", "tile": "floor"},
			{"glyph": "f", "id": "fountain", "tile": "floor", "sprite": "fountain"},
		],
		"edges": [],
	})
	# 3x3 all-fountain deck via ShipClassData.Deck.from_grid. Each tile is a
	# 3-char-wide block; from_grid reads the centre glyph from column 3x+1
	# (Deck.from_grid's `_cell(rows, 3*ty+1, 3*tx+1)`), so 'f' must sit at
	# col 1, 4, 7 -- not col 0, 3, 6.
	var rows := PackedStringArray()
	for _i in range(9):
		rows.append(" f  f  f ")
	return ShipClassData.Deck.from_grid("mask", rows)
