"""Extract move data.

Sources:
  data/moves/moves.asm       -> move macro: animation, effect, power, type, acc, pp
  data/moves/names.asm       -> names in move id order
  data/moves/sfx.asm         -> MoveSoundTable: db sfx_id, pitch mod, tempo mod
                                (played by GetMoveSound, engine/battle/animations.asm)
  constants/music_constants.asm -> music_const SFX_X, SFX_Label (id -> header label)
  data/moves/animations.asm  -> AttackAnimationPointers + battle_anim lists
                                (screen shake / flash special effects)

Output: data/generated/moves.lua
"""

import os
import re

from . import util
from .util import parse_number, read_asm, split_args


def parse_names(pokered):
    names = []
    for lineno, line in read_asm(os.path.join(pokered, "data/moves/names.asm")):
        m = re.match(r'li\s+"([^"]*)"', line.strip())
        if m:
            names.append(m.group(1))
    return names


def parse_sfx_keys(pokered):
    """SFX constant name -> the key used in data/generated/audio.lua's sfx table.

    constants/music_constants.asm maps each SFX_* constant to its sound header
    label (e.g. `music_const SFX_POUND, SFX_Pound`).  The audio extractor keys
    its sfx table by header label with the SFX_ prefix and the trailing bank
    suffix (_1/_2/_3) stripped (SFX_Pound_1 -> "Pound", SFX_Battle_09 ->
    "Battle_09"); apply the same transform here so anim.sound indexes
    audio.lua's sfx table directly.  The constants' labels carry no bank
    suffix, so only a bare _1/_2/_3 is stripped, matching sfx_key() in
    tools/extract/audio.py.
    """
    path = os.path.join(pokered, "constants/music_constants.asm")
    keys = {}
    for lineno, line in read_asm(path):
        m = re.match(r"music_const\s+(SFX_\w+),\s*(\w+)", line.strip())
        if m:
            keys[m.group(1)] = re.sub(r"_[123]$", "",
                                      m.group(2).removeprefix("SFX_"))
    if not keys:
        util.die("music_constants.asm: no music_const SFX entries found")
    return keys


def parse_move_sounds(pokered, n_moves):
    """data/moves/sfx.asm MoveSoundTable: per move (id order)
    `db SFX_CONST, pitch mod, tempo mod`.  Rows after assert_table_length
    (the out-of-range fallback entry) are ignored."""
    path = os.path.join(pokered, "data/moves/sfx.asm")
    rows = []
    for lineno, line in read_asm(path):
        s = line.strip()
        if s.startswith("assert_table_length"):
            break
        m = re.match(r"db\s+(SFX_\w+)\s*,\s*(\S+)\s*,\s*(\S+)$", s)
        if m:
            rows.append({
                "sfx": m.group(1),
                "pitch": parse_number(m.group(2)),
                "tempo": parse_number(m.group(3)),
                "line": lineno,
            })
    if len(rows) != n_moves:
        util.die(f"sfx.asm MoveSoundTable rows {len(rows)} != moves {n_moves}")
    return rows


# battle_anim special effects that imply whole-screen shake / flash
SHAKE_EFFECTS = {"SE_SHAKE_SCREEN"}
FLASH_EFFECTS = {"SE_FLASH_SCREEN_LONG", "SE_DARK_SCREEN_FLASH"}


def parse_anim_effects(pokered, n_moves):
    """Per move (id order), the set of SE_* special effects its animation
    uses (data/moves/animations.asm: AttackAnimationPointers -> battle_anim
    lists).  2-arg battle_anim lines are special effects; 4-arg lines are
    subanimations (constants/move_animation_constants.asm)."""
    path = os.path.join(pokered, "data/moves/animations.asm")
    lines = read_asm(path)

    pointers = []
    in_table = False
    for lineno, line in lines:
        s = line.strip()
        if s == "AttackAnimationPointers:":
            in_table = True
            continue
        if in_table:
            if s.startswith("assert_table_length"):
                break
            m = re.match(r"dw\s+(\w+)$", s)
            if m:
                pointers.append(m.group(1))
    if len(pointers) < n_moves:
        util.die(f"animations.asm: {len(pointers)} anim pointers < {n_moves} moves")

    anims = {}   # label -> shared list of battle_anim arg lists
    cur = None
    prev_was_label = False
    for lineno, line in lines:
        s = line.strip()
        if not s:
            continue
        m = re.match(r"(\w+)::?$", s)
        if m:
            if not prev_was_label:
                cur = []
            anims[m.group(1)] = cur   # consecutive labels alias one block
            prev_was_label = True
            continue
        prev_was_label = False
        m = re.match(r"battle_anim\s+(.*)$", s)
        if m and cur is not None:
            cur.append(split_args(m.group(1)))

    effects = []
    for label in pointers[:n_moves]:
        if label not in anims:
            util.die(f"animations.asm: missing animation block {label}")
        effects.append({a[1] for a in anims[label]
                        if len(a) == 2 and a[1].startswith("SE_")})
    return effects


def extract(pokered, out_dir, move_order):
    names = parse_names(pokered)
    rows = []
    for lineno, line in read_asm(os.path.join(pokered, "data/moves/moves.asm")):
        m = re.match(r"move\s+(.*)$", line.strip())
        if not m:
            continue
        a = split_args(m.group(1))
        if len(a) != 6:
            util.die(f"moves.asm:{lineno}: expected 6 args, got {a}")
        rows.append({
            "id": a[0],
            "effect": a[1],
            "power": parse_number(a[2]),
            "type": a[3],
            "accuracy": parse_number(re.sub(r"\s*percent$", "", a[4])),
            "pp": parse_number(a[5]),
            "line": lineno,
        })
    if len(rows) != len(move_order):
        util.die(f"moves.asm rows {len(rows)} != move constants {len(move_order)}")

    sfx_keys = parse_sfx_keys(pokered)
    sounds = parse_move_sounds(pokered, len(rows))
    anim_effects = parse_anim_effects(pokered, len(rows))

    out = {}
    for i, row in enumerate(rows):
        const = move_order[i]
        if const != row["id"]:
            util.warn(f"moves.asm order mismatch at {i}: {const} vs {row['id']}")
        snd = sounds[i]
        if snd["sfx"] not in sfx_keys:
            util.die(f"sfx.asm:{snd['line']}: unknown sfx constant {snd['sfx']}")
        anim = {
            "sound": sfx_keys[snd["sfx"]],
            "pitch": snd["pitch"],
            "tempo": snd["tempo"],
        }
        if anim_effects[i] & SHAKE_EFFECTS:
            anim["shake"] = True
        if anim_effects[i] & FLASH_EFFECTS:
            anim["flash"] = True
        out[row["id"]] = {
            "id": row["id"],
            "index": i + 1,
            "name": names[i] if i < len(names) else row["id"],
            "source": f"data/moves/moves.asm:{row['line']}",
            "effect": row["effect"],
            "power": row["power"],
            "type": row["type"],
            "accuracy": row["accuracy"],
            "pp": row["pp"],
            "anim": anim,
        }
    util.write_lua(os.path.join(out_dir, "moves.lua"), out,
                   header="Sources: data/moves/moves.asm, data/moves/names.asm,\n"
                          "data/moves/sfx.asm (MoveSoundTable), "
                          "data/moves/animations.asm.\n"
                          "anim.sound keys the sfx table in audio.lua; "
                          "pitch/tempo are the raw GetMoveSound modifiers.")
    return out
