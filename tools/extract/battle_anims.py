"""Extract composed battle move animations (beams, blobs, projectiles...).

Sources:
  data/moves/animations.asm
      AttackAnimationPointers: one label per move (id order, NUM_ATTACKS=165).
      Each block is battle_anim rows terminated by `db -1`.  The battle_anim
      macro (defined in the same file) has two forms:
        4 args: battle_anim sound_move, subanim_id, tileset_id, frame_delay
                -> db (tileset << 6) | delay, sound - 1, subanim
        2 args: battle_anim sound_move, special_effect_id (SE_*, >= $C0)
                -> db effect, sound - 1
      (PlayAnimation in engine/battle/animations.asm:164 dispatches on the
      first byte: >= FIRST_SE_ID is a special effect.)
  data/battle_anims/subanimations.asm
      SubanimationPointers + per subanimation:
        db (SUBANIMTYPE_* << 5) | frame_block_count   (`subanim` macro)
        then count * `db frame_block_id, base_coord_id, frame_block_mode`
      (decoded by LoadSubanimation, engine/battle/animations.asm:270.)
  data/battle_anims/frame_blocks.asm
      FrameBlockPointers + per frame block: db tile_count, then tile_count *
      dbsprite x_tile, y_tile, x_px, y_px, tile, attrs  ->  OAM entry
      (y offset, x offset, tile, attrs); macros/gfx.asm:19.  Offsets are
      relative to the base coordinate; attrs use OAM_XFLIP/OAM_YFLIP/OAM_PRIO.
      (drawn by DrawFrameBlock, engine/battle/animations.asm:3.)
  data/battle_anims/base_coords.asm
      FrameBlockBaseCoords: db y, x pairs in OAM space (screen y+16, x+8).
  constants/move_animation_constants.asm
      SE_* / SUBANIM_* / FRAMEBLOCK_* / BASECOORD_* / FRAMEBLOCKMODE_* /
      SUBANIMTYPE_* values.
  engine/battle/animations.asm
      MoveAnimationTilesPointers (anim_tileset count, gfx label) + INCBINs
      -> which PNG each tileset id (upper 2 bits of the battle_anim first
      byte) uses and how many tiles are loaded.
  gfx/battle/move_anim_0.png, move_anim_1.png -> tilesheets (16 tiles/row).

Output:
  data/generated/battle_anims.lua
  assets/generated/battle/anims/move_anim_*.png (color 0 transparent; these
  are OAM sprites)

Playback semantics (subanimation types, frame block modes, enemy-turn
mirroring) are implemented in src/battle/AnimPlayer.lua.
"""

import os
import re

from . import gfx, util
from .util import parse_number, read_asm, split_args

NUM_ATTACKS = 165

SUBANIMTYPE_NAMES = [
    "NORMAL", "HVFLIP", "HFLIP", "COORDFLIP", "REVERSE", "ENEMY",
]

OAM_FLAGS = {"OAM_XFLIP": 0x20, "OAM_YFLIP": 0x40, "OAM_PRIO": 0x80,
             "OAM_PAL0": 0x00, "OAM_PAL1": 0x10}


def parse_anim_constants(pokered):
    """name -> value for every const in constants/move_animation_constants.asm
    (multiple const_def blocks; handles const_def N and const_skip N)."""
    path = os.path.join(pokered, "constants/move_animation_constants.asm")
    values = {}
    value = None
    for lineno, line in read_asm(path):
        s = line.strip()
        if not s:
            continue
        m = re.match(r"const_def(?:\s+(\S+))?$", s)
        if m:
            value = parse_number(m.group(1)) if m.group(1) else 0
            continue
        m = re.match(r"const_skip(?:\s+(\S+))?$", s)
        if m and value is not None:
            value += parse_number(m.group(1)) if m.group(1) else 1
            continue
        m = re.match(r"const\s+(\w+)$", s)
        if m and value is not None:
            values[m.group(1)] = value
            value += 1
    if "SE_SHAKE_SCREEN" not in values or "FRAMEBLOCKMODE_04" not in values:
        util.die("move_animation_constants.asm: expected constants not found")
    return values


