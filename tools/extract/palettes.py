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
  same shape, plus per-species palette entries (BULBASAUR, …), plus a
  `world` table (below) for true overworld tile/roof/sprite coloring.

The HP bar fill is GB color 2 of PAL_GREENBAR / PAL_YELLOWBAR /
PAL_REDBAR; the thresholds live in home/palettes.asm GetHealthBarColor
(>= 27 pixels green, >= 10 yellow, else red).

Sources (pokered-gbc color/**, the real GBC overworld coloring engine):
  color/data/map_palette_assignments.asm  per tileset: 96 tile-graphic-id
                                          -> palette-group (0-7) bytes
  color/data/map_palette_sets.asm         per tileset: 8 group -> palette-
                                          constant bytes (positional)
  color/data/map_palettes.asm             palette-constant -> 4 RGB colors
  color/data/roofpalettes.asm             per pokered map ID (positional,
                                          matches map.def.index): roof
                                          2-color override + the labeled
                                          RGB blocks it points at
  color/data/spritepalettes.asm           8 four-color OBJ palettes
  color/sprites.asm                       SpritePaletteAssignments: 1-based
                                          picture ID -> OBJ palette 0-3, or
                                          the "db 4" random-per-instance
                                          sentinel (ColorOverworldSprite)

Output `world` table shape:
  world.tileGroups[TILESET][tileId 0-95] = group index 0-7
  world.groupColors[TILESET][group 0-7] = { {r,g,b} x4 }
  world.roofGroup[TILESET] = the town-overridable group index (OVERWORLD/
                             PLATEAU only)
  world.roofByMapIndex[mapIndex] = { {r,g,b} x2 } (matches map.def.index)
  world.spritePalettes[0-7] = { {r,g,b} x4 }
  world.spriteAssignment[pictureIndex 0-based] = group 0-3 or "random"
    (pictureIndex matches the N in a sprite def's
    `source = "ROM:SpriteSheetPointerTable[N]"`)

The 3 hardcoded Celadon Mart tile-group exceptions and the Route 6/Saffron
roof y-split (LoadTilesetPalette / LoadTownPalette control flow, not data)
are NOT extracted here -- they live as a small named table in
src/render/PaletteFX.lua next to the code that consumes `world`.
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


# ---- color/** overworld attribute data ------------------------------------
#
# Two tiny fixed enums, hand-transcribed rather than parsed: both are
# `EQU`/`const` lists that never change (they are the hardware-shaped slot
# numbering, not game content), and each uses a different const-declaration
# style that isn't worth a bespoke parser for 4-8 entries.
#   color/data/map_palette_constants.asm:69-78 (`const_value = 0` block)
_GROUP_NAMES = ["GRAY", "RED", "GREEN", "BLUE", "YELLOW", "BROWN", "ROOF", "TEXT"]
_GROUP_INDEX = {name: i for i, name in enumerate(_GROUP_NAMES)}
#   color/sprites.asm:15-18 (`SPR_PAL_* EQU n`)
_SPR_PAL = {"SPR_PAL_ORANGE": 0, "SPR_PAL_BLUE": 1, "SPR_PAL_GREEN": 2, "SPR_PAL_BROWN": 3}


def _rgbN(nums):
    return [[_scale5(nums[i]), _scale5(nums[i + 1]), _scale5(nums[i + 2])]
            for i in range(0, len(nums), 3)]


def _parse_rgb_table(path, header_re, n_nums):
    """name -> n_nums/3 RGB colors, from blocks of `header_re` + RGB lines
    (one or more `RGB r,g,b[,r,g,b...]` lines per block, however they're
    wrapped -- matches both the 1-color-per-line and 4-colors-per-line
    styles pokered-gbc uses in different files)."""
    out = {}
    order = []
    pending = None
    buf = []
    for lineno, line in _read_raw(path):
        s = line.strip()
        m = header_re.match(s)
        if m:
            if pending:
                util.die(f"{path}:{lineno}: incomplete RGB block for "
                         f"{pending} ({len(buf)}/{n_nums})")
            pending = m.group(1)
            buf = []
            continue
        m = re.match(r"RGB\s+([\d,\s]+)", s)
        if not m or not pending:
            continue
        nums = [n for n in re.split(r"[,\s]+", m.group(1).strip()) if n]
        buf.extend(nums)
        if len(buf) < n_nums:
            continue
        if len(buf) != n_nums:
            util.die(f"{path}:{lineno}: expected {n_nums} components for "
                     f"{pending}, got {len(buf)}")
        out[pending] = _rgbN(buf)
        order.append(pending)
        pending = None
        buf = []
    if pending:
        util.die(f"{path}: incomplete RGB block for {pending}")
    return out, order


_TILESET_HEADER_RE = re.compile(r"^;\s*([A-Z][A-Z0-9_]*)\s*$")


def _parse_map_palette_assignments(path):
    """color/data/map_palette_assignments.asm: per tileset, 96 tile-graphic
    palette-group bytes (0-7, symbolic), 16 per line / 6 lines."""
    tile_groups = {}
    order = []
    current = None
    vals = []

    def flush(lineno):
        if len(vals) != 96:
            util.die(f"{path}:{lineno}: {current} has {len(vals)} tile "
                     f"groups (want 96)")
        tile_groups[current] = vals[:]
        order.append(current)

    for lineno, line in _read_raw(path):
        s = line.strip()
        m = _TILESET_HEADER_RE.match(s)
        if m:
            if current:
                flush(lineno)
            current, vals = m.group(1), []
            continue
        m = re.match(r"db\s+(.*)$", s)
        if not m or not current:
            continue
        for tok in m.group(1).split(","):
            tok = tok.strip()
            if tok not in _GROUP_INDEX:
                util.die(f"{path}:{lineno}: unknown palette group {tok!r}")
            vals.append(_GROUP_INDEX[tok])
    if current:
        flush("EOF")
    return tile_groups, order


def _parse_map_palette_sets(path):
    """color/data/map_palette_sets.asm: per tileset, 8 palette-constant
    names, positional (index = the palette-group 0-7 above)."""
    sets = {}
    order = []
    current = None
    vals = []

    def flush(lineno):
        if len(vals) != 8:
            util.die(f"{path}:{lineno}: {current} has {len(vals)} palette "
                     f"sets (want 8)")
        sets[current] = vals[:]
        order.append(current)

    for lineno, line in _read_raw(path):
        s = line.strip()
        m = _TILESET_HEADER_RE.match(s)
        if m:
            if current:
                flush(lineno)
            current, vals = m.group(1), []
            continue
        m = re.match(r"db\s+(\w+)", s)
        if m and current:
            vals.append(m.group(1))
    if current:
        flush("EOF")
    return sets, order


def _parse_roof_order(path):
    """color/data/roofpalettes.asm's RoofPalettes: dw list, positional by
    pokered map ID (matches map.def.index in the recomp project)."""
    names = []
    in_table = False
    for lineno, line in _read_raw(path):
        s = line.strip()
        if s.startswith("RoofPalettes:"):
            in_table = True
            continue
        if not in_table:
            continue
        m = re.match(r"dw\s+(\w+)", s)
        if m:
            names.append(m.group(1))
            continue
        if s == "":
            continue
        break  # first non-dw, non-blank line (a Label:) ends the table
    if not names:
        util.die(f"{path}: RoofPalettes table not found or empty")
    return names


def _parse_sprite_assignments(path):
    """color/sprites.asm SpritePaletteAssignments: 1-based picture ID (from
    the '; 0xNN: SPRITE_NAME' comment) -> OBJ palette 0-3, or "random" for
    the "db 4" per-instance sentinel (ColorOverworldSprite). Returned keyed
    0-based (pictureId - 1), matching a recomp sprite def's
    `source = "ROM:SpriteSheetPointerTable[N]"` index."""
    assignments = {}
    in_table = False
    pending_id = None
    header_re = re.compile(r"^;\s*0x([0-9a-fA-F]+):")
    for lineno, line in _read_raw(path):
        s = line.strip()
        if s.startswith("SpritePaletteAssignments:"):
            in_table = True
            continue
        if not in_table:
            continue
        m = header_re.match(s)
        if m:
            pending_id = int(m.group(1), 16)
            continue
        m = re.match(r"db\s+(\w+)", s)
        if m and pending_id is not None:
            tok = m.group(1)
            if tok == "4":
                assignments[pending_id - 1] = "random"
            elif tok in _SPR_PAL:
                assignments[pending_id - 1] = _SPR_PAL[tok]
            else:
                util.die(f"{path}:{lineno}: unknown sprite palette {tok!r}")
            pending_id = None
            continue
        if s and not s.startswith(";"):
            break  # next label (AnimationTileset1Palettes:) ends the table
    if not assignments:
        util.die(f"{path}: SpritePaletteAssignments not found or empty")
    return assignments


def extract_gbc_world(pokered_gbc):
    """pokered-gbc color/** -> the `world` table (see module docstring):
    real per-tile GBC BG-palette groups, per-town roof overrides, and
    overworld sprite OBJ palettes, for true overworld parity under
    COLORS=RED++ (LoadTilesetPalette / LoadTownPalette / ColorOverworldSprite)."""
    base = os.path.join(pokered_gbc, "color")

    tile_groups, ts_order = _parse_map_palette_assignments(
        os.path.join(base, "data/map_palette_assignments.asm"))
    pal_sets, ts_order2 = _parse_map_palette_sets(
        os.path.join(base, "data/map_palette_sets.asm"))
    if set(ts_order) != set(ts_order2):
        util.die("map_palette_assignments.asm / map_palette_sets.asm "
                 "tileset lists disagree")
    if len(ts_order) < 20:
        util.die(f"map_palette_assignments.asm: parsed only {len(ts_order)} "
                 f"tilesets (want ~24)")

    map_palettes, _ = _parse_rgb_table(
        os.path.join(base, "data/map_palettes.asm"),
        re.compile(r"^;\s*0x[0-9a-fA-F]+:\s*(\w+)\s*$"), 12)

    group_colors = {}
    for ts in ts_order:
        colors = []
        for slot, const in enumerate(pal_sets[ts]):
            if const not in map_palettes:
                util.die(f"map_palette_sets.asm: {ts} slot {slot}: unknown "
                         f"palette constant {const}")
            colors.append(map_palettes[const])
        group_colors[ts] = colors

    # Only these two tilesets are ever town-roof-swapped
    # (LoadTilesetPalette: `cp 0` / `cp PLATEAU` before calling
    # LoadTownPalette) -- the ROOF slot for every other tileset is static.
    roof_group = {ts: _GROUP_INDEX["ROOF"]
                  for ts in ("OVERWORLD", "PLATEAU") if ts in group_colors}

    roof_path = os.path.join(base, "data/roofpalettes.asm")
    roof_colors, _ = _parse_rgb_table(
        roof_path, re.compile(r"^(?!RoofPalettes)(\w+):\s*$"), 6)
    roof_order = _parse_roof_order(roof_path)
    roof_by_index = {}
    for i, name in enumerate(roof_order):
        if name not in roof_colors:
            util.die(f"{roof_path}: RoofPalettes references unknown label "
                     f"{name}")
        roof_by_index[i] = roof_colors[name]

    sprite_path = os.path.join(base, "data/spritepalettes.asm")
    raw_sprite_pals, _ = _parse_rgb_table(
        sprite_path, re.compile(r"^;\s*(\d+)\s*$"), 12)
    sprite_palettes = {int(k): v for k, v in raw_sprite_pals.items()}
    if len(sprite_palettes) != 8:
        util.die(f"{sprite_path}: parsed {len(sprite_palettes)} sprite "
                 f"palettes (want 8)")

    sprite_assignment = _parse_sprite_assignments(
        os.path.join(base, "sprites.asm"))
    if len(sprite_assignment) != 72:
        util.die(f"sprites.asm: parsed {len(sprite_assignment)} sprite "
                 f"palette assignments (want 72)")

    tile_groups_out = {ts: {i: v for i, v in enumerate(vals)}
                        for ts, vals in tile_groups.items()}

    return {
        "tileGroups": tile_groups_out,
        "groupColors": group_colors,
        "roofGroup": roof_group,
        "roofByMapIndex": roof_by_index,
        "spritePalettes": sprite_palettes,
        "spriteAssignment": sprite_assignment,
    }


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

    world = extract_gbc_world(pokered_gbc)

    # write_lua stamps "Generated by tools/build_data.py"; keep that header
    # but point the source field at the gbc tree.
    util.write_lua(
        out_path,
        {"source": "pokered-gbc data/super_palettes.asm + data/mon_palettes.asm"
                    " + color/**",
         "palettes": palettes,
         "order": order,
         "pokemon": mon_pals,
         "world": world},
        header="Red++ / pokered-gbc SuperPalettes (COLORS=RED++): 4 8-bit RGB\n"
               "colors per palette (color 0 first), including per-species\n"
               "pals and the GEN_2 MonsterPalettes assignment, plus `world`\n"
               "(true overworld tile/roof/sprite GBC coloring -- see this\n"
               "file's module docstring for its shape).")
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
