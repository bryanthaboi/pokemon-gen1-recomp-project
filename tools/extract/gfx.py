"""Graphics conversion for pret/pokered PNGs.

The repo stores Game Boy graphics as 2-bit (or 1-bit) grayscale PNGs where
the *lightest* gray level corresponds to GB color 0 (this matches rgbgfx's
convention).  We convert them to RGBA PNGs using the classic DMG green-less
grayscale palette so LÖVE can load them directly.

Transparency modes:
  * oam  ,  every GB color 0 pixel becomes alpha 0 (hardware OAM rule;
            overworld people, emotes, battle anim sprites).
  * matte,  only color-0 pixels connected to the image edge become alpha 0.
            Interior whites (hat highlights, Articuno's body, etc.) stay
            opaque.  Use this for BG-style plates that need a clear
            background without punching holes in white artwork.  This is
            the RGBA equivalent of remapping shades into [0,127] and
            keeping 255 as a color key.
"""

import os
import re
from collections import deque

from PIL import Image

from . import util
from .util import parse_number, read_asm, split_args

# GB color 0..3 -> RGBA, lightest to darkest.
GB_SHADES = [
    (255, 255, 255, 255),
    (170, 170, 170, 255),
    (85, 85, 85, 255),
    (0, 0, 0, 255),
]


def _gray_to_index(v):
    """Map a grayscale byte (0/85/170/255) to a GB color index (0 = lightest).

    1-bit sources only use 0/255, which map to 3/0,  the same rounding
    formula covers both depths.
    """
    return 3 - round(v / 85)


def _matte_color0(out):
    """Flood-fill edge-connected opaque white (GB color 0) to alpha 0."""
    w, h = out.size
    px = out.load()
    q = deque()
    seen = set()

    def is_opaque_white(x, y):
        r, g, b, a = px[x, y]
        return a == 255 and r == 255 and g == 255 and b == 255

    for x in range(w):
        for y in (0, h - 1):
            if is_opaque_white(x, y):
                seen.add((x, y))
                q.append((x, y))
    for y in range(h):
        for x in (0, w - 1):
            if (x, y) not in seen and is_opaque_white(x, y):
                seen.add((x, y))
                q.append((x, y))

    while q:
        x, y = q.popleft()
        px[x, y] = (255, 255, 255, 0)
        for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
            if 0 <= nx < w and 0 <= ny < h and (nx, ny) not in seen \
               and is_opaque_white(nx, ny):
                seen.add((nx, ny))
                q.append((nx, ny))
    return out


def _convert_image(im, transparent_color0=False, transparent_matte=False):
    """Convert a grayscale PIL image to an RGBA image with the GB palette."""
    im = im.convert("L")
    out = Image.new("RGBA", im.size)
    src_px = im.load()
    dst_px = out.load()
    # Matte needs opaque whites first, then edge flood-fill.  OAM clears
    # every color-0 pixel up front.
    clear_color0 = transparent_color0 and not transparent_matte
    for y in range(im.size[1]):
        for x in range(im.size[0]):
            idx = _gray_to_index(src_px[x, y])
            if idx == 0 and clear_color0:
                dst_px[x, y] = (255, 255, 255, 0)
            else:
                dst_px[x, y] = GB_SHADES[idx]
    if transparent_matte:
        _matte_color0(out)
    return out


def _save_png(out, dst):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    out.save(dst, optimize=True)


def convert_png(src, dst, transparent_color0=False, transparent_matte=False):
    """Convert a pokered grayscale PNG to an RGBA PNG with the GB palette."""
    im = Image.open(src)
    _save_png(_convert_image(im, transparent_color0, transparent_matte), dst)
    return im.size


# Title screen graphics (drawn by engine/movie/title.asm):
#   PokemonLogoGraphics           gfx/title/pokemon_logo.png  (128x56, 2bpp)
#   Version_GFX (Red)             gfx/title/red_version.png   (80x8, 1bpp)
#   PlayerCharacterTitleGraphics  gfx/title/player.png        (40x56, 2bpp)
#   NintendoCopyrightLogoGraphics gfx/splash/copyright.png    (152x8, 2bpp)
# The Red front pic on the title screen is NOT a trainer pic (the player is
# not in data/trainers/), so it is converted here from gfx/title/player.png.
# player is OAM in the ROM, but color 0 is also used for hat/vest/shoe
# highlights that read as white against the title's white BG,  matte keeps
# those while clearing the surrounding plate.
TITLE_GRAPHICS = [
    ("logo", "gfx/title/pokemon_logo.png", False),
    ("version", "gfx/title/red_version.png", False),
    ("player", "gfx/title/player.png", True),
    ("copyright", "gfx/splash/copyright.png", False),
    # GameFreakLogoGraphics: the "GAME FREAK inc." row of the copyright
    # block (tiles $73-$7B, drawn by LoadCopyrightTiles and reused by the
    # end credits' CRED_COPYRIGHT screen)
    ("gamefreakInc", "gfx/title/gamefreak_inc.png", False),
]


