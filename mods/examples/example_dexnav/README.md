# DexNav Example

A START-menu overlay listing every species in the merged dex with its
seen/owned state, sortable, and publishing a small API other mods can call.

**Persona: the Tool Builder.** Consume the merged view, never `require` a
private module, expose a stable inter-mod surface. This example is the
reference for all three.

## Try it

```sh
python3 tools/modkit.py validate mods/examples/example_dexnav --base imported
luajit mods/examples/example_dexnav/tests/example_dexnav_test.lua
```

Enable it (`example_dexnav = true` under `mods` in `options.lua`, or the
F10 manager), then press START → **DEXNAV**. Its two options live in the
manager's per-mod options pane.

## What it demonstrates

| Seam | Where |
|---|---|
| `content.screens:register` | `main.lua` — a factory the engine instantiates by id |
| `hooks:wrap("ui.start_menu.items")` | `main.lua` — decorate, do not replace |
| `mod.ui.insertBefore` | `main.lua` — anchor on a label, not a row index |
| `mod.options:define` / `:get` | `main.lua` — auto-rendered rows in the manager |
| `mod.exports` | `main.lua` — the inter-mod API |
| `content.pokemon:each` | `main.lua` — the whole world, engine records included |

## Reading, not reaching

Every fact this mod displays comes from two public sources:

- `mod.content.pokemon:each()` — the merged species view. A tool that
  hard-codes 151 breaks the moment another mod registers a species; this
  one just gets longer.
- `game.save.pokedex` — the seen/owned tables, handed in by the engine.

No `require("src.pokemon.…")`, no permission declared, nothing that a later
refactor of an engine module can break.

## Anchoring a menu row

```lua
mod.hooks:wrap("ui.start_menu.items", function(next, game, items)
  local out = next(game, items)
  if type(out) ~= "table" then return out end
  return mod.ui.insertBefore(out, "SAVE", { label = "DEXNAV", onSelect = ... })
end)
```

Two rules, both load-bearing:

1. **Call `next` first, then decorate what comes back.** Build a fresh list
   instead and every other mod's row disappears.
2. **Anchor on a stable label, not an index.** `insertBefore` appends when
   the anchor is missing, so the row is always reachable even in a total
   conversion that renamed `SAVE`.

## Exporting an API

```lua
mod.exports.countSeen = function(game) ... end
```

Another mod reads it as:

```lua
local nav = mod.find("example_dexnav")
if nav then print(nav.exports.countSeen(game)) end
```

`mod.find` returns nil when the other mod is absent, disabled, failed, or
has not run yet — so a dependent degrades instead of crashing. Declare it
in `optional_dependencies` if you can live without it and `dependencies`
if you cannot.

## Empty state

`SHOW UNSEEN` off on a fresh save means an empty list. `ListMenu` draws
`Nothing here.` and B still exits — never a blank frame with no way out.
The title still reports `DEXNAV 0/0`, so the screen explains itself.

## Credits

- pret/pokered — the START-menu layout the row is anchored into.
