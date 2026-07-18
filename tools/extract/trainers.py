"""Extract trainer classes and parties.

Sources:
  constants/trainer_constants.asm -> trainer class ids (OPP_*)
  data/trainers/names.asm         -> class display names
  data/trainers/parties.asm       -> parties per class:
       db level, mon, mon, ..., 0          (all same level)
       db $FF, lvl, mon, lvl, mon, ..., 0  (mixed levels)
  gfx/trainers/*.png              -> class battle pics (via gfx/pics.asm)

Output:
  data/generated/trainers.lua
  assets/generated/battle/trainers/*.png
"""

import os
import re

from . import gfx, util
from .util import parse_number, read_asm, split_args, warn


def parse_trainer_consts(pokered):
    path = os.path.join(pokered, "constants/trainer_constants.asm")
    names = []
    for lineno, line in read_asm(path):
        m = re.match(r"trainer_const\s+(\w+)|const\s+(OPP_\w+)", line.strip())
        if m:
            names.append(m.group(1) or m.group(2))
    return names


def parse_parties(pokered):
    """parties.asm: XData: labels with db rows until next label."""
    path = os.path.join(pokered, "data/trainers/parties.asm")
    order, parties = [], {}
    current = None
    for lineno, line in read_asm(path):
        s = line.strip()
        m = re.match(r"(\w+)Data:{1,2}\s*$", s)
        if m:
            current = m.group(1)
            order.append(current)
            parties[current] = []
            continue
        m = re.match(r"db\s+(.*)$", s)
        if m and current:
            a = split_args(m.group(1))
            if a and a[-1] == "0":
                a = a[:-1]
            if not a:
                continue
            party = []
            if a[0] in ("$FF", "-1"):
                it = iter(a[1:])
                for lvl, mon in zip(it, it):
                    party.append({"level": parse_number(lvl), "species": mon})
            else:
                lvl = parse_number(a[0])
                for mon in a[1:]:
                    party.append({"level": lvl, "species": mon})
            parties[current].append(party)
    return order, parties


def parse_move_choices(pokered):
    """move_choices.asm: AI modification layers (1/2/3) per class."""
    mods = []
    for lineno, line in read_asm(os.path.join(pokered, "data/trainers/move_choices.asm")):
        m = re.match(r"move_choices(?:\s+(.*))?$", line.strip())
        if m is not None and not line.strip().startswith("MACRO"):
            args = [int(a) for a in split_args(m.group(1) or "") if a.strip().isdigit()]
            mods.append(args)
    return mods


def extract(pokered, out_dir, assets_dir):
    consts = parse_trainer_consts(pokered)
    consts = [c for c in consts if c and c != "NOBODY"]
    move_choices = parse_move_choices(pokered)

    names = []
    for lineno, line in read_asm(os.path.join(pokered, "data/trainers/names.asm")):
        m = re.match(r'li\s+"([^"]*)"', line.strip())
        if m:
            names.append(m.group(1).replace("#", "POKé"))

    order, parties = parse_parties(pokered)

    # pic labels via gfx/pics.asm: YoungsterPic:: INCBIN "gfx/trainers/youngster.pic"
    pics = {}
    for lineno, line in read_asm(os.path.join(pokered, "gfx/pics.asm")):
        m = re.match(r'(\w+)Pic::?\s+INCBIN\s+"(gfx/trainers/[^"]+)"', line.strip())
        if m:
            pics[m.group(1)] = re.sub(r"\.pic$", ".png", m.group(2))

    # base prize money: reward = baseMoney * level of last enemy mon
    money = []
    for lineno, line in read_asm(os.path.join(pokered, "data/trainers/pic_pointers_money.asm")):
        m = re.match(r"pic_money\s+\w+,\s*(\d+)", line.strip())
        if m:
            money.append(int(m.group(1)) // 100)

    out = {}
    for i, label in enumerate(order):
        const = "OPP_" + consts[i] if i < len(consts) else None
        if const is None:
            warn(f"parties.asm: no trainer constant for {label}Data")
            continue
        pic_src = pics.get(label)
        pic_dst = None
        if pic_src:
            base = os.path.splitext(os.path.basename(pic_src))[0]
            pic_dst = f"assets/generated/battle/trainers/{base}.png"
            gfx.convert_png(os.path.join(pokered, pic_src),
                            os.path.join(assets_dir, "battle/trainers", base + ".png"),
                            transparent_matte=True)
        out[const] = {
            "id": const,
            "index": i + 1,
            "name": names[i] if i < len(names) else label,
            "source": "data/trainers/parties.asm",
            "pic": pic_dst,
            "baseMoney": money[i] if i < len(money) else 0,
            "aiMods": move_choices[i] if i < len(move_choices) else [],
            "parties": parties[label],
        }
    if "OPP_YOUNGSTER" not in out or not out["OPP_YOUNGSTER"]["parties"]:
        util.die("trainer extraction sanity check failed")
    util.write_lua(os.path.join(out_dir, "trainers.lua"), out,
                   header="Sources: data/trainers/parties.asm, names.asm; parties indexed 1-based\n"
                          "as used by object_event trainer args.")
    return out
