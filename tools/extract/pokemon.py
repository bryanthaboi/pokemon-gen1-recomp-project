"""Extract Pokémon species data.

Sources:
  data/pokemon/base_stats/*.asm   -> dex id, base stats, types, catch rate,
                                     base exp, level-1 moves, growth rate, TM/HM
  data/pokemon/names.asm          -> names in internal order
  data/pokemon/evos_moves.asm     -> evolutions + level-up learnsets
  constants/pokemon_constants.asm -> internal order (via constants.py)
  constants/pokedex_constants.asm -> dex order
  gfx/pics.asm                    -> pic label -> PNG file
  gfx/pokemon/front|back/*.png    -> battle sprites

Output:
  data/generated/pokemon.lua
  assets/generated/battle/front/*.png, back/*.png
"""

import os
import re

from . import gfx, util
from .util import parse_number, read_asm, split_args, warn


def parse_names(pokered):
    names = []
    for lineno, line in read_asm(os.path.join(pokered, "data/pokemon/names.asm")):
        m = re.match(r'dname\s+"([^"]*)"', line.strip())
        if m:
            names.append(m.group(1))
    return names  # internal order, 1-based


def parse_pic_files(pokered):
    files = {}
    # Mew's pics live in data/pokemon/mew.asm, squeezed into bank 1
    for rel in ("gfx/pics.asm", "data/pokemon/mew.asm"):
        for lineno, line in read_asm(os.path.join(pokered, rel)):
            m = re.match(r'(\w+)::?\s+INCBIN\s+"([^"]+\.pic)"', line.strip())
            if m:
                files[m.group(1)] = re.sub(r"\.pic$", ".png", m.group(2))
    return files


def parse_base_stats_file(path, rel):
    """One data/pokemon/base_stats/<name>.asm file."""
    out = {"source": rel}
    db_index = 0
    for lineno, line in read_asm(path):
        s = line.strip()
        m = re.match(r"dw\s+(\w+PicFront),\s*(\w+PicBack)", s)
        if m:
            out["picFront"], out["picBack"] = m.group(1), m.group(2)
            continue
        # NO_MOVE/UNUSED are filler tokens, not learnable moves (Mew's
        # list ends with UNUSED)
        m = re.match(r"tmhm\s+(.*)$", s)
        if m:
            out.setdefault("tmhm", []).extend(
                a.rstrip("\\").strip() for a in split_args(m.group(1))
                if a.rstrip("\\").strip() not in ("", "NO_MOVE", "UNUSED"))
            out["_in_tmhm"] = True
            continue
        if out.pop("_in_tmhm", False) and s and not s.startswith(("db", "dw", "INCBIN")):
            # tmhm continuation lines (backslash-continued macro args)
            out.setdefault("tmhm", []).extend(
                a.rstrip("\\").strip() for a in split_args(s)
                if a.rstrip("\\").strip() not in ("", "NO_MOVE", "UNUSED"))
            out["_in_tmhm"] = True
            continue
        m = re.match(r"db\s+(.*)$", s)
        if not m:
            continue
        args = split_args(m.group(1))
        if db_index == 0:
            out["dexConst"] = args[0]
        elif db_index == 1:
            st = [parse_number(a) for a in args]
            out["baseStats"] = {"hp": st[0], "attack": st[1], "defense": st[2],
                                "speed": st[3], "special": st[4]}
        elif db_index == 2:
            out["types"] = args if args[0] != args[1] else [args[0]]
        elif db_index == 3:
            out["catchRate"] = parse_number(args[0])
        elif db_index == 4:
            out["baseExp"] = parse_number(args[0])
        elif db_index == 5:
            out["level1Moves"] = [a for a in args if a != "NO_MOVE"]
        elif db_index == 6:
            out["growthRate"] = args[0].removeprefix("GROWTH_")
        db_index += 1
    out.pop("_in_tmhm", None)
    return out


