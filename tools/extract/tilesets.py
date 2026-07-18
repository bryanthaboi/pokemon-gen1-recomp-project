"""Extract tilesets: headers, blocksets, collision lists, converted graphics.

Sources:
  data/tilesets/tileset_headers.asm     -> tileset table (gfx, blockset, coll,
                                           counter tiles, grass tile, anim)
  data/tilesets/collision_tile_ids.asm  -> WALKABLE tile ids per collision set
  data/tilesets/warp_tile_ids.asm       -> warp-activating tile ids
  gfx/tilesets.asm                      -> label -> file mapping (INCBIN)
  gfx/blocksets/*.bst                   -> 16 bytes per block: 4x4 tile ids
  gfx/tilesets/*.png                    -> 2bpp tile graphics (16 tiles/row)

Output:
  data/generated/tilesets.lua
  assets/generated/tilesets/<name>.png
"""

import os
import re

from . import gfx, util
from .util import parse_number, read_asm, split_args, warn


def parse_incbin_labels(pokered):
    """Map asm labels like Overworld_Block/Overworld_GFX to repo file paths."""
    labels = {}
    path = os.path.join(pokered, "gfx/tilesets.asm")
    pending = []
    for lineno, line in read_asm(path):
        m = re.match(r"(\w+)::?\s*$", line.strip())
        if m:
            pending.append(m.group(1))
            continue
        m = re.match(r'(?:(\w+)::?\s+)?INCBIN\s+"([^"]+)"', line.strip())
        if m:
            if m.group(1):
                pending.append(m.group(1))
            src = m.group(2)
            for lbl in pending:
                labels[lbl] = src
            pending = []
        elif line.strip():
            pending = []
    return labels


def parse_collision(pokered):
    """Parse coll_tiles lists.  Multiple labels may share one list."""
    path = os.path.join(pokered, "data/tilesets/collision_tile_ids.asm")
    colls = {}
    pending = []
    for lineno, line in read_asm(path):
        s = line.strip()
        m = re.match(r"(\w+_Coll)::?\s*$", s)
        if m:
            pending.append(m.group(1))
            continue
        m = re.match(r"coll_tiles\s*(.*)$", s)
        if m:
            tiles = [parse_number(t) for t in split_args(m.group(1)) if t]
            for lbl in pending:
                colls[lbl] = tiles
            pending = []
    if "Overworld_Coll" not in colls:
        util.die("collision_tile_ids.asm did not parse as expected")
    return colls


def _parse_tile_id_lists(path, macro):
    """Parse `.SomeLabel:` groups whose bodies are `<macro> $xx, ...` lines.

    Plain `db` lines do not terminate a group (the source uses fallthrough:
    e.g. GateWarpTileIDs is `db $3B` falling through into the RedsHouse
    list), so a group stays open and keeps collecting until a terminated
    `<macro>` line is seen.  Returns label -> [tile ids].
    """
    groups = []  # (labels, tiles, open)
    open_groups = []
    last_was_label = False
    for lineno, line in read_asm(path):
        s = line.strip()
        if not s:
            continue
        m = re.match(r"\.(\w+):?\s*$", s)
        if m:
            if last_was_label and open_groups and not open_groups[-1][1]:
                open_groups[-1][0].append(m.group(1))
            else:
                g = ([m.group(1)], [], True)
                groups.append(g)
                open_groups.append(g)
            last_was_label = True
            continue
        last_was_label = False
        m = re.match(rf"(?:{macro}|db)\s+(.*)$", s)
        if m and open_groups:
            tiles = []
            for t in split_args(m.group(1)):
                try:
                    v = parse_number(t)
                except ValueError:
                    continue
                if v >= 0:
                    tiles.append(v)
            for g in open_groups:
                g[1].extend(tiles)
            if s.startswith(macro):
                open_groups = []
    out = {}
    for labels, tiles, _ in groups:
        for lbl in labels:
            out[lbl] = tiles
    return out


def parse_warp_tiles(pokered):
    """warp_tile_ids.asm: tile ids that trigger a warp when stood on.

    Labels are `.<TilesetName>WarpTileIDs` where TilesetName matches the
    tileset_headers.asm macro name (Overworld, RedsHouse1, ...).
    """
    path = os.path.join(pokered, "data/tilesets/warp_tile_ids.asm")
    raw = _parse_tile_id_lists(path, "warp_tiles")
    return {lbl.removesuffix("WarpTileIDs"): tiles for lbl, tiles in raw.items()}


