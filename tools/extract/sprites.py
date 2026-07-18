"""Extract overworld sprite sheets.

Sources:
  data/sprites/sprites.asm     -> SpriteSheetPointerTable (sprite id order)
  gfx/sprites.asm              -> label -> PNG file (INCBIN .2bpp -> .png)
  gfx/sprites/*.png            -> 16xN 2bpp sheets

A 12-tile sheet is 6 16x16 frames: stand down/up/left, walk down/up/left
(right facing = horizontal flip of left; see data/sprites/facings.asm).
A 4-tile sheet is a single immobile 16x16 frame.

Output:
  data/generated/sprites.lua
  assets/generated/sprites/<name>.png   (GB color 0 -> transparent)
"""

import os
import re

from . import gfx, util
from .util import read_asm, warn


def parse_sprite_files(pokered):
    """gfx/sprites.asm: RedSprite:: INCBIN "gfx/sprites/red.2bpp"."""
    files = {}
    for lineno, line in read_asm(os.path.join(pokered, "gfx/sprites.asm")):
        m = re.match(r'(\w+)::?\s+INCBIN\s+"([^"]+)"', line.strip())
        if m:
            files[m.group(1)] = m.group(2)
    return files


def parse_sheet_table(pokered):
    """data/sprites/sprites.asm: overworld_sprite Label, tilecount entries."""
    sheets = []
    for lineno, line in read_asm(os.path.join(pokered, "data/sprites/sprites.asm")):
        m = re.match(r"overworld_sprite\s+(\w+),\s*(\d+)", line.strip())
        if m:
            sheets.append((m.group(1), int(m.group(2)), lineno))
    return sheets


def extract(pokered, out_dir, assets_dir, sprite_order):
    files = parse_sprite_files(pokered)
    sheets = parse_sheet_table(pokered)
    if len(sheets) != len(sprite_order):
        util.die(f"sprite sheet count {len(sheets)} != sprite constant count {len(sprite_order)}")

    out = {}
    for (label, tiles, lineno), const in zip(sheets, sprite_order):
        src = files.get(label)
        if not src:
            warn(f"sprite {label}: no INCBIN in gfx/sprites.asm")
            continue
        png_src = os.path.join(pokered, re.sub(r"\.2bpp$", ".png", src))
        base = os.path.splitext(os.path.basename(png_src))[0]
        dst = os.path.join(assets_dir, "sprites", base + ".png")
        size = gfx.convert_png(png_src, dst, transparent_color0=True)
        frames = size[1] // 16
        out[const] = {
            "id": const,
            "source": f"data/sprites/sprites.asm:{lineno}",
            "image": f"assets/generated/sprites/{base}.png",
            "frames": frames,           # 6 = walker, 1 = immobile
            "walker": frames >= 6,
        }

    # the cycling sheet isn't a map SPRITE_ constant -- the engine swaps
    # it into the player's VRAM slot (LoadPlayerSpriteGraphics); extract
    # it under a synthetic id so the port can do the same swap
    bike_src = files.get("RedBikeSprite")
    if bike_src:
        png_src = os.path.join(pokered, re.sub(r"\.2bpp$", ".png", bike_src))
        dst = os.path.join(assets_dir, "sprites", "red_bike.png")
        size = gfx.convert_png(png_src, dst, transparent_color0=True)
        frames = size[1] // 16
        out["SPRITE_RED_BIKE"] = {
            "id": "SPRITE_RED_BIKE",
            "source": "gfx/sprites.asm RedBikeSprite (LoadPlayerSpriteGraphics)",
            "image": "assets/generated/sprites/red_bike.png",
            "frames": frames,
            "walker": frames >= 6,
        }

    util.write_lua(os.path.join(out_dir, "sprites.lua"), out,
                   header="Sources: data/sprites/sprites.asm, gfx/sprites/*.png\n"
                          "Frame order (walker): stand D/U/L, walk D/U/L; right = flipped left.")
    return out
