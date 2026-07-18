"""Extract the Super Game Boy colorization palettes.

Sources:
  data/sgb/sgb_palettes.asm   SuperPalettes: 4 colors per PAL_* entry,
                              5-bit RGB (IF DEF(_RED) variants are used;
                              this is a Red port)
  data/pokemon/palettes.asm   MonsterPalettes: species -> PAL_* name,
                              in Pokédex order with species names in the
                              line comments

Output: data/generated/palettes.lua
  palettes[NAME] = { {r,g,b} x4 } with 8-bit components, color 0 first
  pokemon[SPECIES] = NAME (PAL_ prefix stripped)

The HP bar fill is GB color 2 of PAL_GREENBAR / PAL_YELLOWBAR /
PAL_REDBAR; the thresholds live in home/palettes.asm GetHealthBarColor
(>= 27 pixels green, >= 10 yellow, else red).
"""

import os
import re

from . import util


def _scale5(v):
    """5-bit (0-31) -> 8-bit color component."""
    return round(int(v) * 255 / 31)


def _read_raw(path):
    """Raw lines WITH comments (palette / species names live in them)."""
    with open(path, encoding="utf-8") as f:
        return list(enumerate((l.rstrip("\n") for l in f), 1))


def extract(pokered, out_dir):
    # ---- SuperPalettes ---------------------------------------------------
    palettes = {}
    order = []
    in_blue = False
    for lineno, line in _read_raw(os.path.join(pokered, "data/sgb/sgb_palettes.asm")):
        s = line.strip()
        if s.startswith("IF DEF(_BLUE)"):
            in_blue = True
            continue
        if s.startswith("ENDC") or s.startswith("IF DEF(_RED)"):
            in_blue = False
            continue
        m = re.match(r"RGB\s+([\d,\s]+);\s*PAL_(\w+)", s)
        if not m or in_blue:
            continue
        nums = [n for n in re.split(r"[,\s]+", m.group(1).strip()) if n]
        if len(nums) != 12:
            util.die(f"sgb_palettes.asm:{lineno}: expected 12 components, got {len(nums)}")
        name = m.group(2)
        palettes[name] = [[_scale5(nums[i]), _scale5(nums[i + 1]), _scale5(nums[i + 2])]
                          for i in range(0, 12, 3)]
        order.append(name)

    # ---- MonsterPalettes -------------------------------------------------
    mon_pals = {}
    in_table = False
    for lineno, line in _read_raw(os.path.join(pokered, "data/pokemon/palettes.asm")):
        s = line.strip()
        if s.startswith("MonsterPalettes:"):
            in_table = True
            continue
        if not in_table:
            continue
        m = re.match(r"db\s+PAL_(\w+)\s*;\s*(\w+)", s)
        if not m:
            continue
        pal, species = m.group(1), m.group(2)
        if pal not in palettes:
            util.die(f"palettes.asm:{lineno}: unknown palette PAL_{pal}")
        if species != "MISSINGNO":
            mon_pals[species] = pal

    if len(mon_pals) != 151:
        util.die(f"MonsterPalettes parsed {len(mon_pals)} species (want 151)")
    for name in ("MEWMON", "GREENBAR", "YELLOWBAR", "REDBAR"):
        if name not in palettes:
            util.die(f"sgb_palettes.asm: PAL_{name} missing")

    util.write_lua(os.path.join(out_dir, "palettes.lua"),
                   {"source": "data/sgb/sgb_palettes.asm + data/pokemon/palettes.asm",
                    "palettes": palettes,
                    "order": order,
                    "pokemon": mon_pals},
                   header="SGB colorization: 4 8-bit RGB colors per palette (color 0\n"
                          "first) and the per-species palette assignment.")
    return palettes, mon_pals