def parse_dex_entries(pokered, species_order):
    """data/pokemon/dex_entries.asm: kind, height ft/in, weight (0.1 lb),
    dex text label -- pointer table is in internal species order."""
    lines = read_asm(os.path.join(pokered, "data/pokemon/dex_entries.asm"))
    pointer_order = []
    bodies = {}
    current = None
    for lineno, line in lines:
        s = line.strip()
        m = re.match(r"dw\s+(\w+DexEntry)$", s)
        if m and current is None:
            pointer_order.append(m.group(1))
            continue
        m = re.match(r"(\w+DexEntry):{1,2}\s*$", s)
        if m:
            current = m.group(1)
            bodies[current] = {}
            continue
        if not current:
            continue
        m = re.match(r'db\s+"([^"@]*)@?"', s)
        if m:
            bodies[current]["kind"] = m.group(1)
            continue
        m = re.match(r"db\s+(\d+),\s*(\d+)$", s)
        if m:
            bodies[current]["heightFt"] = int(m.group(1))
            bodies[current]["heightIn"] = int(m.group(2))
            continue
        m = re.match(r"dw\s+(\d+)$", s)
        if m:
            bodies[current]["weight"] = int(m.group(1))
            continue
        m = re.match(r"text_far\s+(\w+)", s)
        if m:
            bodies[current]["text"] = m.group(1)

    out = {}
    for i, label in enumerate(pointer_order):
        if i < len(species_order):
            out[species_order[i]] = bodies.get(label, {})
    return out


def parse_evos_moves(pokered, species_order):
    """evos_moves.asm: pointer table in internal order, then labeled bodies."""
    path = os.path.join(pokered, "data/pokemon/evos_moves.asm")
    lines = read_asm(path)
    pointer_order = []
    bodies = {}
    current = None
    for lineno, line in lines:
        s = line.strip()
        m = re.match(r"dw\s+(\w+EvosMoves)$", s)
        if m and current is None:
            pointer_order.append(m.group(1))
            continue
        m = re.match(r"(\w+EvosMoves):{1,2}\s*$", s)
        if m:
            current = m.group(1)
            bodies[current] = []
            continue
        m = re.match(r"db\s+(.*)$", s)
        if m and current:
            bodies[current].append([a for a in split_args(m.group(1))])

    result = {}
    for i, label in enumerate(pointer_order):
        if i >= len(species_order):
            break
        species = species_order[i]
        rows = bodies.get(label, [])
        evolutions, learnset = [], []
        section = 0  # 0 = evolutions, 1 = learnset
        for args in rows:
            if args == ["0"]:
                section += 1
                continue
            if section == 0:
                kind = args[0]
                if kind == "EVOLVE_LEVEL":
                    evolutions.append({"method": "LEVEL", "level": parse_number(args[1]),
                                       "species": args[2]})
                elif kind == "EVOLVE_ITEM":
                    evolutions.append({"method": "ITEM", "item": args[1],
                                       "level": parse_number(args[2]), "species": args[3]})
                elif kind == "EVOLVE_TRADE":
                    evolutions.append({"method": "TRADE", "level": parse_number(args[1]),
                                       "species": args[2]})
                else:
                    warn(f"evos_moves.asm ({label}): unknown evolution row {args}")
            elif section == 1:
                learnset.append({"level": parse_number(args[0]), "move": args[1]})
        result[species] = {"evolutions": evolutions, "learnset": learnset}
    return result


