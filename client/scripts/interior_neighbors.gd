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
