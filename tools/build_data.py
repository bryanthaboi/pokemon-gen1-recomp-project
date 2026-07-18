#!/usr/bin/env python3
"""Build the port's generated data and graphics from a Pokemon Red ROM.

The public build requires only a canonical US Pokemon Red ROM and Pillow.
Assembly-erased names and the small address subset used by the extractor
are bundled in tools/rom_manifest.json.
"""

from build_rom_data import main


if __name__ == "__main__":
    raise SystemExit(main())
