"""Extract map data: headers, block layouts, objects, warps, signs.

Sources:
  data/maps/headers/<Map>.asm  -> map_header (tileset), connection directives
  data/maps/objects/<Map>.asm  -> border block, warp/bg/object events
  maps/<Map>.blk               -> width*height block indices
  data/maps/names.asm          -> display names (town map names, where mapped)
  constants/map_constants.asm  -> dimensions (parsed by constants.py)

Output: data/generated/maps.lua

Coordinates are in 16x16 "walk grid" cells, matching the macros' arguments.
"""

import os
import re

from . import util
from .util import parse_number, read_asm, split_args, warn


def parse_header(path):
    hdr = {"connections": {}}
    for lineno, line in read_asm(path):
        s = line.strip()
        m = re.match(r"map_header\s+(\w+),\s*(\w+),\s*(\w+)", s)
        if m:
            hdr["label"] = m.group(1)
            hdr["const"] = m.group(2)
            hdr["tileset"] = m.group(3)
            hdr["line"] = lineno
            continue
        m = re.match(r"connection\s+(\w+),\s*(\w+),\s*(\w+),\s*(-?[\w$%]+)", s)
        if m:
            hdr["connections"][m.group(1)] = {
                "map": m.group(3),
                "offset": parse_number(m.group(4)),
            }
    return hdr


def parse_objects(path):
    """Parse a data/maps/objects/*.asm file."""
    out = {"warps": [], "signs": [], "objects": [], "borderBlock": 0,
           "objectNames": []}
    obj_index = 0
    for lineno, line in read_asm(path):
        s = line.strip()
        m = re.match(r"const_export\s+(\w+)$", s)
        if m:
            out["objectNames"].append(m.group(1))
            continue
        m = re.match(r"db\s+(\$?[0-9a-fA-F]+)$", s)
        if m:
            out["borderBlock"] = parse_number(m.group(1))
            continue
        m = re.match(r"warp_event\s+(.*)$", s)
        if m:
            a = split_args(m.group(1))
            out["warps"].append({
                "x": parse_number(a[0]),
                "y": parse_number(a[1]),
                "destMap": a[2],
                "destWarp": parse_number(a[3]),
            })
            continue
        m = re.match(r"bg_event\s+(.*)$", s)
        if m:
            a = split_args(m.group(1))
            out["signs"].append({
                "x": parse_number(a[0]),
                "y": parse_number(a[1]),
                "text": a[2],
            })
            continue
        m = re.match(r"object_event\s+(.*)$", s)
        if m:
            a = split_args(m.group(1))
            obj_index += 1
            obj = {
                "index": obj_index,
                "x": parse_number(a[0]),
                "y": parse_number(a[1]),
                "sprite": a[2],
                "movement": a[3],           # STAY / WALK
                "range": a[4],              # facing (STAY) or roam range (WALK)
                "text": a[5],
            }
            # Extra args: trainers carry (OPP_class, party), static wild
            # Pokémon carry (species, level), items carry (item).
            if len(a) == 8:
                if a[6].startswith("OPP_"):
                    obj["trainerClass"] = a[6]
                    obj["trainerParty"] = parse_number(a[7]) if re.match(r"^[\d$%]", a[7]) else a[7]
                else:
                    obj["pokemon"] = a[6]
                    obj["level"] = parse_number(a[7])
            elif len(a) == 7:
                obj["item"] = a[6]
            out["objects"].append(obj)
            continue
    return out


def read_blk(path, width, height, border_block):
    with open(path, "rb") as f:
        raw = f.read()
    if len(raw) < width * height:
        # e.g. UndergroundPathNorthSouth.blk is 92 bytes for a 4x24 map; the
        # original ROM reads past the file into whatever data follows it.
        warn(f"{path}: expected {width * height} blocks, got {len(raw)}; padding with border block")
        raw = raw + bytes([border_block]) * (width * height - len(raw))
    elif len(raw) > width * height:
        util.die(f"{path}: expected {width * height} blocks, got {len(raw)}")
    return list(raw)


