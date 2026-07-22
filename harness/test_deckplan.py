from deckplan import tile_walkable, circle_walkable

# One deck: 3x3 tiles, middle row walkable, everything else void.
#   tile (0,1),(1,1),(2,1) are floor; the rest void.
PLAN = {"decks": [{"name": "t", "grid": [
    ".........",
    ".........",
    ".........",
    "   #  #  ",   # y=1 row: three floor tiles, walls between (cosmetic here)
    "         ",
    "         ",
    ".........",
    ".........",
    ".........",
]}]}

def test_tile_walkable_center_glyph():
    assert tile_walkable(PLAN, 0, 1) is True
    assert tile_walkable(PLAN, 1, 1) is True
    assert tile_walkable(PLAN, 0, 0) is False   # void
    assert tile_walkable(PLAN, 9, 9) is False   # out of bounds

def test_circle_walkable_center_is_clear():
    assert circle_walkable(PLAN, 1.5, 1.5) is True   # dead center of a floor tile
    assert circle_walkable(PLAN, 1.5, 0.9) is False  # circle pokes into void row 0
