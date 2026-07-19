#!/usr/bin/env python3
"""Regenerate this mod's original sprite art.

    python3 mods/examples/example_mini_conversion/tools/make_assets.py

Every pixel below is plotted from the shape tables in this file, so the
output is original work and nothing is read from the player's imported
cache.  The four colors are the Game Boy shade ramp; the renderer
re-shades them into the active palette, so no trueColor opt-out is needed.

Front sheets are 40x40 (frontSize 5), backs 32x32 and icons 16x32
(two 16x16 frames), matching what the battle and party screens expect.
"""

import os

from PIL import Image

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets")

# lightest first; index 0 is the transparent-white background
SHADES = [(248, 248, 248), (168, 168, 168), (88, 88, 88), (8, 8, 8)]

# Each species is a coarse silhouette painted from primitives: the point is
# that these are geometric marks, not creature art traced from anything.
SPECIES = {
    "emberkit": {"body": "triangle", "accent": 1},
    "tidepup": {"body": "diamond", "accent": 1},
    "mossling": {"body": "hex", "accent": 2},
}


def blank(w, h):
    return [[0] * w for _ in range(h)]


def stroke(grid, x, y, shade):
    if 0 <= y < len(grid) and 0 <= x < len(grid[0]):
        grid[y][x] = shade


def triangle(grid, cx, cy, r, shade):
    for row in range(r * 2):
        half = row // 2
        for x in range(cx - half, cx + half + 1):
            stroke(grid, x, cy - r + row, shade)


def diamond(grid, cx, cy, r, shade):
    for dy in range(-r, r + 1):
        span = r - abs(dy)
        for dx in range(-span, span + 1):
            stroke(grid, cx + dx, cy + dy, shade)


def hexagon(grid, cx, cy, r, shade):
    for dy in range(-r, r + 1):
        span = r if abs(dy) <= r // 2 else r - (abs(dy) - r // 2)
        for dx in range(-span, span + 1):
            stroke(grid, cx + dx, cy + dy, shade)


SHAPES = {"triangle": triangle, "diamond": diamond, "hex": hexagon}


def outline(grid, shade):
    """Darken every lit pixel that touches an unlit one."""
    h, w = len(grid), len(grid[0])
    edges = []
    for y in range(h):
        for x in range(w):
            if not grid[y][x]:
                continue
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nx, ny = x + dx, y + dy
                if not (0 <= nx < w and 0 <= ny < h) or not grid[ny][nx]:
                    edges.append((x, y))
                    break
    for x, y in edges:
        grid[y][x] = shade


def save(grid, path):
    h, w = len(grid), len(grid[0])
    img = Image.new("RGBA", (w, h))
    img.putdata([SHADES[grid[y][x]] + (255,)
                 for y in range(h) for x in range(w)])
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path)
    print("wrote", os.path.relpath(path))


def build(name, spec):
    shape = SHAPES[spec["body"]]
    accent = spec["accent"]

    front = blank(40, 40)
    shape(front, 20, 22, 13, accent)
    shape(front, 20, 12, 5, 2)
    for x in (16, 24):
        stroke(front, x, 11, 3)
        stroke(front, x, 12, 3)
    outline(front, 3)
    save(front, os.path.join(ROOT, name + "_front.png"))

    back = blank(32, 32)
    shape(back, 16, 20, 11, accent)
    outline(back, 3)
    save(back, os.path.join(ROOT, name + "_back.png"))

    # two 16x16 frames stacked: the party-menu bob
    icon = blank(16, 32)
    for frame, lift in enumerate((0, 1)):
        shape(icon, 8, 9 + frame * 16 - lift, 5, accent)
    outline(icon, 3)
    save(icon, os.path.join(ROOT, name + "_icon.png"))


if __name__ == "__main__":
    for name, spec in sorted(SPECIES.items()):
        build(name, spec)
