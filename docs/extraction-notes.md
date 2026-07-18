# ROM Extraction Notes

There are two ROM-only extraction paths:

- The packaged app uses `src/import/RomImporter.lua` and
  `src/import/RomExtractor.lua` on first boot.
- Developers can run `tools/build_data.py --rom <path> [--clean]` to generate
  data in the source tree for audit and parity work.

Both paths read only the supplied ROM and the checked-in
`tools/rom_manifest.json`. Neither invokes RGBDS, Git, or a disassembly.

## Validation

Only the canonical US Pokemon Red ROM is supported. SHA-1 is checked before
any cached output is removed or written.

## Decoded Data

| Area | ROM data |
| --- | --- |
| world | map headers, block maps, connections, warps, signs, objects |
| tiles | tileset graphics, blocksets, collision, door and warp tile lists |
| text | 2,584 text command streams and RAM/number substitutions |
| Pokemon | names, stats, evolutions, learnsets, Dex data, compressed pictures |
| battle | moves, detailed animations, OAM frames/tiles, effects, type chart, palettes, trainer parties/AI/pictures |
| inventory | item names, prices, key-item flags, TM/HM data |
| encounters | grass and water wild tables |
| UI | fonts, icons, title/intro, trainer card, town map, slots, field effects |
| audio | music, SFX and cry headers, channel programs, wave instruments |

The Python and Lua picture decompressors implement the Gen 1 `pic` format.
Graphics are converted to RGBA PNGs. OAM artwork uses transparent color 0;
battle pictures use edge-connected white matting so white interior details
remain visible.

The in-app importer stores three audio ROM banks as a 48 KiB
`programs.bin`. `src/core/ChipAudio.lua` interprets the channel bytecode and
synthesizes music as a queueable stream; SFX and cries are synthesized on
demand. This avoids shipping or generating a large WAV/OGG tree.

## Metadata Boundary

Names, dimensions, enum ordering, Lua script hooks, and hand-ported field
behavior do not survive compilation in a form the Lua runtime can infer.
Those relationships are bundled in `rom_manifest.json`. The manifest stores
no dialogue strings, images, audio samples, or ROM bytes.

`tools/make_rom_manifest.py` and `tools/verify_rom_data.py` are developer audit
tools. They are not used by the packaged game.
