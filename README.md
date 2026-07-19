# Pokemon Gen 1 Recompilation Project

A native LÖVE2D recreation of Pokemon Red. The engine and map behavior are
hand-written Lua; game data and graphics are decoded from a ROM supplied by
the player.

SUPPORT AND ANNOUNCEMENTS: [Discord](https://bois.icu)

This project does not include a ROM, emulate the Game Boy, transpile assembly,
or download a disassembly. A canonical US Pokemon Red ROM is the only game
content input.

The ROM is verified, used during import, and then released from memory. It is
not copied into the cache. Later launches load the private generated cache and
do not ask for the ROM again.

## Quick Start

Open the desktop app. On first boot, choose your legally obtained `.gb` file
or drop it onto the window. Import takes a few seconds and the game starts
automatically.

Only the canonical 1 MiB US Red ROM is accepted. The importer verifies SHA-1
`ea9bcae617fdf159b045185467ae58b2e4a48b9a` before creating any game data.
The packaged app contains neither a ROM nor pre-extracted game data. Music,
sound effects, and cries are synthesized while the game runs from compact
audio channel programs copied out of the verified ROM.

## Controls

arrow keys or WASD move; Z, Enter, or Space is A; X or Backspace is
B; Escape opens START. F1 saves and F2 loads. Controllers are supported.

## Running From Source

Requires LÖVE 11.x. Place the ROM in the project folder and double-click
`Play-Mac.command` or `Play-Windows.bat`, or run:

```sh
scripts/setup.sh --rom "/path/to/Pokemon Red.gb"
scripts/run.sh
```

then `love .` for later launches. Windows PowerShell scripts, the optional
developer data build, test suites, and cache management are covered in
[Developer Setup](https://github.com/bryanthaboi/pokemon-gen1-recomp-project/wiki/Guide-Developer-Setup).

## Modding

The game ships a native mod platform: content registries, events and hooks,
per-mod saves and options, and an in-game manager. The full modding book —
getting started, a twelve-rung tutorial ladder, a cookbook, and the generated
reference — lives on the
[project wiki](https://github.com/bryanthaboi/pokemon-gen1-recomp-project/wiki).

Shipped example mods, one per kind of author, live in [`mods/`](mods/).

## More

- [Link play](https://github.com/bryanthaboi/pokemon-gen1-recomp-project/wiki/Guide-Link-Play)
  — START > LINK connects two copies directly over UDP.
- [Save editor](https://github.com/bryanthaboi/pokemon-gen1-recomp-project/wiki/Guide-Save-Editor)
  — edit party, boxes, items, events, and Pokédex flags outside the game.
- `docs/architecture.md` — runtime details;
  `docs/behavior-porting-notes.md` — formula provenance.

## Special Thanks

This project would not be possible without [pret](https://github.com/pret) >
the pret band of decompiling maniacs > and their
[pokered](https://github.com/pret/pokered) disassembly.