def extract_title(pokered, assets_dir):
    """Convert the title-screen graphics to assets/generated/title/.

    Returns a manifest dict (key -> {path, width, height, source}); there is
    no separate gfx manifest file, so the caller embeds this in field.lua
    under the `title` key.
    """
    out = {}
    for key, src_rel, matte in TITLE_GRAPHICS:
        base = os.path.basename(src_rel)
        size = convert_png(os.path.join(pokered, src_rel),
                           os.path.join(assets_dir, "title", base),
                           transparent_matte=matte)
        out[key] = {
            "path": f"assets/generated/title/{base}",
            "width": size[0],
            "height": size[1],
            "source": src_rel,
        }
    return out


# ---------------------------------------------------------------------------
# Boot splash + attract-movie graphics
# (engine/movie/splash.asm + engine/movie/intro.asm)
# ---------------------------------------------------------------------------

def _read_text(pokered, rel):
    with open(os.path.join(pokered, rel), encoding="utf-8") as f:
        return f.read()


def _parse_oam_block(pokered, label):
    """The dbsprite entries of a labelled OAM block in splash.asm.

    dbsprite x, y, xpix, ypix, tile, attrs (macros/gfx.asm) -> the sprite's
    top-left lands at screen pixel (x*8 + xpix, y*8 + ypix).  Returns
    (x, y, tile, attrs-string) tuples.
    """
    out = []
    in_block = False
    for lineno, line in read_asm(os.path.join(pokered, "engine/movie/splash.asm")):
        s = line.strip()
        if s == f"{label}:":
            in_block = True
            continue
        if in_block:
            m = re.match(r"dbsprite\s+(\d+),\s*(\d+),\s*(\d+),\s*(\d+),"
                         r"\s*(\$\w+),\s*(.*)$", s)
            if not m:
                break
            if m.group(3) != "0" or m.group(4) != "0":
                util.die(f"splash.asm:{lineno}: unexpected dbsprite pixel offset")
            out.append((int(m.group(1)), int(m.group(2)),
                        parse_number(m.group(5)), m.group(6).strip()))
    if not out:
        util.die(f"splash.asm: OAM block {label} not found")
    return out