def parse_pointer_table(lines, table_label, path, whole_table=False):
    """Labels of a `dw` pointer table, up to the first assert_table_length
    (or, with whole_table, through interior asserts to the table's end --
    AttackAnimationPointers continues past NUM_ATTACKS with the ball
    toss/poof and status animation entries)."""
    labels = []
    in_table = False
    for lineno, line in lines:
        s = line.strip()
        if s == table_label + ":":
            in_table = True
            continue
        if in_table:
            if s.startswith("assert_table_length"):
                if not whole_table:
                    return labels
                continue
            m = re.match(r"dw\s+(\w+)$", s)
            if m:
                labels.append(m.group(1))
                continue
            if s and not s.startswith("table_width"):
                return labels  # end of table (whole_table)
    util.die(f"{path}: pointer table {table_label} not found/unterminated")


def parse_base_coords(pokered):
    path = os.path.join(pokered, "data/battle_anims/base_coords.asm")
    coords = []
    for lineno, line in read_asm(path):
        s = line.strip()
        if s.startswith("assert_table_length"):
            break
        m = re.match(r"db\s+(\S+)\s*,\s*(\S+)$", s)
        if m:
            coords.append({"y": parse_number(m.group(1)),
                           "x": parse_number(m.group(2))})
    if len(coords) != 0xB1:  # BASECOORD_00..BASECOORD_B0
        util.die(f"base_coords.asm: expected 177 coords, got {len(coords)}")
    return coords


def _parse_attrs(argstr):
    flags = 0
    for tok in argstr.split("|"):
        tok = tok.strip()
        if tok in OAM_FLAGS:
            flags |= OAM_FLAGS[tok]
        else:
            flags |= parse_number(tok)
    return flags


def parse_frame_blocks(pokered):
    """FrameBlockPointers order -> list of frame blocks; each is a list of
    { y, x, tile, xflip, yflip [, prio] } OAM entries (offsets mod 256)."""
    path = os.path.join(pokered, "data/battle_anims/frame_blocks.asm")
    lines = read_asm(path)
    order = parse_pointer_table(lines, "FrameBlockPointers", path)

    bodies = {}       # label -> list of entries
    counts = {}       # label -> declared tile count
    cur = None        # list currently being filled
    cur_labels = []   # labels awaiting their `db count` line
    for lineno, line in lines:
        s = line.strip()
        if not s or s.startswith(("dw ", "table_width", "assert_table_length",
                                  "INCLUDE")):
            continue
        m = re.match(r"(\w+)::?$", s)
        if m:
            if m.group(1) in order:
                if m.group(1) in bodies:
                    util.die(f"{path}:{lineno}: duplicate body {m.group(1)}")
                cur_labels.append(m.group(1))
            else:
                cur_labels = []   # FrameBlockBaseCoords etc.
                cur = None
            continue
        m = re.match(r"dbsprite\s+(.*)$", s)
        if m:
            if cur is None:
                continue
            a = split_args(m.group(1))
            if len(a) != 6:
                util.die(f"{path}:{lineno}: dbsprite wants 6 args, got {a}")
            attrs = _parse_attrs(a[5])
            entry = {
                # macros/gfx.asm dbsprite: db (ytile*8)+ypx, (xtile*8)+xpx,
                # tile, attrs -- i.e. (y offset, x offset, tile, attrs)
                "y": (parse_number(a[1]) * 8 + parse_number(a[3])) & 0xFF,
                "x": (parse_number(a[0]) * 8 + parse_number(a[2])) & 0xFF,
                "tile": parse_number(a[4]),
                "xflip": bool(attrs & OAM_FLAGS["OAM_XFLIP"]),
                "yflip": bool(attrs & OAM_FLAGS["OAM_YFLIP"]),
            }
            if attrs & OAM_FLAGS["OAM_PRIO"]:
                entry["prio"] = True
            if attrs & OAM_FLAGS["OAM_PAL1"]:
                entry["pal1"] = True   # drawn with OBP1 ($6c) on the GB
            cur.append(entry)
            continue
        m = re.match(r"db\s+(\S+)$", s)
        if m:
            if cur_labels:
                cur = []
                n = parse_number(m.group(1))
                for label in cur_labels:
                    bodies[label] = cur
                    counts[label] = n
                cur_labels = []
            # else: trailing `db $00 ; unused` filler -- ignore
            continue

    blocks = []
    for label in order:
        if label not in bodies:
            util.die(f"{path}: missing body for {label}")
        if len(bodies[label]) < counts[label]:
            util.die(f"{path}: {label} declares {counts[label]} tiles "
                     f"but has {len(bodies[label])}")
        if len(bodies[label]) > counts[label]:
            # FrameBlock62 has 16 dbsprite rows but a count byte of 15; the
            # engine only ever draws the declared count.
            util.warn(f"frame_blocks.asm: {label} declares {counts[label]} "
                      f"tiles but has {len(bodies[label])}; truncating")
        blocks.append(bodies[label][:counts[label]])
    return blocks


