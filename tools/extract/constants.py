"""Extract constants from pret/pokered.

Sources:
  constants/map_constants.asm      -> map ids + block dimensions
  constants/tileset_constants.asm  -> tileset ids
  constants/sprite_constants.asm   -> overworld sprite ids
  constants/pokemon_constants.asm  -> internal species order
  constants/pokedex_constants.asm  -> dex order
  constants/move_constants.asm     -> move ids
  constants/item_constants.asm     -> item ids
  constants/type_constants.asm     -> type ids
  constants/hide_show_constants.asm-> toggleable object ids (unused for now)
"""

import os
import re

from . import util
from .util import parse_number, read_asm


def extract_map_constants(pokered):
    """Parse map_const NAME, width, height entries in id order."""
    path = os.path.join(pokered, "constants/map_constants.asm")
    order, dims = [], {}
    value = None
    for lineno, line in read_asm(path):
        s = line.strip()
        if re.match(r"const_def", s):
            value = 0
            continue
        m = re.match(r"map_const\s+(\w+),\s*([\d$%-]+),\s*([\d$%-]+)", s)
        if m and value is not None:
            name = m.group(1)
            order.append(name)
            dims[name] = {
                "index": value,
                "width": parse_number(m.group(2)),
                "height": parse_number(m.group(3)),
            }
            value += 1
    if not order or order[0] != "PALLET_TOWN":
        util.die("map_constants.asm did not parse as expected")
    return order, dims


def extract_simple(pokered, relpath, stop_at=None):
    return util.parse_const_block(os.path.join(pokered, relpath), stop_at=stop_at)


def extract_types(pokered):
    """Type constants are physical IDs, a gap, then special IDs at $14."""
    path = os.path.join(pokered, "constants/type_constants.asm")
    types = {}
    value = None
    for lineno, line in read_asm(path):
        s = line.strip()
        m = re.match(r"const_def(?:\s+(\$?\w+))?$", s)
        if m:
            value = parse_number(m.group(1)) if m.group(1) else 0
            continue
        m = re.match(r"const_next\s+(\$?\w+)$", s)
        if m:
            value = parse_number(m.group(1))
            continue
        m = re.match(r"const\s+(\w+)", s)
        if m and value is not None:
            types[m.group(1)] = value
            value += 1
    if types.get("NORMAL") != 0 or "PSYCHIC_TYPE" not in types:
        util.die("type_constants.asm did not parse as expected")
    return types


def extract(pokered, out_dir):
    map_order, map_dims = extract_map_constants(pokered)
    tilesets = [n for n in extract_simple(pokered, "constants/tileset_constants.asm") if n]
    sprites = extract_simple(pokered, "constants/sprite_constants.asm")
    species = extract_simple(pokered, "constants/pokemon_constants.asm")
    moves = extract_simple(pokered, "constants/move_constants.asm", stop_at="NUM_ATTACKS")
    types = extract_types(pokered)

    # index 0 is the null entry (NO_MON / NO_MOVE / SPRITE_NONE); dropping it
    # makes the Lua arrays line up so array index == game id.
    data = {
        "source": "constants/*.asm",
        "mapOrder": map_order,
        "maps": map_dims,
        "tilesetOrder": tilesets,
        "spriteOrder": [n or "UNUSED" for n in sprites[1:]],
        "speciesOrder": [n or "UNUSED" for n in species[1:]],
        "moveOrder": [n or "UNUSED" for n in moves[1:]],
        "types": types,
    }
    util.write_lua(os.path.join(out_dir, "constants.lua"), data,
                   header="Source: pret/pokered constants/*.asm")
    return data
