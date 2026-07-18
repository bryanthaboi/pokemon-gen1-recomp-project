# Building a Blue Version of the port

pokered builds Red and Blue from one source tree: the Makefile
assembles everything twice with `rgbasm -D _RED` or `-D _BLUE`, and
every in-game difference sits in an `IF DEF(_RED)` / `IF DEF(_BLUE)`
block. Our extraction pipeline resolves those conditionals the same
way (`tools/extract/util.py` `ASM_DEFINES`), so most of a Blue build
falls out of re-running the extractors. Only three things are
hand-ported on the Lua side and need swapping by hand.

## What differs between Red and Blue

| Where (pokered) | What |
| --- | --- |
| `data/wild/maps/*.asm` (34 files) | Version-exclusive encounters (Red: Ekans, Oddish, Growlithe, Mankey, Scyther, Electabuzz,  Blue: Sandshrew, Bellsprout, Vulpix, Meowth, Pinsir, Magmar) |
| `data/pokemon/title_mons.asm` | The 16 title-screen Pokémon |
| `engine/movie/title.asm` + `gfx/version.asm` | The "Red Version" / "Blue Version" ribbon |
| `constants/player_constants.asm` | Preset names (Red: RED/ASH/JACK + BLUE/GARY/JOHN) |
| `data/sgb/sgb_palettes.asm`, `sgb_border.asm` | Super Game Boy palettes and border |
| `data/events/prizes.asm`, `prize_mon_levels.asm` | Game Corner prize mons, costs and levels |
| `engine/movie/intro.asm`, `data/credits/credits_text.asm`, `engine/slots/slot_machine.asm`, `engine/battle/animations.asm`, `audio/sfx/save_3.asm` | Small gated tweaks (credits say "BLUE VERSION STAFF", etc.) |

## Step 1,  flip the extraction define

`tools/extract/util.py`:

```python
ASM_DEFINES = {"_RED"}   # -> {"_BLUE"}
```

Then regenerate everything (same as scripts/setup.sh does):

```sh
cd tools
../.venv/bin/python3 build_data.py \
    --pokered /Users/bryanbassett/Documents/development/pokered \
    --out ../data/generated --assets ../assets/generated
```

This alone switches the wild encounters, preset names, SGB palettes
and credits text. **Caveat:** `parse_preset_names` sanity-checks in
`tools/extract/field.py:1193` expect "RED" in the player presets, 
relax that check for a Blue build (Blue's presets are BLUE/GARY/JOHN
for the player and RED/ASH/JACK for the rival).

`tools/extract/palettes.py` uses its own raw reader with hardcoded
`IF DEF(_BLUE)` skipping (around line 44),  invert that too, or port
it to `read_asm` so `ASM_DEFINES` covers it.

## Step 2,  title screen (hand-ported)

`src/ui/TitleState.lua`:

1. **Ribbon art.** The extractor writes
   `assets/generated/title/red_version.png`; add `blue_version.png`
   to `gfx.extract_title` in `tools/extract/gfx.py` (source:
   `gfx/title/blue_version.png`, 64×8). In `TitleState:draw()`, the
   Red strip needs two quads (tiles 0–1 "Red", skip, tiles 5–9
   "Version",  `title.asm` `VersionOnTitleScreenText`). Blue's strip
   prints its tiles contiguously (`db $61..$68`), so draw the whole
   64×8 image at px (56, 64) and verify with the title driver
   screenshot.

2. **Title mons.** Replace `CYCLE_SPECIES` with Blue's list from
   `data/pokemon/title_mons.asm`:

   ```lua
   local CYCLE_SPECIES = {
     "SQUIRTLE", "CHARMANDER", "BULBASAUR", "MANKEY", "HITMONLEE",
     "VULPIX", "CHANSEY", "AERODACTYL", "JOLTEON", "SNORLAX",
     "GLOOM", "POLIWAG", "DODUO", "PORYGON", "GENGAR", "RAICHU",
   }
   ```

## Step 3,  Game Corner prizes (hand-ported)

`data/scripts/story3.lua` (~line 209) carries the Red prize tables.
Blue's values (`prizes.asm` + `prize_mon_levels.asm`):

| Prize | Cost | Level |
| --- | --- | --- |
| ABRA | 120 | 6 |
| CLEFAIRY | 750 | 12 |
| NIDORINO | 1200 | 17 |
| PINSIR | 2500 | 20 |
| DRATINI | 4600 | 24 |
| PORYGON | 6500 | 18 |

(TM prizes are identical in both versions.)

## Step 4,  verify

```sh
luajit tests/run_tests.lua
```

Plus two spot checks:

```sh
# every grass table must have exactly 10 slots (a conditional-parsing
# regression shows up as 19–20 slots)
luajit -e 'local e=dofile("data/generated/encounters.lua")
for m,d in pairs(e) do if type(d)=="table" and d.grass and #d.grass.slots>0
  and #d.grass.slots~=10 then print("BAD",m,#d.grass.slots) end end'

# a Blue exclusive should now appear (and Growlithe should not)
grep -c VULPIX data/generated/encounters.lua
grep -c GROWLITHE data/generated/encounters.lua
```

Title screenshot: run the driver in
`tests/drivers/` style (`SHOT_DIR=... POKEPORT_DRIVER=... love .`) and
eyeball the ribbon, title mon, and copyright row.

## What you get for free / what to skip

- Free after re-extraction: encounters (incl. Super Rod groups), SGB
  palettes, preset names, credits text, the gated sfx/animation
  tweaks.
- Trades, gift Pokémon, story scripts, gym data: identical in Western
  Red/Blue,  nothing to touch.
- Save files: a Red save loads fine, but dex AREA nests and new
  encounters will be Blue's. Trainer parties are identical.

## Making it a runtime toggle instead

If you want one build with both versions, extraction would need to
emit both branches keyed by version (e.g. `slots` / `slotsBlue`) and
the three hand-ported spots would read a `save.version` or
`conf.lua` flag. That is a bigger change than the rebuild above, 
the flip-and-regenerate route needs no engine changes at all.