def extract(pokered, out_dir, assets_dir, species_order):
    names = parse_names(pokered)
    pics = parse_pic_files(pokered)
    evos = parse_evos_moves(pokered, species_order)
    dex_entries = parse_dex_entries(pokered, species_order)

    # the tower Ghost battle pic (gfx/pics.asm GhostPic)
    # the museum's fossil exhibit pics (DisplayMonFrontSpriteInBox)
    # BG-style plates: matte clears the surrounding color-0 field without
    # punching holes in white artwork (eyes, Articuno, Red's hat, etc.).
    for fossil in ("fossilaerodactyl", "fossilkabutops"):
        gfx.convert_png(os.path.join(pokered, f"gfx/pokemon/front/{fossil}.png"),
                        os.path.join(assets_dir, "battle/front", fossil + ".png"),
                        transparent_matte=True)
    gfx.convert_png(os.path.join(pokered, "gfx/battle/ghost.png"),
                    os.path.join(assets_dir, "battle/front/ghost.png"),
                    transparent_matte=True)
    # trainer-side battle pics: Red's back (RedPicBack), the old man's
    # back (OldManPicBack); party pokeball tiles are OAM-style
    gfx.convert_png(os.path.join(pokered, "gfx/player/redb.png"),
                    os.path.join(assets_dir, "battle/redb.png"),
                    transparent_matte=True)
    gfx.convert_png(os.path.join(pokered, "gfx/battle/oldmanb.png"),
                    os.path.join(assets_dir, "battle/oldmanb.png"),
                    transparent_matte=True)
    gfx.convert_png(os.path.join(pokered, "gfx/battle/balls.png"),
                    os.path.join(assets_dir, "battle/balls.png"),
                    transparent_color0=True)
    # trainer card badges, numbered tabs, frame tiles, circle and the
    # player's front pic (gfx/trainer_card/ + gfx/player/red.png)
    gfx.convert_png(os.path.join(pokered, "gfx/trainer_card/badges.png"),
                    os.path.join(assets_dir, "trainer_card/badges.png"),
                    transparent_color0=True)
    gfx.convert_png(os.path.join(pokered, "gfx/trainer_card/badge_numbers.png"),
                    os.path.join(assets_dir, "trainer_card/badge_numbers.png"),
                    transparent_color0=True)
    gfx.convert_png(os.path.join(pokered, "gfx/trainer_card/trainer_info.png"),
                    os.path.join(assets_dir, "trainer_card/trainer_info.png"))
    gfx.convert_png(os.path.join(pokered, "gfx/trainer_card/circle_tile.png"),
                    os.path.join(assets_dir, "trainer_card/circle_tile.png"),
                    transparent_color0=True)
    gfx.convert_png(os.path.join(pokered, "gfx/player/red.png"),
                    os.path.join(assets_dir, "trainer_card/red.png"),
                    transparent_matte=True)

    # dex const -> dex number
    dex_names = util.parse_const_block(os.path.join(pokered, "constants/pokedex_constants.asm"))
    dex_num = {n: i for i, n in enumerate(dex_names) if n}

    base_dir = os.path.join(pokered, "data/pokemon/base_stats")
    by_dex_const = {}
    for fname in sorted(os.listdir(base_dir)):
        if not fname.endswith(".asm"):
            continue
        rel = f"data/pokemon/base_stats/{fname}"
        st = parse_base_stats_file(os.path.join(base_dir, fname), rel)
        if "dexConst" not in st:
            warn(f"{rel}: no dex id found")
            continue
        by_dex_const[st["dexConst"]] = st

    out = {}
    for idx, species in enumerate(species_order, start=1):
        if species.startswith(("MISSINGNO", "UNUSED", "FOSSIL_", "MON_GHOST")):
            continue  # glitch/placeholder slots have no base stats
        name = names[idx - 1] if idx - 1 < len(names) else species
        dex_const = "DEX_" + species
        st = by_dex_const.get(dex_const)
        if st is None:
            warn(f"species {species}: no base stats file for {dex_const}")
            continue
        front = pics.get(st.get("picFront", ""), "")
        back = pics.get(st.get("picBack", ""), "")
        front_dst = back_dst = None
        if front:
            base = os.path.splitext(os.path.basename(front))[0]
            front_dst = f"assets/generated/battle/front/{base}.png"
            size = gfx.convert_png(os.path.join(pokered, front),
                                   os.path.join(assets_dir, "battle/front", base + ".png"),
                                   transparent_matte=True)
            st["frontSize"] = size[0] // 8  # sprite dimension in tiles
        if back:
            base = os.path.splitext(os.path.basename(back))[0]
            back_dst = f"assets/generated/battle/back/{base}.png"
            gfx.convert_png(os.path.join(pokered, back),
                            os.path.join(assets_dir, "battle/back", base + ".png"),
                            transparent_matte=True)

        ev = evos.get(species, {"evolutions": [], "learnset": []})
        out[species] = {
            "id": species,
            "index": idx,                       # internal id
            "dex": dex_num.get(dex_const),
            "name": name,
            "source": st["source"],
            "types": st["types"],
            "baseStats": st["baseStats"],
            "catchRate": st["catchRate"],
            "baseExp": st["baseExp"],
            "level1Moves": st.get("level1Moves", []),
            "growthRate": st.get("growthRate"),
            "tmhm": st.get("tmhm", []),
            "learnset": ev["learnset"],
            "evolutions": ev["evolutions"],
            "spriteFront": front_dst,
            "spriteBack": back_dst,
            "frontSize": st.get("frontSize"),
            "dexEntry": dex_entries.get(species),
        }

    util.write_lua(os.path.join(out_dir, "pokemon.lua"), out,
                   header="Sources: data/pokemon/base_stats/*.asm, names.asm, evos_moves.asm")
    return out
