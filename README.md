# Pokemon Gen 1 Recompilation Project

A native LÖVE2D recreation of Pokemon Red. The engine and map behavior are
hand-written Lua; game data and graphics are decoded from a ROM supplied by
the player.

This project does not include a ROM, emulate the Game Boy, transpile assembly,
or download a disassembly. A canonical US Pokemon Red ROM is the only game
content input.

```text
first boot
Pokemon Red ROM -> in-app Lua importer -> private LÖVE save directory
                                       -> generated Lua data and PNGs
                                       -> compact audio channel programs
                                       -> LÖVE2D engine
```

The ROM is verified, used during import, and then released from memory. It is
not copied into the cache. Later launches load the private generated cache and
do not ask for the ROM again.

## Packaged App

Open the desktop app. On first boot, choose your legally obtained `.gb` file
or drop it onto the window. Import takes a few seconds and the game starts
automatically.

Only the canonical 1 MiB US Red ROM is accepted. The importer verifies SHA-1
`ea9bcae617fdf159b045185467ae58b2e4a48b9a` before creating any game data.
The packaged app contains neither a ROM nor pre-extracted game data.

Music, sound effects, and cries are synthesized while the game runs from
compact Game Boy audio channel programs copied out of the verified ROM. No
WAV or OGG library is bundled or generated.

## Source Checkout

The source launchers retain an optional Python workflow for developers. Place
the ROM in the project folder and double-click `Play-Mac.command` or
`Play-Windows.bat`, or run:

```sh
scripts/setup.sh --rom "/path/to/Pokemon Red.gb"
scripts/run.sh
```

Windows PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup.ps1 -Rom C:\path\red.gb
powershell -ExecutionPolicy Bypass -File scripts\run.ps1
```

The setup scripts also accept `ROM_PATH`. With no argument, they use the first
`.gb` file in the project root.

## Developer Data Build

Requirements: Python 3.10+ and Pillow.

```sh
python3 -m pip install pillow
python3 tools/build_data.py --rom "/path/to/Pokemon Red.gb" --clean
```

This command produces the data modules and 495 PNGs in the source tree for
development and parity checks. It is not used by the packaged app.

## Running

Requires LÖVE 11.x:

```sh
love .
```

Controls: arrow keys or WASD move; Z, Enter, or Space is A; X or Backspace is
B; Escape opens START. F1 saves and F2 loads. Controllers are supported.

## Link Play

START > LINK connects two copies directly over UDP. The host chooses HOST A
GAME and shares the shown address; the other player chooses JOIN A GAME.
The default port is 7777 and can be overridden with `POKEPORT_LINK_PORT`.

## Save Editor

Edit party, boxes, items, events, map location, and Pokédex flags without
playing through the game. Close the game first, then from the repo root:

```sh
love . --editor
# or
POKEPORT_EDITOR=1 love .
# open a specific save
love . --editor --save "/path/to/save.lua"
```

By default it loads the game's LÖVE save (`save.lua`):

- macOS: `~/Library/Application Support/LOVE/pokemon-love2d/save.lua (or without the LOVE in a built version)`
- Linux: `~/.local/share/love/pokemon-love2d/save.lua`
- Windows: `%APPDATA%\love\pokemon-love2d\save.lua`

If that file is missing or you want another copy, use **Open...**, drop a
`save.lua` onto the window, or pass `--save`. Each write makes a
`save.lua.bak-YYYYMMDD-HHMMSS` backup first.

See `tools/save-editor/README.md` for headless tests.

## Layout

```text
tools/           ROM decoder, save editor, and developer verification tools
data/generated/  generated Lua game data (gitignored)
data/scripts/    hand-ported map behavior
assets/generated generated graphics and compact audio cache (gitignored)
src/             hand-written LÖVE engine
scripts/         setup, run, and packaging helpers
mobile/          Android and iOS build trees
tests/           headless behavior and parity suites
docs/            architecture, behavior notes, and platform docs
```

See `docs/architecture.md` for runtime details and
`docs/behavior-porting-notes.md` for formula provenance.

## Delete generated files (mac)

```sh
rm -rf data/generated assets/generated \
  "$HOME/Library/Application Support/LOVE/pokemon-love2d/data/generated" \
  "$HOME/Library/Application Support/LOVE/pokemon-love2d/assets/generated"

rm -f "$HOME/Library/Application Support/LOVE/pokemon-love2d/rom-cache.complete"

```

