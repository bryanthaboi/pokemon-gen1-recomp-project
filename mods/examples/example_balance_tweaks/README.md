# Balance Tweaks Example

Raises the final-stage Kanto starters to 100 base speed, halves every TM
price, and re-slots the Route 1 grass table — all without copying a single
record whole.

**Persona: the Tweaker.** A player who wants one number changed and copies
an example to get there. This is the shortest complete mod in the gallery
and the one to start from.

## Try it

```sh
python3 tools/modkit.py validate mods/examples/example_balance_tweaks --base imported
luajit mods/examples/example_balance_tweaks/tests/example_balance_tweaks_test.lua
```

Then enable it: add `example_balance_tweaks = true` under `mods` in your
`options.lua`, or toggle it in the F10 mod manager.

## What it demonstrates

| Seam | Where |
|---|---|
| `content.pokemon:patch` | `main.lua` — deep-merges one leaf, leaves the rest alone |
| `content.items:each` | `main.lua` — walks the merged view to find TMs instead of listing them |
| `content.encounters:patch` | `main.lua` — a list leaf replaces wholesale even inside a patch |
| `content.<r>:get` | `main.lua` — the guard that turns a missing id into a log line, not a crash |

`patch` is the point. The legacy `mods/example_mew_starter` has to copy
every field of Mew to change two sprite paths, because api 1 only had
`override`. With `patch` you name the leaf:

```lua
mod.content.pokemon:patch("VENUSAUR", { baseStats = { speed = 100 } })
```

Everything not named — `learnset`, `types`, `evolutions`, `spriteFront` —
keeps its base value, and a second mod patching `baseStats.attack` on the
same species composes with this one instead of clobbering it.

## Exact changes

- `VENUSAUR` base speed 80 → 100
- `BLASTOISE` base speed 78 → 100
- `CHARIZARD` base speed 100 → 100 (already there; kept for symmetry)
- every item whose `machine.kind == "TM"` has its `price` halved
  (`TM_TOXIC` 4000 → 2000, and 49 others; HMs carry `machine.kind == "HM"`
  and are left alone)
- `ROUTE_1` grass `rate` 25 → 20, slot table re-weighted to include
  `SPEAROW`

Field meanings are in the generated registry reference (`modkit docs`),
section `pokemon`, `items` and `encounters`.

## Credits

Base stat and mart price tables come from the player's own imported ROM;
this mod ships numbers, not data.
