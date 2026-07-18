#!/usr/bin/env python3
"""Create the inverted battle sprites used by the example native mod."""

from pathlib import Path
import sys

from PIL import Image, ImageOps


def invert(source: Path, destination: Path) -> None:
    image = Image.open(source).convert("RGBA")
    r, g, b, a = image.split()
    inverted = ImageOps.invert(Image.merge("RGB", (r, g, b)))
    inverted.putalpha(a)
    destination.parent.mkdir(parents=True, exist_ok=True)
    inverted.save(destination)
    print(f"generated {destination} ({image.width}x{image.height})")


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: generate_example_mod_sprite.py <source-dir> <output-dir>")
        return 2
    source_dir, output_dir = map(Path, sys.argv[1:])
    invert(source_dir / "battle/front/mew.png",
           output_dir / "assets/mew_front_inverted.png")
    invert(source_dir / "battle/back/mewb.png",
           output_dir / "assets/mew_back_inverted.png")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
