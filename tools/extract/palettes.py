"""Extract the Super Game Boy colorization palettes.

Sources (vanilla pokered):
  data/sgb/sgb_palettes.asm   SuperPalettes: 4 colors per PAL_* entry,
                              5-bit RGB (IF DEF(_RED) variants are used;
                              this is a Red port)
  data/pokemon/palettes.asm   MonsterPalettes: species -> PAL_* name,
                              in Pokédex order with species names in the
                              line comments

Sources (pokered-gbc / Red++ SuperPalettes, optional COLORS mode):
  data/super_palettes.asm     multi-line RGB + ; 0xNN: PAL_NAME comments;
                              includes per-species pals under GEN_2_GRAPHICS
  data/mon_palettes.asm       MonsterPalettes: GEN_2 per-species PAL_* ids

Output: data/generated/palettes.lua
  palettes[NAME] = { {r,g,b} x4 } with 8-bit components, color 0 first
  pokemon[SPECIES] = NAME (PAL_ prefix stripped)

Output: data/palettes_gbc.lua (committed; not wiped by ROM import)
  same shape, plus per-species palette entries (BULBASAUR, …)

The HP bar fill is GB color 2 of PAL_GREENBAR / PAL_YELLOWBAR /
PAL_REDBAR; the thresholds live in home/palettes.asm GetHealthBarColor
(>= 27 pixels green, >= 10 yellow, else red).
"""

import argparse
import os
import re
import sys

from . import util


def _scale5(v):
    """5-bit (0-31) -> 8-bit color component."""
    return round(int(v) * 255 / 31)


def _rgb8(nums12):
    return [[_scale5(nums12[i]), _scale5(nums12[i + 1]), _scale5(nums12[i + 2])]
            for i in range(0, 12, 3)]


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
        palettes[name] = _rgb8(nums)
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


def _parse_gbc_super_palettes(path):
    """pokered-gbc data/super_palettes.asm: ; 0xNN: PAL_NAME then 4x RGB lines."""
    palettes = {}
    order = []
    pending = None
    buf = []
    for lineno, line in _read_raw(path):
        s = line.strip()
        m = re.match(r";\s*0x[0-9a-fA-F]+:\s*PAL_(\w+)", s)
        if m:
            pending = m.group(1)
            buf = []
            continue
        m = re.match(r"RGB\s+([\d,\s]+)", s)
        if not m or not pending:
            continue
        nums = [n for n in re.split(r"[,\s]+", m.group(1).strip()) if n]
        buf.extend(nums)
        if len(buf) < 12:
            continue
        if len(buf) != 12:
            util.die(f"{path}:{lineno}: expected 12 components for PAL_{pending}, "
                     f"got {len(buf)}")
        palettes[pending] = _rgb8(buf)
        order.append(pending)
        pending = None
        buf = []
    if pending:
        util.die(f"{path}: incomplete palette PAL_{pending}")
    return palettes, order


def _parse_gbc_monster_palettes(path):
    """GEN_2_GRAPHICS MonsterPalettes paired with ELSE-branch species comments."""
    lines = _read_raw(path)
    # species order from the vanilla ELSE comments (dex order + MISSINGNO)
    species_order = []
    in_else = False
    for _, line in lines:
        s = line.strip()
        if s.startswith("ELSE"):
            in_else = True
            continue
        if s.startswith("ENDC"):
            break
        if not in_else:
            continue
        m = re.match(r"db\s+PAL_\w+\s*;\s*(\w+)", s)
        if m:
            species_order.append(m.group(1))

    gen2_pals = []
    in_gen2 = False
    for lineno, line in lines:
        s = line.strip()
        if s.startswith("MonsterPalettes:"):
            continue
        if s.startswith("IF GEN_2_GRAPHICS"):
            in_gen2 = True
            continue
        if s.startswith("ELSE") or s.startswith("TrainerPalettes:"):
            break
        if not in_gen2:
            continue
        m = re.match(r"db\s+PAL_(\w+)", s)
        if m:
            gen2_pals.append(m.group(1))

    if len(species_order) != len(gen2_pals):
        util.die(f"{path}: GEN_2 MonsterPalettes ({len(gen2_pals)}) != "
                 f"ELSE species comments ({len(species_order)})")
    mon_pals = {}
    for species, pal in zip(species_order, gen2_pals):
        if species != "MISSINGNO":
            mon_pals[species] = pal
    return mon_pals


def extract_gbc(pokered_gbc, out_path):
    """Build the Red++ / pokered-gbc SuperPalette pack used by COLORS=RED++."""
    super_path = os.path.join(pokered_gbc, "data/super_palettes.asm")
    mon_path = os.path.join(pokered_gbc, "data/mon_palettes.asm")
    if not os.path.isfile(super_path):
        util.die(f"missing {super_path}")
    if not os.path.isfile(mon_path):
        util.die(f"missing {mon_path}")

    palettes, order = _parse_gbc_super_palettes(super_path)
    # pret spelling vs Red++ British spelling
    if "GREYMON" in palettes and "GRAYMON" not in palettes:
        palettes["GRAYMON"] = palettes["GREYMON"]
        order.append("GRAYMON")
    # Overworld still asks for ROUTE / PALLET; Red++ dropped those SGB
    # entries (color/data handles overworld). Alias to closest town pals.
    if "ROUTE" not in palettes and "VIRIDIAN" in palettes:
        palettes["ROUTE"] = palettes["VIRIDIAN"]
        order.append("ROUTE")
    if "PALLET" not in palettes and "PEWTER" in palettes:
        palettes["PALLET"] = palettes["PEWTER"]
        order.append("PALLET")

    mon_pals = _parse_gbc_monster_palettes(mon_path)
    if len(mon_pals) != 151:
        util.die(f"mon_palettes.asm: parsed {len(mon_pals)} species (want 151)")
    for species, pal in mon_pals.items():
        if pal not in palettes:
            util.die(f"mon_palettes.asm: unknown palette PAL_{pal} for {species}")
    for name in ("MEWMON", "GREENBAR", "YELLOWBAR", "REDBAR", "GRAYMON"):
        if name not in palettes:
            util.die(f"super_palettes.asm: PAL_{name} missing")

    # write_lua stamps "Generated by tools/build_data.py"; keep that header
    # but point the source field at the gbc tree.
    util.write_lua(
        out_path,
        {"source": "pokered-gbc data/super_palettes.asm + data/mon_palettes.asm",
         "palettes": palettes,
         "order": order,
         "pokemon": mon_pals},
        header="Red++ / pokered-gbc SuperPalettes (COLORS=RED++): 4 8-bit RGB\n"
               "colors per palette (color 0 first), including per-species\n"
               "pals and the GEN_2 MonsterPalettes assignment.")
    return palettes, mon_pals


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_van = sub.add_parser("vanilla", help="extract pret/pokered SGB palettes")
    p_van.add_argument("--pokered", required=True)
    p_van.add_argument("--out-dir", default="data/generated")

    p_gbc = sub.add_parser("gbc", help="extract pokered-gbc SuperPalettes")
    p_gbc.add_argument("--pokered-gbc", required=True)
    p_gbc.add_argument("--out", default="data/palettes_gbc.lua")

    args = parser.parse_args(argv)
    if args.cmd == "vanilla":
        extract(args.pokered, args.out_dir)
    else:
        extract_gbc(args.pokered_gbc, args.out)
    return 0


if __name__ == "__main__":
    # python3 -m extract.palettes  (from tools/)  or  python3 tools/extract/palettes.py
    if __package__ is None:
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
        __package__ = "extract"
        from extract import util as util  # noqa: F811
    raise SystemExit(main())
