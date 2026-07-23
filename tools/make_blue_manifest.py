#!/usr/bin/env python3
"""Derive the Pokemon Blue import manifest from the shipped Red manifest.

Red and Blue are assembled from one pokered source tree; the two ROMs are
byte-identical except for a small set of version-gated regions (wild
encounters, SGB/GBC palettes, the title ribbon, credits text, preset names).
Everything the manifest carries is either identical between the versions or
derivable, so rather than re-parsing pokered from scratch -- which would drag
in unrelated drift between the checked-out source and the *shipped* Red
manifest -- we take the shipped Red manifest verbatim and override only the
fields that genuinely differ for Blue:

  * romSha1        -- Blue's ROM hash.
  * symbols        -- the 23 map-header symbols in bank $1D that shift by one
                      byte in Blue (everything else, audio included, is at the
                      same address).  Re-sourced from pokeblue.sym.
  * field.presetNames -- player/rival name presets swap (Blue's player is
                      BLUE/GARY/JOHN, rival RED/ASH/JACK).
  * field.credits  -- the "BLUE VERSION STAFF" title line (and any staff
                      reordering) parsed with _BLUE defined.

Every other field -- maps, trainers, text, audio addresses, trainer party
overrides, tilesets, etc. -- is inherited unchanged, so Blue behaves exactly
like Red wherever the two games are identical.  The version-specific *content*
that is not in the manifest (wild Pokemon, palette colours, the ribbon
graphic, credits strings) is decoded from the Blue ROM at import time, which
works because the symbol addresses above now point at Blue's data.
"""

from __future__ import annotations

import argparse
import copy
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from extract import field, util  # noqa: E402
from rom_data import CANONICAL_BLUE_SHA1, SymbolTable  # noqa: E402

DEV = "/Users/bryanbassett/Documents/development"
DEFAULT_RED = os.path.join(os.path.dirname(__file__), "rom_manifest.json")
DEFAULT_OUT = os.path.join(os.path.dirname(__file__), "rom_manifest_blue.json")
DEFAULT_POKERED = os.path.join(DEV, "pokered")
DEFAULT_SYMBOLS = os.path.join(DEV, "decprep/pokered-symbols/pokeblue.sym")


def derive(red, pokered, symbols_path):
    """Return the Blue manifest derived from the Red manifest dict."""
    blue = copy.deepcopy(red)
    blue["romSha1"] = CANONICAL_BLUE_SHA1

    # Re-source every symbol the manifest already references from Blue's .sym.
    # The name set is identical between versions; only 23 bank-$1D map headers
    # actually move, but resolving the whole set keeps this robust to future
    # shifts and fails loudly if pokeblue.sym is ever missing a name.
    blue_symbols = SymbolTable(symbols_path)
    resolved, missing = {}, []
    for name in red["symbols"]:
        symbol = blue_symbols.by_name.get(name)
        if symbol is None:
            missing.append(name)
            continue
        resolved[name] = [symbol.bank, symbol.address]
    if missing:
        raise SystemExit(
            "pokeblue.sym is missing symbols the manifest needs: "
            + ", ".join(sorted(missing)[:10])
            + (" ..." if len(missing) > 10 else ""))
    blue["symbols"] = resolved

    # Version-gated field bits.  Calling the parsers directly (rather than
    # through field_metadata) sidesteps field_metadata's Red-only sanity
    # checks, which is exactly what we want for a Blue build.
    saved = util.ASM_DEFINES
    util.ASM_DEFINES = {"_BLUE"}
    try:
        blue["field"]["presetNames"] = field.parse_preset_names(pokered)
        blue["field"]["credits"] = field.parse_credits(pokered)
    finally:
        util.ASM_DEFINES = saved

    # Sanity: Blue's presets must be the swapped set, and the credits banner
    # must say BLUE.  A silent Red-through here would be a hard-to-spot bug.
    presets = blue["field"]["presetNames"]
    if "BLUE" not in presets["player"] or "RED" not in presets["rival"]:
        raise SystemExit("Blue preset-name parse did not swap player/rival")
    banner = blue["field"]["credits"]["screens"][0]["lines"][1]["text"]
    if banner != "BLUE VERSION STAFF":
        raise SystemExit(f"Blue credits banner is {banner!r}, expected BLUE")

    return blue


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--red", default=DEFAULT_RED,
                        help="shipped Red manifest to derive from")
    parser.add_argument("--pokered", default=DEFAULT_POKERED,
                        help="pokered source checkout (for _BLUE field bits)")
    parser.add_argument("--symbols", default=DEFAULT_SYMBOLS,
                        help="pokeblue.sym symbol file")
    parser.add_argument("--out", default=DEFAULT_OUT)
    args = parser.parse_args()

    pokered = os.path.abspath(args.pokered)
    if not os.path.isfile(os.path.join(pokered, "main.asm")):
        raise SystemExit(f"{pokered} is not a pokered checkout")
    with open(args.red, encoding="utf-8") as f:
        red = json.load(f)

    blue = derive(red, pokered, os.path.abspath(args.symbols))
    with open(args.out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(blue, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