def parse_subanimations(pokered, n_frame_blocks, n_base_coords, consts):
    """SubanimationPointers order ->
    { type = SUBANIMTYPE name, blocks = [{ block, coord, mode }, ...] }.
    First byte is (SUBANIMTYPE << 5) | count (`subanim` macro,
    data/battle_anims/subanimations.asm:97)."""
    path = os.path.join(pokered, "data/battle_anims/subanimations.asm")
    lines = read_asm(path)
    order = parse_pointer_table(lines, "SubanimationPointers", path)

    bodies = {}
    cur = None
    cur_labels = []
    for lineno, line in lines:
        s = line.strip()
        if not s:
            continue
        m = re.match(r"(\w+)::?$", s)
        if m:
            if m.group(1) in order:
                if m.group(1) in bodies:
                    util.die(f"{path}:{lineno}: duplicate body {m.group(1)}")
                cur_labels.append(m.group(1))
            else:
                cur_labels = []
                cur = None
            continue
        m = re.match(r"subanim\s+(\w+)\s*,\s*(\S+)$", s)
        if m:
            if not cur_labels:
                continue   # the macro definition body itself
            if m.group(1) not in consts:
                util.die(f"{path}:{lineno}: unknown type {m.group(1)}")
            cur = {
                "type": SUBANIMTYPE_NAMES[consts[m.group(1)]],
                "count": parse_number(m.group(2)),
                "blocks": [],
            }
            for label in cur_labels:
                bodies[label] = cur
            cur_labels = []
            continue
        m = re.match(r"db\s+(\w+)\s*,\s*(\w+)\s*,\s*(\w+)$", s)
        if m:
            if cur is None:
                continue
            for name in m.groups():
                if name not in consts:
                    util.die(f"{path}:{lineno}: unknown constant {name}")
            block, coord, mode = (consts[n] for n in m.groups())
            if block >= n_frame_blocks:
                util.die(f"{path}:{lineno}: frame block {block} out of range")
            if coord >= n_base_coords:
                util.die(f"{path}:{lineno}: base coord {coord} out of range")
            cur["blocks"].append({"block": block, "coord": coord,
                                  "mode": mode})
            continue

    subanims = []
    for label in order:
        if label not in bodies:
            util.die(f"{path}: missing body for {label}")
        body = bodies[label]
        if len(body["blocks"]) != body["count"]:
            util.die(f"{path}: {label} declares {body['count']} frame blocks "
                     f"but has {len(body['blocks'])}")
        subanims.append({"type": body["type"], "blocks": body["blocks"]})
    return subanims


