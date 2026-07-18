"""Extract wild encounter tables.

Sources:
  data/wild/grass_water.asm -> WildDataPointers (one entry per map id)
  data/wild/maps/*.asm      -> def_grass_wildmons rate / db level, species x10

Output: data/generated/encounters.lua  (keyed by map constant)
"""

import os
import re

from . import util
from .util import parse_number, read_asm, split_args, warn


def parse_wild_file(path, rel):
    grass = {"rate": 0, "slots": []}
    water = {"rate": 0, "slots": []}
    current = None
    label = None
    out = {}
    for lineno, line in read_asm(path):
        s = line.strip()
        m = re.match(r"(\w+):{1,2}\s*$", s)
        if m:
            label = m.group(1)
            grass, water = {"rate": 0, "slots": []}, {"rate": 0, "slots": []}
            out[label] = {"grass": grass, "water": water, "source": rel}
            continue
        m = re.match(r"def_grass_wildmons\s+(\d+)", s)
        if m:
            grass["rate"] = int(m.group(1))
            current = grass
            continue
        m = re.match(r"def_water_wildmons\s+(\d+)", s)
        if m:
            water["rate"] = int(m.group(1))
            current = water
            continue
        if s.startswith(("end_grass_wildmons", "end_water_wildmons")):
            current = None
            continue
        m = re.match(r"db\s+(.*)$", s)
        if m and current is not None:
            a = split_args(m.group(1))
            if len(a) == 2:
                current["slots"].append({"level": parse_number(a[0]), "species": a[1]})
    return out


def extract(pokered, out_dir, map_order):
    tables = {}
    wild_dir = os.path.join(pokered, "data/wild/maps")
    for fname in sorted(os.listdir(wild_dir)):
        if fname.endswith(".asm"):
            tables.update(parse_wild_file(os.path.join(wild_dir, fname),
                                          f"data/wild/maps/{fname}"))

    pointers = []
    for lineno, line in read_asm(os.path.join(pokered, "data/wild/grass_water.asm")):
        m = re.match(r"dw\s+(\w+)$", line.strip())
        if m:
            pointers.append(m.group(1))

    out = {}
    for i, label in enumerate(pointers):
        if i >= len(map_order):
            break
        if label == "NothingWildMons":
            continue
        t = tables.get(label)
        if t is None:
            warn(f"grass_water.asm: no wild table {label}")
            continue
        entry = {"source": t["source"]}
        if t["grass"]["rate"] > 0 or t["grass"]["slots"]:
            entry["grass"] = t["grass"]
        if t["water"]["rate"] > 0 or t["water"]["slots"]:
            entry["water"] = t["water"]
        out[map_order[i]] = entry

    if "ROUTE_1" not in out or out["ROUTE_1"]["grass"]["rate"] != 25:
        util.die("encounter extraction sanity check failed (ROUTE_1)")
    util.write_lua(os.path.join(out_dir, "encounters.lua"), out,
                   header="Sources: data/wild/grass_water.asm, data/wild/maps/*.asm\n"
                          "10 grass slots; slot probabilities live in the engine (Gen 1 buckets).")
    return out