def parse_door_tiles(pokered):
    """door_tile_ids.asm: keyed by tileset CONSTANT via a dbw pointer table."""
    path = os.path.join(pokered, "data/tilesets/door_tile_ids.asm")
    by_label = _parse_tile_id_lists(path, "door_tiles")
    doors = {}
    for lineno, line in read_asm(path):
        m = re.match(r"dbw\s+(\w+),\s*\.(\w+)", line.strip())
        if m:
            const, label = m.groups()
            if label not in by_label:
                warn(f"door_tile_ids.asm:{lineno}: unknown label .{label}")
                continue
            doors[const] = by_label[label]
    return doors


def read_blockset(path):
    """A blockset is a flat list of blocks; each block is 16 tile ids (4x4)."""
    with open(path, "rb") as f:
        raw = f.read()
    if len(raw) % 16 != 0:
        util.die(f"blockset {path} size {len(raw)} is not a multiple of 16")
    return [list(raw[i:i + 16]) for i in range(0, len(raw), 16)]


TILESET_RE = re.compile(
    r"tileset\s+(\w+),\s*([\w$-]+),\s*([\w$-]+),\s*([\w$-]+),\s*([\w$-]+),\s*(\w+)"
)


def extract_flower_frames(pokered, assets_dir):
    """gfx/tilesets/flower/flower{1,2,3}.png: the animated flower tile
    frames cycled by home/vcopy.asm's tile animation."""
    from . import gfx
    for i in (1, 2, 3):
        gfx.convert_png(os.path.join(pokered, f"gfx/tilesets/flower/flower{i}.png"),
                        os.path.join(assets_dir, f"tilesets/flower{i}.png"))


def extract_spinner_tiles(pokered, assets_dir):
    """gfx/overworld/spinners.png (SpinnerArrowAnimTiles): the shared
    'blur' graphic engine/overworld/spinners.asm's LoadSpinnerArrowTiles
    VRAM-patches over the Gym/Facility spinner-arrow tile IDs while
    wMovementFlags.BIT_SPINNING is set (see data/tilesets/spinner_tiles.asm
    for the per-tileset dest tile mapping)."""
    from . import gfx
    gfx.convert_png(os.path.join(pokered, "gfx/overworld/spinners.png"),
                    os.path.join(assets_dir, "tilesets/spinners.png"))


def extract(pokered, out_dir, assets_dir, tileset_order):
    extract_flower_frames(pokered, assets_dir)
    extract_spinner_tiles(pokered, assets_dir)
    labels = parse_incbin_labels(pokered)
    colls = parse_collision(pokered)
    doors = parse_door_tiles(pokered)
    warps = parse_warp_tiles(pokered)

    headers = []
    path = os.path.join(pokered, "data/tilesets/tileset_headers.asm")
    for lineno, line in read_asm(path):
        m = TILESET_RE.match(line.strip())
        if m:
            headers.append((lineno, m))
    if len(headers) != len(tileset_order):
        util.die(f"tileset header count {len(headers)} != constant count {len(tileset_order)}")

    out = {}
    converted = {}
    for (lineno, m), const_name in zip(headers, tileset_order):
        name = m.group(1)  # e.g. Overworld
        counters = [parse_number(m.group(i)) for i in (2, 3, 4)]
        grass = parse_number(m.group(5))
        anim = m.group(6)

        gfx_src = labels.get(f"{name}_GFX")
        blk_src = labels.get(f"{name}_Block")
        if not gfx_src or not blk_src:
            util.die(f"tileset {name}: missing INCBIN labels in gfx/tilesets.asm")

        png_src = os.path.join(pokered, re.sub(r"\.2bpp$", ".png", gfx_src))
        base = os.path.splitext(os.path.basename(png_src))[0]
        png_dst = os.path.join(assets_dir, "tilesets", base + ".png")
        if png_src not in converted:
            size = gfx.convert_png(png_src, png_dst)
            converted[png_src] = size
        size = converted[png_src]

        blocks = read_blockset(os.path.join(pokered, blk_src))
        coll_label = f"{name}_Coll"
        if coll_label not in colls:
            util.die(f"tileset {name}: no collision list {coll_label}")

        out[const_name] = {
            "id": const_name,
            "source": f"data/tilesets/tileset_headers.asm:{lineno}",
            "image": f"assets/generated/tilesets/{base}.png",
            "imageWidth": size[0],
            "imageHeight": size[1],
            "tilesPerRow": size[0] // 8,
            "blocks": blocks,
            "walkable": sorted(colls[coll_label]),
            "counterTiles": [c for c in counters if c >= 0],
            "grassTile": grass if grass >= 0 else None,
            "doorTiles": sorted(doors.get(const_name, [])),
            "warpTiles": sorted(set(warps.get(name, []))),
            "animation": anim,
        }

    util.write_lua(os.path.join(out_dir, "tilesets.lua"), out,
                   header="Sources: data/tilesets/*.asm, gfx/blocksets/*.bst, gfx/tilesets/*.png")
    return out