def parse_move_anims(pokered, move_order, consts, n_subanims):
    """Per move constant: source line + list of rows
    { subanim, tileset, delay [, sound] } or { effect = "SE_*" [, sound] }."""
    path = os.path.join(pokered, "data/moves/animations.asm")
    lines = read_asm(path)
    pointers = parse_pointer_table(lines, "AttackAnimationPointers", path,
                                   whole_table=True)
    if len(pointers) < len(move_order):
        util.die(f"{path}: {len(pointers)} anim pointers < "
                 f"{len(move_order)} moves")

    anims = {}   # label -> (start lineno, list of rows)
    cur = None
    prev_was_label = False
    for lineno, line in lines:
        s = line.strip()
        if not s:
            continue
        m = re.match(r"(\w+)::?$", s)
        if m:
            if not prev_was_label:
                cur = (lineno, [])
            anims[m.group(1)] = cur   # consecutive labels alias one block
            prev_was_label = True
            continue
        prev_was_label = False
        m = re.match(r"battle_anim\s+(.*)$", s)
        if m and cur is not None:
            a = split_args(m.group(1))
            if len(a) == 2:
                if not a[1].startswith("SE_") or a[1] not in consts:
                    util.die(f"{path}:{lineno}: unknown special effect {a[1]}")
                row = {"effect": a[1]}
            elif len(a) == 4:
                if a[1] not in consts:
                    util.die(f"{path}:{lineno}: unknown subanimation {a[1]}")
                subanim = consts[a[1]]
                if subanim >= n_subanims:
                    util.die(f"{path}:{lineno}: subanim {subanim} "
                             f"out of range")
                delay = parse_number(a[3])
                if not 0 < delay <= 63:
                    util.die(f"{path}:{lineno}: delay {delay} out of range")
                row = {
                    "subanim": subanim,
                    "tileset": parse_number(a[2]),
                    "delay": delay,
                }
            else:
                util.die(f"{path}:{lineno}: battle_anim wants 2 or 4 args")
            if a[0] != "NO_MOVE":
                row["sound"] = a[0]
            cur[1].append(row)

    out = {}
    for i, move in enumerate(move_order):
        label = pointers[i]
        if label not in anims:
            util.die(f"{path}: missing animation block {label}")
        start, rows = anims[label]
        out[move] = {
            "source": f"data/moves/animations.asm:{start}",
            "seq": rows,
        }
    if len(out) != len(move_order):
        util.die(f"{path}: extracted {len(out)} move anims, "
                 f"expected {len(move_order)}")
    return out


def parse_tilesheets(pokered, assets_dir):
    """MoveAnimationTilesPointers (engine/battle/animations.asm) -> per
    battle-anim tileset id: converted PNG path + tile count.  Tileset ids 0
    and 2 share gfx/battle/move_anim_0.png (2 loads only 64 tiles)."""
    path = os.path.join(pokered, "engine/battle/animations.asm")
    lines = read_asm(path)
    rows = []          # (tile count, gfx label) in tileset id order
    incbins = {}       # gfx label -> source png (relative to pokered)
    pending = []
    for lineno, line in lines:
        s = line.strip()
        m = re.match(r"anim_tileset\s+(\S+)\s*,\s*(\w+)$", s)
        if m:
            rows.append((parse_number(m.group(1)), m.group(2)))
            continue
        m = re.match(r"(\w+)::?$", s)
        if m:
            pending.append(m.group(1))
            continue
        m = re.match(r'INCBIN\s+"([^"]+)"$', s)
        if m:
            for label in pending:
                incbins[label] = re.sub(r"\.2bpp$", ".png", m.group(1))
            pending = []
            continue
        if s:
            pending = []
    if len(rows) != 3:
        util.die(f"{path}: expected 3 anim_tileset rows, got {len(rows)}")

    sheets = {}
    converted = {}
    for tileset_id, (n_tiles, label) in enumerate(rows):
        if label not in incbins:
            util.die(f"{path}: no INCBIN found for {label}")
        src_rel = incbins[label]
        base = os.path.basename(src_rel)
        if src_rel not in converted:
            size = gfx.convert_png(
                os.path.join(pokered, src_rel),
                os.path.join(assets_dir, "battle", "anims", base),
                transparent_color0=True)
            converted[src_rel] = size
        w, h = converted[src_rel]
        sheets[tileset_id] = {
            "path": f"assets/generated/battle/anims/{base}",
            "width": w,
            "height": h,
            "tiles": n_tiles,
            "source": src_rel,
        }
    return sheets


