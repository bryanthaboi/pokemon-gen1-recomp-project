# Sable Cove (Mini Conversion)

The smallest thing that is recognizably a *different game*: its own title
screen, its own starting town, its own three-species dex, its own single
badge — running on the same engine, with the same import.

**Persona: the Total-Conversion Team.** This is the capstone skeleton. It
is deliberately incomplete as a game and deliberately complete as a
demonstration of which seams a conversion owns.

## Legal callout (read this first)

A total conversion on this engine is a **recipe, not a redistribution**.

- The Red import still runs. It supplies the fallback infrastructure this
  conversion sits on: the `OVERWORLD` tileset, the font, the move table,
  the type chart. That data lives on the player's machine, decoded from
  the player's own ROM.
- The conversion overrides on top. Everything under `assets/` here is
  original work, plotted pixel by pixel by
  `tools/make_assets.py` — run it yourself and diff the output.
- It never ships extracted content, and it never launders extracted
  content into "new" species by transforming Red sprites. If your
  conversion wants to *derive* art from the player's cache, that is what
  `assets_transforms` is for — see
  `mods/examples/example_shiny_palette/` for the worked pattern.

## Try it

```sh
python3 tools/modkit.py validate mods/examples/example_mini_conversion --base imported
python3 tools/modkit.py lint mods/examples/example_mini_conversion
luajit mods/examples/example_mini_conversion/tests/example_mini_conversion_test.lua

# regenerate the original art from its shape tables
python3 mods/examples/example_mini_conversion/tools/make_assets.py
```

Enable it (`example_mini_conversion = true` under `mods` in `options.lua`,
or the F10 manager) and start the game. You land on the SABLE COVE title
screen; NEW GAME spawns you in Sable Cove with 1500 money as SABLE.

## What it demonstrates

| Seam | Where |
|---|---|
| `profile = "total_conversion"` | `manifest.json` — implies `affects_link` |
| `content.field:patch("boot", …)` | `main.lua` — spawn, names, money, boot screens |
| `content.constants:patch` / `:override` | `main.lua` — dex size, level cap, badge list |
| `content.pokemon:register` | `main.lua` — three species with full records |
| `content.cries:register` (ChipAsm) | `main.lua` — one authored effect per species |
| `content.icons:register` | `main.lua` — party icons keyed by species id |
| `content.maps:register` | `main.lua` — one map on the imported tileset |
| `content.encounters:register` | `main.lua` — its wild table |
| `content.items:register` | `main.lua` — the badge, which is an item |
| `content.screens:register` | `main.lua` — the title screen the boot config names |
| `events:on("game.ready")` | `main.lua` — checking the boot merge actually took |

## patch vs override on a deep registry

`constants` and `field` are **deep** registries. Two rules differ from the
record registries, and both bite a conversion:

1. `register` and `patch` are the same verb. A partial payload is the
   normal case; only the keys you name move.
2. **Lists append.** That is deliberate — two mods each adding a badge both
   land. But a conversion wants to *replace* the badge list, and appending
   would leave Kanto's eight in front of its one:

```lua
mod.content.constants:patch("badges", { … })    -- 8 + 1 = 9 badges
mod.content.constants:override("badges", { … }) -- 1 badge
```

`override` is the verb that drops a list. The test asserts both behaviors.

`field.boot` is the opposite case: `patch` is right there, because the keys
this conversion does not name (`startFacing`, the `splash` and `newGame`
screen ids) should keep the engine's values.

## Priority

`"priority": 900`. A conversion wants to merge *after* content mods so its
`field.boot` and `constants` win. If another mod still beats it, the
`game.ready` listener says so by name instead of leaving the player on a
map they did not expect.

## What a real conversion adds next

This skeleton stops at the boundary of the mechanism demonstration. A
shipping conversion continues with:

- `map_scripts` for the story (see `mods/examples/example_lost_parcel/`)
- `maps:remove` / `pokemon:remove` tombstones to hide Kanto content
- `content.text` and `text_pointers` for its own dialogue
- `content.music` for its soundtrack (see `mods/examples/example_jukebox/`)
- `link_fields` and an honest `affects_link` so its players do not corrupt
  each other's saves in a trade

## Credits

- All original sprite art: this project (`tools/make_assets.py`).
- pret/pokered: the `OVERWORLD` tileset, font and move table this builds on.