def parse_toggleable_objects(pokered):
    """data/maps/toggleable_objects.asm: initial ON/OFF state per object.

    Objects marked OFF exist in the object list but start hidden (e.g. Oak
    in his lab, cuttable trees' post-cut states...).
    """
    path = os.path.join(pokered, "data/maps/toggleable_objects.asm")
    states = {}
    current = None
    for lineno, line in read_asm(path):
        s = line.strip()
        m = re.match(r"toggleable_objects_for\s+(\w+)$", s)
        if m:
            current = m.group(1)
            states[current] = {}
            continue
        m = re.match(r"toggle_object_state\s+(\w+),\s*(ON|OFF)$", s)
        if m and current:
            states[current][m.group(1)] = m.group(2)
    return states


def parse_blocks_files(pokered):
    """maps.asm: `<Label>_Blocks:` labels (possibly several, shared) -> INCBIN file."""
    files = {}
    pending = []
    for lineno, line in read_asm(os.path.join(pokered, "maps.asm")):
        s = line.strip()
        m = re.match(r'(?:(\w+)_Blocks:{1,2}\s*)?(?:INCBIN\s+"([^"]+)")?$', s)
        if not s or not m:
            continue
        if m.group(1):
            pending.append(m.group(1))
        if m.group(2):
            for lbl in pending:
                files[lbl] = m.group(2)
            pending = []
    return files


def parse_display_names(pokered):
    """data/maps/names.asm: map display names in constant order via names list."""
    path = os.path.join(pokered, "data/maps/names.asm")
    names = []
    for lineno, line in read_asm(path):
        m = re.match(r'db\s+"([^"]*)@?"', line.strip())
        if m:
            names.append(m.group(1).replace("@", ""))
    return names


def extract(pokered, out_dir, map_dims):
    headers_dir = os.path.join(pokered, "data/maps/headers")
    blocks_files = parse_blocks_files(pokered)
    toggles = parse_toggleable_objects(pokered)
    out = {}
    for fname in sorted(os.listdir(headers_dir)):
        if not fname.endswith(".asm"):
            continue
        hdr = parse_header(os.path.join(headers_dir, fname))
        if "const" not in hdr:
            warn(f"data/maps/headers/{fname}: no map_header found")
            continue
        const = hdr["const"]
        if const not in map_dims:
            warn(f"{fname}: unknown map constant {const}")
            continue
        dims = map_dims[const]
        label = hdr["label"]

        # Two header files may declare the same map_header const (the unused
        # UndergroundPathRoute7Copy.asm shadows UndergroundPathRoute7.asm);
        # keep the file whose label spells the constant -- that is the one
        # the ROM's map_header_pointers.asm actually uses.
        if const in out:
            def spells_const(lbl):
                return lbl.upper() == const.replace("_", "")
            if spells_const(out[const]["label"]) == spells_const(label):
                util.die(f"duplicate map_header const {const}: "
                         f"{out[const]['label']} vs {label}")
            if spells_const(out[const]["label"]):
                continue

        obj_path = os.path.join(pokered, "data/maps/objects", f"{label}.asm")
        objects = parse_objects(obj_path)

        blk_rel = blocks_files.get(label, f"maps/{label}.blk")
        blocks = read_blk(os.path.join(pokered, blk_rel),
                          dims["width"], dims["height"], objects["borderBlock"])

        # attach export names + initial visibility to object events
        names = objects.pop("objectNames")
        map_toggles = toggles.get(const, {})
        for obj in objects["objects"]:
            name = names[obj["index"] - 1] if obj["index"] - 1 < len(names) else None
            if name:
                obj["name"] = name
                if map_toggles.get(name) == "OFF":
                    obj["hidden"] = True

        out[const] = {
            "id": const,
            "label": label,
            "index": dims["index"],
            "source": f"data/maps/headers/{label}.asm",
            "tileset": hdr["tileset"],
            "width": dims["width"],
            "height": dims["height"],
            "blocks": blocks,
            "borderBlock": objects["borderBlock"],
            "connections": hdr["connections"],
            "warps": objects["warps"],
            "signs": objects["signs"],
            "objects": objects["objects"],
        }

    util.write_lua(os.path.join(out_dir, "maps.lua"), out,
                   header="Sources: data/maps/headers/*.asm, data/maps/objects/*.asm, maps/*.blk\n"
                          "Coordinates are 16x16 walk-grid cells; width/height are in 32x32 blocks.")
    return out
