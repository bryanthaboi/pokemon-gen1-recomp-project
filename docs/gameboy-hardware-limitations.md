# Game Boy Hardware Limitations Carried Into This Port

This is a 1:1 parity port of Pokémon Red onto a modern engine (LÖVE2D), so a
lot of the original game's design isn't "design" at all,  it's a direct
consequence of what the actual Game Boy hardware could physically do. None
of these constraints apply to a Lua table or a 2026 GPU. They're kept here
purely for faithfulness to the original, and documented below so it's clear
which limits are load-bearing history rather than intentional choices for
this port.

## Kept faithfully (gameplay-visible limits reproduced on purpose)

| # | Mechanic | Value | Why the Game Boy had this limit | Where it lives here |
|---|---|---|---|---|
| 1 | Bag capacity | 20 item slots | `wNumBagItems` save block was a fixed 20-entry id/quantity array in SRAM | `src/inventory/Bag.lua:8` (`Bag.CAPACITY = 20`) |
| 2 | Party size | 6 Pokémon | `wPartyMon1..6` were 6 fixed save-RAM slots | `src/pokemon/Party.lua:5` (`Party.MAX = 6`) |
| 3 | PC storage | 12 boxes × 20 Pokémon | `wBoxDataStart` / Bill's PC allocated a fixed 12×20 SRAM block | `src/pokemon/Boxes.lua:7-8` |
| 4 | Moves per Pokémon | 4 | Fixed 4-move-slot field in the party/box Pokémon struct | `src/pokemon/Pokemon.lua:20`, enforced again in `src/battle/BattleState.lua:1941` |
| 5 | Screen resolution / tile grid | 160×144 px, 8×8 tiles, 20×18 visible tiles | The Game Boy PPU's actual pixel and tile-map dimensions | `src/render/Renderer.lua:13-14`, `src/render/TileRenderer.lua:64`, `src/render/BattleTransition.lua:25` |
| 6 | Name length | Nickname 10 chars, trainer/rival name 7 chars | Fixed-width `wPlayerName` and nickname byte buffers in SRAM | `src/ui/OakSpeech.lua:91,108`, `src/battle/BattleState.lua:2240`, `src/ui/NamingScreen.lua:50` |
| 7 | Text box size / word wrap | 20×6 tile dialogue window, 18-column wrap | Text rendered directly into the tile-map grid | `src/render/TextBox.lua:14,17` |
| 8 | Text print speed | 1/3/5-frame character delay | Text was drawn character-by-character into VRAM on a fixed 60Hz frame budget | `src/render/TextBox.lua:133-136`, `src/core/SaveData.lua` (`textSpeed = 3` default) |
| 9 | Audio channel behavior | 4 channels (2 pulse, 1 wave, 1 noise); fanfares "steal" the music's tone channels | The GB APU only has 4 physical sound channels | `src/core/Sound.lua:14-21`, `docs/behavior-porting-notes.md:225-235` |
| 10 | Stat/damage byte-overflow bugs | Atk/Def quartered when either exceeds 255; Focus Energy crit bug; stat-exp capped at 255 pre-scale | Original math ran on 8-bit registers and overflowed/wrapped exactly this way,  these are *bugs*, kept for authenticity | `src/battle/Damage.lua:19-25,143-148`, `src/pokemon/Stats.lua:25-27` (toggleable via `gen1_faithful` ruleset) |
| 11 | Fixed 60Hz update step | `STEP = 1/60` | The Game Boy's actual refresh rate | `src/core/FixedStep.lua` |

## Explicitly NOT carried over (the hardware cause disappeared, so the effect was dropped)

| # | Mechanic | Original GB constraint | Status here |
|---|---|---|---|
| 1 | OAM sprite limits | Max 40 sprites on screen, max 10 per scanline (causes the classic flicker) | Not modeled,  LÖVE draws every sprite unconditionally, no scanline budget or cycling exists |
| 2 | Money cap of 999999 | Money was packed as 3 BCD bytes in SRAM, capping at 999,999 | Not enforced,  money is only floored at 0, can grow unbounded |
| 3 | DMA transfer / VBlank timing | Sprite/tile updates had to be batched into the VBlank window via DMA | Not applicable,  no equivalent constraint in a modern renderer |
| 4 | SRAM save layout | Save data was a precise byte-for-byte struct fit to a small battery-backed SRAM chip | Save file is a plain serialized Lua table (`src/core/SaveData.lua`), not an SRAM layout |
| 5 | Weak/deterministic RNG | The GB's RNG was driven by timer/divider registers, not a real PRNG | Replaced with `love.math.random` / `math.random`,  only the *value ranges/thresholds* the original produced are kept. Exception: link battles use a deterministic Park-Miller LCG (`src/link/LinkBattle.lua:22-33`) so both sides can reproduce identical rolls,  that's a design choice, not a GB replication |
| 6 | VRAM tile budget | 256 tiles per bank, 2 VRAM banks total | Not applicable,  generated tile sheets aren't memory-budget constrained |
| 7 | Old man glitch (MissingNo. / 'M, +128 item duplication, Hall of Fame corruption) | The catch tutorial stashes the 11-byte player name over `wGrassRate`/`wGrassMons` (core.asm:2024-2037) and restores it from there after the throw (item_effects.asm:159-164), leaving name bytes in the grass table; `LoadWildData` skips rewriting `wGrassMons` on maps with grass rate 0 (wild_mons.asm:13-16), so Cinnabar/Route 21 shore tiles read name characters as level/species pairs,  out-of-range species IDs render garbage base-stat/sprite memory as MissingNo./'M, the dex-#0 seen-flag write lands 255 bits past `wPokedexSeen` onto bag slot 6's quantity byte (+128 items), and the oversized glitch sprite overflows the decompression buffer into Hall of Fame SRAM | Not modeled,  encounters are a pure per-map data lookup (`src/world/Encounter.lua` + `data/generated/encounters.lua`) with no stale copied buffer, the species table is closed (no out-of-range reads to render), and dex flags / bag / HoF data are separate Lua tables with no address adjacency; the tutorial's OLD MAN name swap is kept only in its visible text (`BattleState:oldManThrow`) |

## Notes

- PC Box **overflow handling** was deliberately changed even though the
  20×12 box *shape* was kept faithful: instead of Gen 1's "full box discards
  or blocks the deposit," this port spills into the next box with room.
- Several battle-related overflow "bugs" (byte overflow, Focus Energy) are
  gated behind a `gen1_faithful` vs `modern_clean` ruleset toggle in
  `src/battle/rulesets/`, so the faithful-but-buggy behavior can be turned
  off without losing the option to replay it exactly as it shipped in 1996.
- Hardware-terminology comments referencing OAM, VRAM, DMA, BCD, SGB
  colorization, etc. are scattered across ~14 files for context even where
  the constraint itself isn't enforced (e.g. `src/battle/AnimPlayer.lua:310-312`
  documents OAM sprite-hiding coordinate quirks used for animation
  correctness, without implementing the underlying 40-sprite cap).
