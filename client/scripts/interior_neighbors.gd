class_name InteriorNeighbors
## Deterministic, load-order-independent helpers for neighbour-aware interior
## rendering (issue #36). Variation MUST derive only from (deck_id, x, y) --
## never Time/RNG/iteration order -- so fountains, flowerbeds and trees never
## reshuffle on relog.

const N := 1
const E := 2
const S := 4
const W := 8

## FNV-1a over the three ints. Pure; returns a non-negative 31-bit int.
static func interior_hash(deck_id: int, x: int, y: int) -> int:
	var h := 2166136261
	for v in [deck_id, x, y]:
		# fold 32 bits of v, byte by byte
		for shift in [0, 8, 16, 24]:
			h = (h ^ ((v >> shift) & 0xff)) & 0xffffffff
			h = (h * 16777619) & 0xffffffff
	return h & 0x7fffffff

## Bitmask (N|E|S|W) of orthogonal neighbours whose decor glyph == `glyph`.
static func mask4(deck, x: int, y: int, glyph: String) -> int:
	var m := 0
	if deck.decor_at(x, y - 1) == glyph: m |= N
	if deck.decor_at(x + 1, y) == glyph: m |= E
	if deck.decor_at(x, y + 1) == glyph: m |= S
	if deck.decor_at(x - 1, y) == glyph: m |= W
	return m

## Deterministic "num/den" chance from a precomputed hash.
static func chance(hash: int, num: int, den: int) -> bool:
	return (hash % den) < num


## Autotile sprite-id suffix from a mask4 bitmask: "" for isolated, else
## "_" + set directions in n,e,s,w order (e.g. E|W -> "_ew", all -> "_nesw").
static func autotile_suffix(mask: int) -> String:
	if mask == 0:
		return ""
	var s := "_"
	if mask & N: s += "n"
	if mask & E: s += "e"
	if mask & S: s += "s"
	if mask & W: s += "w"
	return s


## Count of set bits in a 4-bit neighbour mask (0..15).
static func popcount(mask: int) -> int:
	var c := 0
	for b in [N, E, S, W]:
		if mask & b: c += 1
	return c


## Deterministic plant variant for flowerbed/hydroponic tiles. `neighbours` is
## the popcount of a mask4; `hash` is interior_hash for the tile. Returns
## "tree" | "plant" | "base". Trees only where the cell is interior to a large
## bed (>= tree_neighbors same-type orthogonal neighbours) AND allow_tree.
## Pure -- no RNG/Time/order.
static func plant_variant(neighbours: int, hash: int, tree_neighbors: int, allow_tree: bool) -> String:
	if allow_tree and neighbours >= tree_neighbors and chance(hash, 1, 3):
		return "tree"
	if chance(hash >> 3, 1, 2):
		return "plant"
	return "base"