# animation ids past the moves (constants/move_constants.asm after
# STRUGGLE): ball tosses, the send-out POOF, status/trade animations
MISC_ANIMS = [
    "SHOWPIC_ANIM", "STATUS_AFFECTED_ANIM", "ANIM_A8",
    "ENEMY_HUD_SHAKE_ANIM", "TRADE_BALL_DROP_ANIM",
    "TRADE_BALL_SHAKE_ANIM", "TRADE_BALL_TILT_ANIM",
    "TRADE_BALL_POOF_ANIM", "XSTATITEM_ANIM", "XSTATITEM_DUPLICATE_ANIM",
    "SHRINKING_SQUARE_ANIM", "ANIM_B1", "ANIM_B2", "ANIM_B3", "ANIM_B4",
    "ANIM_B5", "ANIM_B6", "ANIM_B7", "ANIM_B8", "ANIM_B9",
    "BURN_PSN_ANIM", "ANIM_BB", "SLP_PLAYER_ANIM", "SLP_ANIM",
    "CONF_PLAYER_ANIM", "CONF_ANIM", "SLIDE_DOWN_ANIM", "TOSS_ANIM",
    "SHAKE_ANIM", "POOF_ANIM", "BLOCKBALL_ANIM", "GREATTOSS_ANIM",
    "ULTRATOSS_ANIM", "SHAKE_SCREEN_ANIM", "HIDEPIC_ANIM", "ROCK_ANIM",
    "BAIT_ANIM",
]


def extract(pokered, out_dir, assets_dir, move_order):
    if len(move_order) != NUM_ATTACKS:
        util.die(f"battle_anims: expected {NUM_ATTACKS} moves, "
                 f"got {len(move_order)}")
    move_order = list(move_order) + MISC_ANIMS
    consts = parse_anim_constants(pokered)
    base_coords = parse_base_coords(pokered)
    frame_blocks = parse_frame_blocks(pokered)
    subanims = parse_subanimations(pokered, len(frame_blocks),
                                   len(base_coords), consts)
    move_anims = parse_move_anims(pokered, move_order, consts, len(subanims))
    tilesheets = parse_tilesheets(pokered, assets_dir)

    # sanity: every referenced tile must fit its sheet
    for move, anim in move_anims.items():
        for row in anim["seq"]:
            if "subanim" not in row:
                continue
            sheet = tilesheets[row["tileset"]]
            for entry in subanims[row["subanim"]]["blocks"]:
                for t in frame_blocks[entry["block"]]:
                    if t["tile"] >= sheet["tiles"]:
                        util.die(f"{move}: tile {t['tile']} out of range for "
                                 f"tileset {row['tileset']}")

    out = {
        # indexes are the ROM's 0-based ids throughout
        "tilesheets": tilesheets,
        "baseCoords": {i: c for i, c in enumerate(base_coords)},
        "frameBlocks": {i: b for i, b in enumerate(frame_blocks)},
        "subanims": {i: s for i, s in enumerate(subanims)},
        "moveAnims": move_anims,
    }
    util.write_lua(
        os.path.join(out_dir, "battle_anims.lua"), out,
        header="Sources: data/moves/animations.asm (battle_anim rows),\n"
               "data/battle_anims/{subanimations,frame_blocks,base_coords}"
               ".asm,\n"
               "constants/move_animation_constants.asm, "
               "engine/battle/animations.asm,\n"
               "gfx/battle/move_anim_*.png.\n"
               "Coordinates are OAM-space (screen x+8, y+16); offsets and\n"
               "flip math are 8-bit like the GB.  Playback: "
               "src/battle/AnimPlayer.lua.")
    return out
