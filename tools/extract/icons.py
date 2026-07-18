"""Extract the party-menu mon icons.

Sources:
  data/pokemon/menu_icons.asm  MonPartyData: one ICON_* nybble per
                               species in Pokédex order
  gfx/icons/*.png              the bug/plant/quadruped/snake icons as
                               8x32 columns of two 8x16 left halves
                               (animation frames 1+2); the other icons
                               reuse overworld sprites
                               (engine/menus/party_menu.asm)

Output: data/generated/icons.lua (byDex list + icon -> asset paths)
        assets/generated/icons/{bug,plant,quadruped,snake}.png
        (16x32: two 16x16 frames stacked)
"""

import os
import re

from PIL import Image

from . import gfx, util

# ICON_* -> already-extracted overworld sprite sheets (16x16 frame 0)
SPRITE_ICONS = {
    "MON": "assets/generated/sprites/monster.png",
    "BALL": "assets/generated/sprites/poke_ball.png",
    "HELIX": "assets/generated/sprites/fossil.png",
    "FAIRY": "assets/generated/sprites/fairy.png",
    "BIRD": "assets/generated/sprites/bird.png",
    "WATER": "assets/generated/sprites/seel.png",
}

SHEET_ICONS = ("BUG", "GRASS", "SNAKE", "QUADRUPED")
SHEET_FILES = { "BUG": "bug", "GRASS": "plant", "SNAKE": "snake",
                "QUADRUPED": "quadruped" }


def _reassemble_icon(src, dst):
    """8x32 column = two 8x16 LEFT halves (frames 1+2); each frame is
    the half plus its X-mirror (AnimatePartyMon swaps tile frames; the
    icons are symmetric).  Output: 16x32, frames stacked."""
    im = Image.open(src).convert("L")
    if im.size != (8, 32):
        util.die(f"{src}: expected 8x32 icon column, got {im.size}")
    out = Image.new("L", (16, 32), 255)
    for f in range(2):
        half = im.crop((0, f * 16, 8, (f + 1) * 16))
        out.paste(half, (0, f * 16))
        out.paste(half.transpose(Image.FLIP_LEFT_RIGHT), (8, f * 16))
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    gfx._save_png(gfx._convert_image(out, transparent_color0=True), dst)


def extract(pokered, out_dir, assets_dir):
    by_dex = []
    started = False
    for lineno, line in util.read_asm(
            os.path.join(pokered, "data/pokemon/menu_icons.asm")):
        s = line.strip()
        if s.startswith("MonPartyData:"):
            started = True
            continue
        m = re.match(r"nybble\s+ICON_(\w+)", s)
        if started and m:
            by_dex.append(m.group(1))
    if len(by_dex) != 151:
        util.die(f"menu_icons.asm parsed {len(by_dex)} icons (want 151)")

    icons = dict(SPRITE_ICONS)
    for name in SHEET_ICONS:
        fn = SHEET_FILES[name]
        _reassemble_icon(os.path.join(pokered, f"gfx/icons/{fn}.png"),
                         os.path.join(assets_dir, f"icons/{fn}.png"))
        icons[name] = f"assets/generated/icons/{fn}.png"

    util.write_lua(os.path.join(out_dir, "icons.lua"),
                   {"source": "data/pokemon/menu_icons.asm + gfx/icons/ "
                              "(engine/menus/party_menu.asm icon sprites)",
                    "byDex": by_dex,
                    "icons": icons},
                   header="Party menu icons: ICON name per Pokédex number and\n"
                          "the image each icon draws from (sprite sheets use\n"
                          "frame 0; the 16x32 icon sheets stack two real\n"
                          "animation frames).")
    return by_dex
