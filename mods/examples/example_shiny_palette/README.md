# Shiny Palette Example

Recolors the player's overworld sheets to teal and repaints Pallet Town —
and ships no ROM-derived pixels to do it.

**Persona: the Artist.** This is the canonical answer to "how do I ship a
recolor legally": you ship the *transform*, not the image.

## Try it

```sh
python3 tools/modkit.py validate mods/examples/example_shiny_palette --base imported
python3 tools/modkit.py lint mods/examples/example_shiny_palette
luajit mods/examples/example_shiny_palette/tests/example_shiny_palette_test.lua
```

Enable it (`example_shiny_palette = true` under `mods` in `options.lua`, or
the F10 manager) and start the game. On first load the transform runs once
and writes `save/mod-derived/example_shiny_palette/sprites/*.png`. Delete
that directory to force a re-run.

## What it demonstrates

| Seam | Where |
|---|---|
| `assets_transforms` | `manifest.json` + `transforms.lua` — the recipe that derives art |
| `content.palettes:register` | `main.lua` — the v2 named-record palette shape |
| `content.palettes:override` | `main.lua` — the vanilla four-triple shape |
| `content.sprites:patch` | `main.lua` — `trueColor` opt-out, nothing else touched |
| `events:on("assets.transformed")` | `main.lua` — the empty-state warning |

## The legal pattern

`transforms.lua` runs inside a restricted context with exactly two
filesystem roots: read `assets/generated/**` (the player's own imported
cache) and write `save/mod-derived/example_shiny_palette/**`. There is no
`require`, no `love`, no `io`, no `os`. The only way data leaves the
sandbox is the `ctx` table.

Because the derived file keeps the *same relative name* as the cache file
it came from, the asset resolver finds it automatically:

```
assets/generated/sprites/red.png          <- the player's import
save/mod-derived/example_shiny_palette/sprites/red.png   <- this mod's recolor
```

Every consumer of the first path transparently gets the second. No
`sprites:override`, no path string in `main.lua` — and `modkit lint` can
prove the repo carries no cache-derived bytes, because it carries no bytes
at all.

The one thing that *does* need a registry entry is the 4-shade contract.
The renderer normally re-shades an overworld sheet into the current
palette's four grays, which would throw the teal away. `trueColor = true`
opts out:

```lua
mod.content.sprites:patch("SPRITE_RED", { trueColor = true })
```

`patch`, not `override`: `image`, `frames` and `walker` stay whatever the
merged view already holds, so the derived sheet keeps supplying the pixels.

## Empty state

No ROM imported yet? `ctx.exists(rel)` is false, the transform writes
nothing, the mod still loads, and `main.lua` logs a remediation line naming
the directory to delete once you have imported. It never errors.

## Original assets

`assets/accent_sparkle.png` is a 16x16 four-shade sparkle drawn for this
example. It is the only image in the directory and it is original work.

## Credits

- pret/pokered — the overworld sheet layout the transform recolors.
