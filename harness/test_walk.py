from walk import find_path, console_tile

PLAN = {  # L-shaped single-deck corridor: (0,0)->(0,1)->(1,1)->(2,1)
    "decks": [{"name": "t", "grid": [
        "     ....",
        "         ",
        "     ....",
        "         ",
        "         ",
        "         ",
        ".........",
        ".........",
        ".........",
    ]}],
    "consoles": [{"id": "s1:helm", "kind": "helm", "deck": 0, "x": 2, "y": 1}],
}

def test_find_path_reaches_goal():
    path = find_path(PLAN, (0, 0), (2, 1))
    assert path is not None
    assert path[-1] == (2, 1)
    # every hop is one orthogonal step onto a walkable tile
    prev = (0, 0)
    for tile in path:
        assert abs(tile[0] - prev[0]) + abs(tile[1] - prev[1]) == 1
        prev = tile

def test_console_tile_lookup():
    assert console_tile(PLAN, "s1:helm") == (2, 1)

def test_unreachable_is_none():
    assert find_path(PLAN, (0, 0), (8, 8)) is None