def _rebuild_gengar_poses(pokered):
    """The three Gengar intro poses as 56x56 grayscale images.

    gfx/intro/gengar.png (168x56) holds the three poses, but the ROM tile
    sheet is built with `rgbgfx --columns` (column-major tile order) and
    `tools/gfx --remove-duplicates --preserve=0x19,0x76` (Makefile:176-177),
    and each pose is drawn by recomposing that deduplicated sheet through a
    gfx/intro/gengar_N.tilemap: 49 bytes = 7x7 row-major tile indices
    (tile_ids GengarIntroTiles{1,2,3}, 7, 7 in data/tilemaps.asm), written
    to the screen at hlcoord 13,7 by IntroCopyTiles -> CopyTileIDs
    (engine/movie/intro.asm:271-276, engine/battle/animations.asm:2284).
    Tile 0 is blank (white) and tile 1 is the solid black tile reused for
    the intro's letterbox bars (IntroPlaceBlackTiles, intro.asm:227-233).
    """
    makefile = _read_text(pokered, "Makefile")
    if "gfx/intro/gengar.2bpp: RGBGFXFLAGS += --columns" not in makefile \
       or "gfx/intro/gengar.2bpp: tools/gfx += --remove-duplicates " \
          "--preserve=0x19,0x76" not in makefile:
        util.die("Makefile: gengar.2bpp build flags changed")
    tilemaps_asm = _read_text(pokered, "data/tilemaps.asm")
    for n in (1, 2, 3):
        if not re.search(rf"tile_ids GengarIntroTiles{n},\s*7,\s*7", tilemaps_asm):
            util.die(f"tilemaps.asm: GengarIntroTiles{n} is no longer 7x7")
    intro_asm = _read_text(pokered, "engine/movie/intro.asm")
    if "hlcoord 13, 7" not in intro_asm:
        util.die("intro.asm: IntroCopyTiles destination changed")

    im = Image.open(os.path.join(pokered, "gfx/intro/gengar.png")).convert("L")
    if im.size != (168, 56):
        util.die(f"gengar.png: expected 168x56, got {im.size}")

    # rgbgfx --columns tile order, then tools/gfx remove_duplicates: a tile
    # is dropped if an earlier kept tile is identical, unless its original
    # index is in the --preserve list
    tiles = [im.crop((tx * 8, ty * 8, tx * 8 + 8, ty * 8 + 8))
             for tx in range(21) for ty in range(7)]
    kept, seen = [], []
    for idx, t in enumerate(tiles):
        b = t.tobytes()
        if b in seen and idx not in (0x19, 0x76):
            continue
        kept.append(t)
        seen.append(b)
    if len(kept) != 95 or set(kept[0].tobytes()) != {255} \
       or set(kept[1].tobytes()) != {0}:
        util.die(f"gengar.png: deduplicated to {len(kept)} tiles "
                 "(expected 95 with blank tile 0 / black tile 1)")

    poses = []
    for n in (1, 2, 3):
        with open(os.path.join(pokered, f"gfx/intro/gengar_{n}.tilemap"),
                  "rb") as f:
            tilemap = f.read()
        if len(tilemap) != 49 or max(tilemap) >= len(kept):
            util.die(f"gengar_{n}.tilemap: not 49 in-range tile ids")
        pose = Image.new("L", (56, 56), 255)
        for i, tid in enumerate(tilemap):
            pose.paste(kept[tid], ((i % 7) * 8, (i // 7) * 8))
        # each pose must reproduce its 56x56 slice of the source PNG; the
        # only known exception is pose 1's tile (0,1), where the PNG stores
        # the solid black bar tile but the tilemap places blank
        crop = im.crop(((n - 1) * 56, 0, n * 56, 56))
        for ty in range(7):
            for tx in range(7):
                box = (tx * 8, ty * 8, tx * 8 + 8, ty * 8 + 8)
                if pose.crop(box).tobytes() != crop.crop(box).tobytes() \
                   and not (n == 1 and (tx, ty) == (0, 1)):
                    util.die(f"gengar pose {n}: tile ({tx},{ty}) does not "
                             "match the source PNG")
        poses.append(pose)
    return poses


def extract_intro(pokered, assets_dir):
    """Splash + intro fight graphics -> assets/generated/intro/.

    Splash (PlayShootingStar, intro.asm:305-341 + splash.asm):
      * falling_star.png: the small-stars OAM tile $A2 (splash.asm:148-150,
        237-239) that rains from the logo in 4 waves.
      * big_star.png: the big shooting star is NOT falling_star -- it is
        two tiles of the battle move animation sheet, MoveAnimationTiles1
        tiles 3 and 19 (gfx/battle/move_anim_1.png), left column plus an
        X-flipped right column (splash.asm:6-13, 230-235).
      * gamefreak_logo.png (16x24) drawn at screen (72,56) and the "GAME
        FREAK" letter row at (40,80), both OAM (GameFreakLogoOAMData,
        splash.asm:211-228).  The letter row reuses tiles of
        gamefreak_presents.png; gamefreak_text.png is that row pre-composed
        (80x8).  The "presents" tiles themselves are unused in the English
        release (LoadPresentsGraphic dummied out, intro.asm:359-364).
    All splash graphics are OAM sprites -> color 0 transparent.

    Fight (PlayIntroScene, intro.asm:23-141):
      * gengar_{1,2,3}.png: 56x56 poses rebuilt from gengar.png through the
        gengar_{1,2,3}.tilemap files (see _rebuild_gengar_poses).  The port
        moves each pose as one image, so edge-connected color 0 is matted
        like the title-screen Red portrait while interior whites remain.
      * red_nidorino_{1,2,3}.png: 48x48 OAM poses -> color 0 transparent.
    """
    out_dir = os.path.join(assets_dir, "intro")

    def entry(base, size, source):
        return {"path": f"assets/generated/intro/{base}",
                "width": size[0], "height": size[1], "source": source}

    manifest = {}
    for key, rel in (("fallingStar", "gfx/splash/falling_star.png"),
                     ("gamefreakLogo", "gfx/splash/gamefreak_logo.png"),
                     ("gamefreakPresents", "gfx/splash/gamefreak_presents.png")):
        base = os.path.basename(rel)
        size = convert_png(os.path.join(pokered, rel),
                           os.path.join(out_dir, base), transparent_color0=True)
        manifest[key] = entry(base, size, rel)
    if manifest["fallingStar"]["width"] != 8 \
       or (manifest["gamefreakLogo"]["width"],
           manifest["gamefreakLogo"]["height"]) != (16, 24) \
       or manifest["gamefreakPresents"]["width"] != 104:
        util.die("splash graphics: unexpected sizes")

    # falling_star.png holds two small stars: the upper one in GB color 1,
    # the lower one in color 2.  MoveDownSmallStars toggles OBP1 with
    # %10100000 every step (splash.asm:199-203), blanking colors 2/3 so the
    # lower star blinks; falling_star_blink.png is that toggled state
    # (color >= 2 hidden) for pixel-exact blinking.
    star_src = Image.open(
        os.path.join(pokered, "gfx/splash/falling_star.png")).convert("L")
    blink = Image.new("RGBA", star_src.size, (255, 255, 255, 0))
    n_hidden = 0
    for y in range(star_src.size[1]):
        for x in range(star_src.size[0]):
            idx = _gray_to_index(star_src.getpixel((x, y)))
            if idx == 1:
                blink.putpixel((x, y), GB_SHADES[1])
            elif idx >= 2:
                n_hidden += 1
    if not n_hidden:
        util.die("falling_star.png: no color-2 (blinking) star pixels found")
    _save_png(blink, os.path.join(out_dir, "falling_star_blink.png"))
    manifest["fallingStarBlink"] = entry(
        "falling_star_blink.png", blink.size,
        "gfx/splash/falling_star.png with OBP1 colors 2/3 blanked "
        "(MoveDownSmallStars, engine/movie/splash.asm:199-203)")

    # the "GAME FREAK" letter row: OAM entries on grid row 12 place
    # gamefreak_presents tiles $80.. plus the blank tile $93 (splash.asm)
    oam = _parse_oam_block(pokered, "GameFreakLogoOAMData")
    text_row = sorted((x, tile) for x, y, tile, _ in oam if y == 12)
    logo_row = sorted((y, x, tile) for x, y, tile, _ in oam if y != 12)
    if [t for _, _, t in logo_row] != [0x8D + i for i in range(6)] \
       or [(y, x) for y, x, _ in logo_row] != \
          [(y, x) for y in (9, 10, 11) for x in (10, 11)]:
        util.die("splash.asm: GameFreakLogoOAMData logo arrangement changed")
    presents = _convert_image(
        Image.open(os.path.join(pokered, "gfx/splash/gamefreak_presents.png")),
        transparent_color0=True)
    text_img = Image.new("RGBA", (8 * len(text_row), 8), (255, 255, 255, 0))
    for i, (x, tile) in enumerate(text_row):
        if x != text_row[0][0] + i:
            util.die("splash.asm: GAME FREAK letter row not contiguous")
        if tile != 0x93:    # $93 = the blank tile after the logo tiles
            if not 0x80 <= tile <= 0x8C:
                util.die(f"splash.asm: letter tile ${tile:02x} out of range")
            col = tile - 0x80
            text_img.paste(presents.crop((col * 8, 0, col * 8 + 8, 8)),
                           (i * 8, 0))
    _save_png(text_img, os.path.join(out_dir, "gamefreak_text.png"))
    manifest["gamefreakText"] = entry(
        "gamefreak_text.png", text_img.size,
        "gfx/splash/gamefreak_presents.png via GameFreakLogoOAMData "
        "(engine/movie/splash.asm:218-227)")

    # big shooting star: MoveAnimationTiles1 tiles 3 (top left) and 19
    # (bottom left), right column X-flipped (splash.asm:6-13, 230-235)
    splash_asm = _read_text(pokered, "engine/movie/splash.asm")
    if "MoveAnimationTiles1 tile 3" not in splash_asm \
       or "MoveAnimationTiles1 tile 19" not in splash_asm:
        util.die("splash.asm: big star tile sources changed")
    anim = _convert_image(
        Image.open(os.path.join(pokered, "gfx/battle/move_anim_1.png")),
        transparent_color0=True)
    if anim.size[0] != 128:
        util.die(f"move_anim_1.png: expected width 128, got {anim.size}")
    star = Image.new("RGBA", (16, 16), (255, 255, 255, 0))
    for row, tile in ((0, 3), (1, 19)):
        x, y = (tile % 16) * 8, (tile // 16) * 8
        quad = anim.crop((x, y, x + 8, y + 8))
        star.paste(quad, (0, row * 8))
        star.paste(quad.transpose(Image.FLIP_LEFT_RIGHT), (8, row * 8))
    _save_png(star, os.path.join(out_dir, "big_star.png"))
    manifest["bigStar"] = entry(
        "big_star.png", star.size,
        "gfx/battle/move_anim_1.png tiles 3/19 via "
        "GameFreakShootingStarOAMData (engine/movie/splash.asm:6-13,230-235)")

    manifest["gengar"] = {}
    for n, pose in enumerate(_rebuild_gengar_poses(pokered), 1):
        base = f"gengar_{n}.png"
        _save_png(
            _convert_image(pose, transparent_matte=True),
            os.path.join(out_dir, base))
        manifest["gengar"][f"frame{n}"] = entry(
            base, pose.size,
            f"gfx/intro/gengar.png via gfx/intro/gengar_{n}.tilemap "
            "(TILEMAP_GENGAR_INTRO_*, engine/movie/intro.asm)")

    manifest["nidorino"] = {}
    for n in (1, 2, 3):
        rel = f"gfx/intro/red_nidorino_{n}.png"
        base = os.path.basename(rel)
        size = convert_png(os.path.join(pokered, rel),
                           os.path.join(out_dir, base), transparent_color0=True)
        if size != (48, 48):
            util.die(f"{rel}: expected 48x48, got {size}")
        manifest["nidorino"][f"frame{n}"] = entry(base, size, rel)

    manifest["source"] = (
        "gfx/splash/*.png, gfx/intro/*.png + gengar_{1,2,3}.tilemap, "
        "gfx/battle/move_anim_1.png, engine/movie/splash.asm, "
        "engine/movie/intro.asm (PlayShootingStar, PlayIntroScene)")
    return manifest


# ---------------------------------------------------------------------------
# Slot machine wheel symbols
# ---------------------------------------------------------------------------

def extract_slots(pokered, assets_dir):
    """Slot machine graphics and the wheel-symbol crop table.

    LoadSlotMachineTiles (engine/slots/slot_machine.asm) copies
    SlotMachineTiles2 (gfx/slots/red_slots_2.png, 32x48 = 24 tiles, via
    engine/battle/animations.asm) into vChars0, so the spinning wheel
    symbols are OAM sprites with tile ids $00-$17.  SlotMachine_AnimWheel
    draws one byte of the wheel list per 8-pixel row, bottom-up
    (wBaseCoordY starts at $58 and shrinks by 8), as two side-by-side
    sprites with tiles t and t+1.  Each `dw SLOTS*` wheel entry
    (constants/script_constants.asm) is therefore one 16x16 symbol: the
    LOW byte is its bottom tile pair and the HIGH byte its top tile pair
    (SLOTS7 EQU $0200 -> top tiles $02/$03, bottom tiles $00/$01).

    In the 32x48 source sheet tile n sits at ((n % 4) * 8, (n // 4) * 8),
    so each symbol occupies one full 32x8 strip: the right 16x8 half is
    the symbol's top row and the left half its bottom row.  We reassemble
    the six symbols into contiguous 16x16 crops in symbols.png (color 0
    transparent, since the wheels are OAM sprites) and also convert both
    raw sheets.
    """
    path = os.path.join(pokered, "constants/script_constants.asm")
    order = []
    consts = {}
    for lineno, line in read_asm(path):
        m = re.match(r"DEF\s+SLOTS(\w+)\s+EQU\s+(\$\w+)", line.strip())
        if m and not m.group(1).startswith("_"):
            order.append(m.group(1))
            consts[m.group(1)] = parse_number(m.group(2))
    if order != ["7", "BAR", "CHERRY", "FISH", "BIRD", "MOUSE"]:
        util.die(f"script_constants.asm: unexpected SLOTS* symbols {order}")

    engine = "\n".join(l.strip() for _, l in read_asm(
        os.path.join(pokered, "engine/slots/slot_machine.asm")))
    if not re.search(r"ld hl, SlotMachineTiles2\s+ld de, vChars0", engine) \
       or "ld a, $58" not in engine:
        util.die("slot_machine.asm: wheel tile loading/drawing code changed")

    src = Image.open(os.path.join(pokered, "gfx/slots/red_slots_2.png"))
    if src.size != (32, 48):
        util.die(f"red_slots_2.png: expected 32x48, got {src.size}")
    rgba = _convert_image(src, transparent_color0=True)

    def tile_pair(n):
        """16x8 strip for OAM tiles n, n+1."""
        x, y = (n % 4) * 8, (n // 4) * 8
        return rgba.crop((x, y, x + 16, y + 8))

    sheet = Image.new("RGBA", (16 * len(order), 16), (255, 255, 255, 0))
    symbols = {}
    for i, name in enumerate(order):
        value = consts[name]
        hi, lo = value >> 8, value & 0xFF
        if hi != lo + 2 or lo % 4 != 0 or hi + 1 >= 24:
            util.die(f"SLOTS{name} = ${value:04x}: not a 2x2 tile pair in the sheet")
        sheet.paste(tile_pair(hi), (i * 16, 0))   # high byte = top row
        sheet.paste(tile_pair(lo), (i * 16, 8))   # low byte = bottom row
        symbols[name] = {
            "sheet": "assets/generated/slots/symbols.png",
            "x": i * 16, "y": 0, "w": 16, "h": 16,
            "tiles": value,     # dw SLOTS* value: high/low = top/bottom tile pair
        }
    _save_png(sheet, os.path.join(assets_dir, "slots", "symbols.png"))

    sheets = {}
    for key, rel in (("background", "gfx/slots/red_slots_1.png"),
                     ("wheel", "gfx/slots/red_slots_2.png")):
        base = os.path.basename(rel)
        size = convert_png(os.path.join(pokered, rel),
                           os.path.join(assets_dir, "slots", base))
        sheets[key] = {"path": f"assets/generated/slots/{base}",
                       "width": size[0], "height": size[1], "source": rel}

    # Static machine background tilemap (SlotMachineMap, INCBIN'd from
    # gfx/slots/slots.tilemap by slot_machine.asm and copied to the BG map by
    # LoadSlotMachineTiles).  It is 20xN tile ids that index the vChars2
    # background tiles; LoadSlotMachineTiles fills vChars2 with SlotMachineTiles1
    # (red_slots_1.png) first, so every id < $25 is one tile of that sheet.  We
    # store the grid plus the sheet's tile-atlas stride so the port can blit the
    # frame straight from red_slots_1.png.
    if not re.search(r'SlotMachineMap:\s*INCBIN "gfx/slots/slots\.tilemap"',
                     engine):
        util.die("slot_machine.asm: SlotMachineMap tilemap include changed")
    with open(os.path.join(pokered, "gfx/slots/slots.tilemap"), "rb") as fh:
        raw = list(fh.read())
    cols = 20  # SCREEN_WIDTH
    if not raw or len(raw) % cols != 0:
        util.die(f"slots.tilemap: {len(raw)} bytes is not a whole 20-col grid")
    rows = len(raw) // cols
    bg_tile_cols = sheets["background"]["width"] // 8
    bg_tile_count = bg_tile_cols * (sheets["background"]["height"] // 8)
    if max(raw) >= 0x25 or max(raw) >= bg_tile_count:
        util.die("slots.tilemap: tile id outside red_slots_1 / vChars2 range")
    tilemap = {
        "cols": cols, "rows": rows,
        "sheet": sheets["background"]["path"],
        "tileCols": bg_tile_cols,   # red_slots_1.png is a tileCols-wide atlas
        "tiles": [raw[r * cols:(r + 1) * cols] for r in range(rows)],
        "source": "gfx/slots/slots.tilemap (SlotMachineMap)",
    }

    return {
        "sheet": "assets/generated/slots/symbols.png",
        "width": 16 * len(order), "height": 16,
        "order": order,             # constant definition order
        "symbols": symbols,         # keys match field.lua's slotWheels names
        "sheets": sheets,
        "tilemap": tilemap,         # 20x12 static machine frame (red_slots_1)
        "source": "constants/script_constants.asm (SLOTS*), "
                  "engine/slots/slot_machine.asm (LoadSlotMachineTiles, "
                  "SlotMachine_AnimWheel), gfx/slots/red_slots_{1,2}.png, "
                  "gfx/slots/slots.tilemap",
    }


# ---------------------------------------------------------------------------
# Oak speech shrink frames
# ---------------------------------------------------------------------------

def extract_oak_speech(pokered, assets_dir):
    """The player-pic shrink frames from the end of the Oak speech.

    OakSpeech (engine/movie/oak_speech/oak_speech.asm .next) collapses
    RedPicFront through ShrinkPic1 and ShrinkPic2 (gfx/player.asm ->
    gfx/player/shrink{1,2}.png, 7x7-tile pics like the trainer pics)
    into the overworld walking sprite.  Converted like gfx/player/red.png
    (the trainer-card front pic): whites matted transparent.
    """
    out = {}
    for name in ("shrink1", "shrink2"):
        size = convert_png(os.path.join(pokered, f"gfx/player/{name}.png"),
                           os.path.join(assets_dir, "intro", f"{name}.png"),
                           transparent_matte=True)
        if size != (56, 56):
            util.die(f"gfx/player/{name}.png: expected 56x56, got {size}")
        out[name] = f"assets/generated/intro/{name}.png"
    out["source"] = ("gfx/player/shrink{1,2}.png "
                     "(engine/movie/oak_speech/oak_speech.asm ShrinkPic1/2)")
    return out


# ---------------------------------------------------------------------------
# Emotion bubbles
# ---------------------------------------------------------------------------

def extract_emotes(pokered, assets_dir):
    """The overworld emotion bubbles (engine/overworld/emotion_bubbles.asm).

    EmotionBubble copies 4 tiles (one 16x16 OAM block) from the entry of
    EmotionBubblesPointerTable selected by wWhichEmotionBubble; the indexes
    are the *_BUBBLE constants at the top of constants/script_constants.asm
    (EXCLAMATION_BUBBLE=0 -> ShockEmote, QUESTION_BUBBLE=1 -> QuestionEmote,
    SMILE_BUBBLE=2 -> HappyEmote).  The three 16x16 PNGs are packed into
    one sheet, color 0 transparent (they are OAM sprites).
    """
    consts = util.parse_const_block(
        os.path.join(pokered, "constants/script_constants.asm"), stop_at="SLOTS7")
    ptr = []
    incbins = {}
    path = os.path.join(pokered, "engine/overworld/emotion_bubbles.asm")
    for lineno, line in read_asm(path):
        s = line.strip()
        m = re.match(r"dw\s+(\w+Emote)$", s)
        if m:
            ptr.append(m.group(1))
            continue
        m = re.match(r'(\w+Emote):\s*INCBIN\s+"(gfx/emotes/\w+)\.2bpp"', s)
        if m:
            incbins[m.group(1)] = m.group(2) + ".png"
    if consts != ["EXCLAMATION_BUBBLE", "QUESTION_BUBBLE", "SMILE_BUBBLE"] \
       or len(ptr) != 3 or set(ptr) != set(incbins):
        util.die("emotion bubble constants/pointer table changed")

    sheet = Image.new("RGBA", (16 * len(ptr), 16), (255, 255, 255, 0))
    bubbles = []
    for i, label in enumerate(ptr):
        rel = incbins[label]
        im = Image.open(os.path.join(pokered, rel))
        if im.size != (16, 16):
            util.die(f"{rel}: expected 16x16, got {im.size}")
        sheet.paste(_convert_image(im, transparent_color0=True), (i * 16, 0))
        bubbles.append({"name": consts[i], "x": i * 16, "y": 0, "w": 16, "h": 16,
                        "source": rel})
    _save_png(sheet, os.path.join(assets_dir, "emotes.png"))
    return {
        "path": "assets/generated/emotes.png",
        "width": 16 * len(ptr), "height": 16,
        "bubbles": bubbles,     # index = *_BUBBLE constant value
        "source": "engine/overworld/emotion_bubbles.asm, gfx/emotes/*.png, "
                  "constants/script_constants.asm (*_BUBBLE)",
    }


# ---------------------------------------------------------------------------
# Overworld effect art (gfx/overworld/*.png): the ledge-hop shadow, the
# fishing rod + player-fishing overlays, the Pokémon Center heal
# machine, and the battle-transition tile.  The pokedex frame tiles
# ride along (gfx/pokedex/pokedex.png).
# ---------------------------------------------------------------------------

def extract_overworld_fx(pokered, assets_dir):
    out = {}
    fx = [
        ("shadow", "gfx/overworld/shadow.png", True),
        ("fishingRod", "gfx/overworld/fishing_rod.png", True),
        ("redFishSide", "gfx/overworld/red_fish_side.png", True),
        ("redFishFront", "gfx/overworld/red_fish_front.png", True),
        ("redFishBack", "gfx/overworld/red_fish_back.png", True),
        # OAM tiles: color 0 is transparent (the ball tile's corners)
        ("healMachine", "gfx/overworld/heal_machine.png", True),
        # one 8x8 tile drawn as a 2x2 block (LoadSmokeTileFourTimes):
        # the Cut / boulder-push dust puff
        ("smoke", "gfx/overworld/smoke.png", True),
        ("battleTransition", "gfx/overworld/battle_transition.png", False),
        ("pokedexFrame", "gfx/pokedex/pokedex.png", False),
    ]
    os.makedirs(os.path.join(assets_dir, "fx"), exist_ok=True)
    for key, rel, transparent in fx:
        base = os.path.splitext(os.path.basename(rel))[0]
        dst = os.path.join(assets_dir, "fx", base + ".png")
        size = convert_png(os.path.join(pokered, rel), dst,
                           transparent_color0=transparent)
        out[key] = {
            "path": f"assets/generated/fx/{base}.png",
            "width": size[0], "height": size[1], "source": rel,
        }
    return out


# ---------------------------------------------------------------------------
# Credits "THE END" graphic
# ---------------------------------------------------------------------------

def extract_the_end(pokered, assets_dir):
    """gfx/credits/the_end.png, drawn by Credits .showTheEnd.

    The Makefile builds the_end.2bpp with `tools/gfx --interleave`, which
    stores each pair of vertically stacked 8x8 tiles consecutively; the
    40x16 PNG is therefore the natural image of five 8x16 letters
    T, H, E, N, D left to right, and 2bpp tile $60+2c / $60+2c+1 is the
    top/bottom half of PNG column c.  TheEndTextString
    (engine/movie/credits.asm) lays those columns out as "T H E  E N D".
    `pattern` lists, per screen column, which 8x16 letter column of the
    PNG to draw (-1 = blank).
    """
    with open(os.path.join(pokered, "Makefile"), encoding="utf-8") as f:
        if not any("the_end.2bpp" in l and "--interleave" in l for l in f):
            util.die("Makefile: the_end.2bpp is no longer interleaved")

    rows = []
    current = None
    for lineno, line in read_asm(os.path.join(pokered, "engine/movie/credits.asm")):
        s = line.strip()
        if s == "TheEndTextString:":
            rows = []
            current = rows
            continue
        if current is None:
            continue
        m = re.match(r"db\s+(.+)$", s)
        if not m:
            if s:
                current = None
            continue
        row = []
        for tok in split_args(m.group(1)):
            if tok.startswith('"'):
                for ch in tok[1:-1]:
                    if ch == " ":
                        row.append(-1)
                    elif ch != "@":
                        util.die(f"credits.asm:{lineno}: unexpected char {ch!r} in THE END")
            else:
                row.append(parse_number(tok))
        rows.append(row)
    if len(rows) != 2 or len(rows[0]) != len(rows[1]):
        util.die("credits.asm: TheEndTextString shape changed")
    pattern = []
    for top, bottom in zip(rows[0], rows[1]):
        if top == -1:
            if bottom != -1:
                util.die("credits.asm: THE END rows misaligned")
            pattern.append(-1)
        else:
            if bottom != top + 1 or top % 2 != 0 or not 0x60 <= top <= 0x68:
                util.die(f"credits.asm: THE END tiles {top:#x}/{bottom:#x} not a column pair")
            pattern.append((top - 0x60) // 2)
    letters = "THEND"
    display = "".join(letters[c] if c >= 0 else " " for c in pattern)
    if display != "T H E  E N D":
        util.die(f"credits.asm: THE END layout changed: {display!r}")

    size = convert_png(os.path.join(pokered, "gfx/credits/the_end.png"),
                       os.path.join(assets_dir, "credits", "the_end.png"))
    if size != (40, 16):
        util.die(f"the_end.png: expected 40x16, got {size}")
    return {
        "path": "assets/generated/credits/the_end.png",
        "width": size[0], "height": size[1],
        "letters": letters,         # PNG columns, each 8x16 (x = index * 8)
        "letterWidth": 8, "letterHeight": 16,
        "pattern": pattern,         # screen columns -> PNG letter column (-1 = blank)
        "display": display,
        "source": "gfx/credits/the_end.png (Makefile --interleave), "
                  "engine/movie/credits.asm (TheEndTextString, .showTheEnd)",
    }


# ---------------------------------------------------------------------------
# In-battle HUD tiles
# ---------------------------------------------------------------------------

# During battles the GB overlays the $62-$7F font area with the HP bar /
# status sheet (home/load_font.asm LoadHpBarAndStatusTilePatterns -> tile
# $62) and the HUD line tiles (engine/battle/core.asm LoadHudTilePatterns:
# battle_hud_1 -> tile $6D, battle_hud_2+3 -> tile $73).  Color 0 is
# exported transparent so the underlines can overlap the mon pics.
BATTLE_HUD_GRAPHICS = [
    ("fontBattleExtra", "gfx/font/font_battle_extra.png", 0x62),
    ("hud1", "gfx/battle/battle_hud_1.png", 0x6D),
    ("hud2", "gfx/battle/battle_hud_2.png", 0x73),
    ("hud3", "gfx/battle/battle_hud_3.png", 0x76),
]


def extract_battle_hud(pokered, assets_dir):
    """Convert the battle HUD tile sheets to assets/generated/battle/."""
    out = {}
    for key, src_rel, base in BATTLE_HUD_GRAPHICS:
        name = os.path.basename(src_rel)
        size = convert_png(os.path.join(pokered, src_rel),
                           os.path.join(assets_dir, "battle", name),
                           transparent_color0=True)
        out[key] = {
            "path": f"assets/generated/battle/{name}",
            "width": size[0],
            "height": size[1],
            "tileBase": base,
            "source": src_rel,
        }
    return out


# ---------------------------------------------------------------------------
# Town map background (engine/items/town_map.asm)
# ---------------------------------------------------------------------------

def extract_town_map_bg(pokered, assets_dir):
    """gfx/town_map/town_map.{rle,png}: the 20x18 Kanto map background.

    The RLE stream is one byte per run -- high nibble = tile index into
    town_map.png, low nibble = run length -- terminated by $00
    (LoadTownMap's decompression loop).
    """
    with open(os.path.join(pokered, "gfx/town_map/town_map.rle"), "rb") as f:
        data = f.read()
    tiles = []
    for b in data:
        if b == 0:
            break
        tiles.extend([b >> 4] * (b & 0x0F))
    if len(tiles) != 20 * 18:
        util.die(f"town_map.rle decoded to {len(tiles)} tiles (want 360)")
    size = convert_png(os.path.join(pokered, "gfx/town_map/town_map.png"),
                       os.path.join(assets_dir, "townmap", "tiles.png"))
    cursor = convert_png(os.path.join(pokered, "gfx/town_map/town_map_cursor.png"),
                         os.path.join(assets_dir, "townmap", "cursor.png"),
                         transparent_color0=True)
    return {
        "tiles": {"path": "assets/generated/townmap/tiles.png",
                  "width": size[0], "height": size[1]},
        "cursor": {"path": "assets/generated/townmap/cursor.png",
                   "width": cursor[0], "height": cursor[1]},
        "map": tiles,
        "source": "gfx/town_map/town_map.rle + town_map.png "
                  "(engine/items/town_map.asm LoadTownMap)",
    }
