# What This Port Requires

The packaged desktop app requires one user-supplied input on first boot: a
canonical 1 MiB US Pokemon Red ROM.

The importer verifies SHA-1
`ea9bcae617fdf159b045185467ae58b2e4a48b9a`. Other revisions, Virtual
Console releases, and Pokemon Blue are rejected rather than decoded with
incorrect addresses.

After verification, the app generates its private cache in the LÖVE save
directory. It does not keep a copy of the ROM. Later boots use the cache.
Python and Pillow are not required by the packaged app.

## Bundled Metadata

Assembly removes high-level names and some relationships that the Lua port
needs. `tools/rom_manifest.json` therefore contains:

- the 3,268 ROM symbol addresses actually read by the extractor
- symbolic IDs and ordering for maps, species, moves, items, and trainers
- source-erased dimensions, image names, and map object integration names
- hand-ported field/script integration tables
- text labels and runtime substitution markers, but no dialogue payload
- music, sound-effect, and cry header names and addresses

The manifest contains no ROM bytes, graphics, dialogue, audio samples, or
complete symbol file. Dialogue, map blocks, encounters, stats, names, parties,
palettes, artwork, and audio channel programs are read from the user's ROM.

## Generated Output

First boot writes:

- `data/generated/`: constants, maps, tilesets, text and pointer tables,
  Pokemon, moves, items, trainers, encounters, field data, palettes, and font
  mappings, detailed battle animation programs, plus compact audio metadata
- `assets/generated/`: 495 PNGs covering maps, overworld sprites, fonts,
  Pokemon/trainer pictures, title and intro art, menus, field effects, and
  battle animation tiles
- `assets/generated/audio/programs.bin`: three 16 KiB ROM banks containing
  the music, sound-effect, cry, and waveform programs used by live synthesis

Map behavior remains hand-ported under `data/scripts/`.

## Developer Builder

The optional source-tree builder provides a repeatable audit path:

```sh
python3 tools/build_data.py --rom /path/to/pokemon-red.gb --clean
```

That path requires Python 3.10+ and Pillow. It is not part of a packaged
game's first boot.

## Not Required

- a `pret/pokered` checkout
- the `symbols` branch or a `.sym` file
- Git
- RGBDS
- a separately compiled ROM
- Python or Pillow when running the packaged app
