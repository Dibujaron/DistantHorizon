"""Pure file validation: every shipped world/ship-class document must
validate against its JSON Schema (server/schemas/*.schema.json). No server
needed — this module intentionally does not use the `server` fixture from
conftest.py.
"""

import json
from pathlib import Path

import pytest
from jsonschema import Draft202012Validator

REPO_ROOT = Path(__file__).resolve().parent.parent
SCHEMAS_DIR = REPO_ROOT / "server" / "schemas"
WORLDS_DIR = REPO_ROOT / "server" / "worlds"
CLASSES_DIR = REPO_ROOT / "server" / "classes"

WORLD_SCHEMA = json.loads((SCHEMAS_DIR / "world.schema.json").read_text())
SHIP_CLASS_SCHEMA = json.loads((SCHEMAS_DIR / "ship_class.schema.json").read_text())

WORLD_DOCS = sorted(WORLDS_DIR.glob("*.json"))
CLASS_DOCS = sorted(CLASSES_DIR.glob("*.json"))


def test_world_schema_is_valid():
    Draft202012Validator.check_schema(WORLD_SCHEMA)


def test_ship_class_schema_is_valid():
    Draft202012Validator.check_schema(SHIP_CLASS_SCHEMA)


@pytest.mark.parametrize("path", WORLD_DOCS, ids=lambda p: p.name)
def test_every_world_document_validates(path):
    doc = json.loads(path.read_text())
    Draft202012Validator(WORLD_SCHEMA).validate(doc)


@pytest.mark.parametrize("path", CLASS_DOCS, ids=lambda p: p.name)
def test_every_ship_class_document_validates(path):
    doc = json.loads(path.read_text())
    Draft202012Validator(SHIP_CLASS_SCHEMA).validate(doc)


def test_at_least_one_world_document_was_found():
    # Guards against the glob silently matching nothing and the two
    # parametrized tests above passing vacuously.
    assert WORLD_DOCS, f"no *.json files found in {WORLDS_DIR}"


def test_at_least_one_ship_class_document_was_found():
    assert CLASS_DOCS, f"no *.json files found in {CLASSES_DIR}"


def test_world_rejects_a_one_element_berth():
    invalid_world = {
        "schema": 1,
        "name": "invalid",
        "seed": 1,
        "bodies": [],
        "stations": [
            {
                "id": "s1",
                "name": "S1",
                "parent": "b1",
                "orbit": {"radius": 1.0, "period_s": 1.0, "phase": 0.0},
                "dock_radius": 1.0,
                # A berth must be a [x, y] pair; this one is missing y.
                "berths": [[1]],
            }
        ],
        "spawn_station": "s1",
    }
    with pytest.raises(Exception):
        Draft202012Validator(WORLD_SCHEMA).validate(invalid_world)


def test_ship_class_rejects_an_unknown_handling_value():
    invalid_class = {
        "schema": 1,
        "id": "x",
        "name": "X",
        "grid": {"width": 1, "height": 1},
        "walkable": ["#"],
        "rooms": [],
        "consoles": [],
        "spawn_tile": [0, 0],
        "cargo": {"capacity": 1, "handling": "magnets"},
    }
    with pytest.raises(Exception):
        Draft202012Validator(SHIP_CLASS_SCHEMA).validate(invalid_class)
