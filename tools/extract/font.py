"""Extract the text font and character map.

Sources:
  gfx/font/font.png        -> glyphs for codes $80-$FF (16 per row, 8x8)
  gfx/font/font_extra.png  -> glyphs for codes $60-$7F (border tiles etc.)
  constants/charmap.asm    -> printable char/token -> glyph code

Output:
  assets/generated/fonts/font.png        (black ink on transparent)
  assets/generated/fonts/font_extra.png
  data/generated/font.lua                (charmap sorted longest-first)
"""

import os
import re

from PIL import Image

from . import util
from .util import parse_number, read_asm, warn

# Tokens the runtime substitutes rather than draws.
RUNTIME_TOKENS = {"<NULL>", "<PAGE>", "<PKMN>", "<_CONT>", "<SCROLL>", "<NEXT>",
                  "<LINE>", "@", "<PARA>", "<PLAYER>", "<RIVAL>", "#", "<CONT>",
                  "<……>", "<DONE>", "<PROMPT>", "<TARGET>", "<USER>", "<PC>",
                  "<TM>", "<TRAINER>", "<ROCKET>", "<DEXEND>"}


def _ink(src):
    """1bpp/2bpp font PNG -> black ink with transparent background."""
    im = Image.open(src).convert("L")
    out = Image.new("RGBA", im.size, (0, 0, 0, 0))
    sp, dp = im.load(), out.load()
    for y in range(im.size[1]):
        for x in range(im.size[0]):
            if sp[x, y] < 128:
                dp[x, y] = (0, 0, 0, 255)
    return out


def convert_font(src, dst, patches=None):
    """Convert a font sheet; patches = [(png, src_tile, dst_tile), ...]
    overwrite 8x8 tiles with tiles taken from another sheet."""
    out = _ink(src)
    per_row = out.size[0] // 8
    for png, src_tile, dst_tile in patches or []:
        pat = _ink(png)
        pr = pat.size[0] // 8
        sx, sy = (src_tile % pr) * 8, (src_tile // pr) * 8
        dx, dy = (dst_tile % per_row) * 8, (dst_tile // per_row) * 8
        out.paste(pat.crop((sx, sy, sx + 8, sy + 8)), (dx, dy))
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    out.save(dst, optimize=True)
    return out.size


def parse_charmap(pokered):
    """charmap.asm entries for the main font range ($60-$FF)."""
    entries = []
    seen = set()
    for lineno, line in read_asm(os.path.join(pokered, "constants/charmap.asm")):
        m = re.match(r'charmap\s+"((?:[^"\\]|\\.)*)",\s*(\$\w+)', line.strip())
        if not m:
            continue
        seq = m.group(1).replace('\\"', '"')
        code = parse_number(m.group(2))
        if seq in seen:
            continue  # later blocks redefine codes for other gfx files
        seen.add(seq)
        if seq in RUNTIME_TOKENS:
            continue
        if 0x60 <= code <= 0xFF:
            entries.append({"seq": seq, "code": code})
    # ASCII double quote has no charmap.asm entry (the original writes the
    # curly “/” glyphs, and the dex height's inch mark is ″); alias it to
    # the closing-quote glyph $73 so hand-written port text renders a quote
    # instead of a blank + warning.
    entries.append({"seq": '"', "code": 0x73})
    # longest-first so the renderer can greedily match 'd 'l 's etc.
    entries.sort(key=lambda e: (-len(e["seq"]), e["seq"]))
    return entries


def extract(pokered, out_dir, assets_dir):
    fonts_dir = os.path.join(assets_dir, "fonts")
    main = convert_font(os.path.join(pokered, "gfx/font/font.png"),
                        os.path.join(fonts_dir, "font.png"))
    # The dex screen loads ′/″ over vChars2 tiles $60/$61 (engine/gfx/
    # load_pokedex_tiles.asm; charmap.asm maps ′->$60 ″->$61 for
    # gfx/pokedex/pokedex.png).  font_extra.png's own $60/$61 are the
    # unused <BOLD_A>/<BOLD_B>, so bake the dex glyphs into those slots.
    pokedex_png = os.path.join(pokered, "gfx/pokedex/pokedex.png")
    extra = convert_font(os.path.join(pokered, "gfx/font/font_extra.png"),
                         os.path.join(fonts_dir, "font_extra.png"),
                         patches=[(pokedex_png, 0, 0x60 - 0x60),
                                  (pokedex_png, 1, 0x61 - 0x60)])
    charmap = parse_charmap(pokered)
    data = {
        "source": "constants/charmap.asm, gfx/font/font.png, gfx/font/font_extra.png",
        "image": "assets/generated/fonts/font.png",
        "imageExtra": "assets/generated/fonts/font_extra.png",
        # font.png holds codes $80..$FF, font_extra.png holds $60..$7F
        "mainBase": 0x80,
        "extraBase": 0x60,
        "glyphsPerRow": main[0] // 8,
        "charmap": charmap,
    }
    util.write_lua(os.path.join(out_dir, "font.lua"), data,
                   header="Charmap sorted longest-first for greedy matching.")
    return data
