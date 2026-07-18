# Architecture

```text
packaged first boot
user-provided Pokemon Red ROM
        |
        v
RomImporter + RomExtractor (Lua)
        |
        +--> private data/generated/*.lua
        +--> private assets/generated/**/*.png
        +--> private assets/generated/audio/programs.bin
        |
        v
LÖVE2D engine + ChipAudio
```

The importer validates the ROM SHA-1, decodes tables and graphics using
bundled address/name metadata, and writes a private cache. It releases the ROM
after import and does not copy it into the cache. Normal gameplay reads only
the generated files.

`tools/build_data.py` is a separate Python/Pillow developer path that writes
the same core data and graphics into the source tree for verification.

## Runtime layout

| Area | Files | Role |
| --- | --- | --- |
| import | `src/import/RomImporter.lua` | first-boot UI, ROM validation, cache ownership |
| | `src/import/RomExtractor.lua` | ROM tables, text, pictures, PNGs, audio programs |
| core | `src/core/Game.lua` | service owner: data, input, renderer, stack, save |
| | `src/core/Data.lua` | loads `data/generated/*`, resolves TEXT_* pointers |
| | `src/core/ChipAudio.lua` | streams ROM music programs and synthesizes SFX/cries |
| | `src/core/FixedStep.lua` | 60 Hz fixed-step loop |
| | `src/core/Input.lua` | GB button abstraction, per-step edge detection |
| | `src/core/StateStack.lua` | stack of states; top updates, draws bottom-up from the last opaque state |
| | `src/core/SaveData.lua` | Lua-serialized save in the LÖVE save dir |
| render | `src/render/Renderer.lua` | 160x144 canvas, integer nearest scaling |
| | `src/render/TileRenderer.lua` | one SpriteBatch per map (8x8 quads) + border-block ring |
| | `src/render/SpriteRenderer.lua` | 6-frame walker sheets, flipped right facing |
| | `src/render/Font.lua` | glyph rendering via charmap (greedy longest match) |
| | `src/render/TextBox.lua` | dialogue box: typewriter, `\n` line, `\v` scroll, `\f` page |
| | `src/render/Camera.lua`, `Transition.lua` | follow camera, warp fades |
| world | `src/world/Map.lua` | cell queries: walkable/grass/door/warp/sign (bottom-left-tile rule) |
| | `src/world/MapLoader.lua` | generated def -> runtime Map, cached |
| | `src/world/Player.lua`, `NPC.lua` | grid movement, walk animation, wander AI |
| | `src/world/Collision.lua` | tile + entity + bounds checks |
| | `src/world/Warp.lua` | arrive-on-door and walk-off-edge warp rules, LAST_MAP |
| | `src/world/Encounter.lua` | Gen 1 encounter rate + slot buckets |
| | `src/world/OverworldController.lua` | the overworld state: input, interactions, connections, encounters |
| script | `src/script/ScriptRunner.lua` | coroutine executor for command lists |
| | `src/script/Commands.lua` | show_text, flags, battles, warps, movement, objects... |
| | `src/script/Flags.lua` | named event flags in the save |
| pokemon | `src/pokemon/*` | instances, Gen 1 stat calc, growth curves, party |
| battle | `src/battle/BattleState.lua` | battle flow + menus + message queue |
| | `src/battle/Damage.lua` | Gen 1 damage/crit/accuracy formulas |
| | `src/battle/TypeChart.lua`, `TurnOrder.lua`, `Status.lua`, `MoveEffects.lua` | subsystems |
| | `src/battle/Experience.lua`, `Catching.lua`, `TrainerAI.lua` | exp/levels, Gen 1 catch algorithm, AI |
| | `src/battle/rulesets/` | `gen1_faithful` (default) vs `modern_clean` |
| ui | `src/ui/*` | start menu, generic menu, yes/no box, party/bag lists |
| | `tools/save-editor/` | Standalone save editor (`love . --editor`) |

## Map scripts

Map-specific behavior lives in `data/scripts/<map>.lua`, keyed by the
TEXT_* constants from the map's object events. The engine dispatches a
talk interaction to (in order):

1. a hand-ported script in `data/scripts/` (`{ talk = { TEXT_X = {...} } }`),
2. the generic trainer path (object has trainer args from `object_event`),
3. the extracted plain text via the map's text pointer table.

Scripts are arrays of `{ "command", args... }` rows executed by a
coroutine so `show_text`, `ask`, `start_battle`, `warp`, `wait` block
naturally. Every hand-ported script cites its pokered source file.

## Coordinates

- **block**: 32x32 px, the unit of `.blk` layouts (`map.width/height`)
- **cell**: 16x16 px walk grid, the unit of all object/warp coordinates
- **tile**: 8x8 px graphics; a cell is 2x2 tiles, a block 4x4

A cell's behavior (collision, grass, door, warp tile) is decided by its
bottom-left 8x8 tile, matching the original engine's "tile at the
sprite's feet" checks.

## Verification

- `luajit tests/run_tests.lua` - headless behavior suite over real
  generated data (collision, warps, text, stats, damage, growth, type
  chart, encounters, a full scripted battle, save round-trip) using a
  `love` API stub.
- `luajit tests/run_save_editor_tests.lua` (plus the task-specific suites)
  - save editor pure logic and panel click tests.
- `POKEPORT_AUTOPILOT=1 love .` - scripted end-to-end run (walk Pallet
  Town, read the sign, enter Oak's Lab, take a starter, beat the rival,
  exit, cross into Route 1, win a wild battle) that captures screenshots.
- `POKEPORT_DRIVER=tests/drivers/audio_runtime_test.lua love .` - imports
  and queues title music, a sound effect, and a Pokemon cry.
