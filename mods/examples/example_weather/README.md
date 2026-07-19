# Weather Battles Example

Adds rain: for the first five turns of every battle, WATER moves deal 1.5x
damage and FIRE moves deal 0.5x. Only under the `WEATHER` ruleset — pick
`gen1_faithful` and the mod is installed and inert.

**Persona: the Mechanic Designer.** A new battle mechanic, no engine fork.
The status and ruleset registries plus one hook carry the whole thing.

## Try it

```sh
python3 tools/modkit.py validate mods/examples/example_weather --base imported
luajit mods/examples/example_weather/tests/example_weather_test.lua
```

Enable it (`example_weather = true` under `mods` in `options.lua`, or the
F10 manager), then **OPTIONS → RULESET → WEATHER**.

## What it demonstrates

| Seam | Where |
|---|---|
| `content.statuses:register` | `main.lua` — declaring a field effect |
| `content.rulesets:register` | `main.lua` — a ruleset the OPTIONS menu lists automatically |
| `content.rulesets:get` | `main.lua` — deriving from vanilla without requiring a private module |
| `hooks:wrap("battle.damage")` | `main.lua` — the one behavior change |
| `events:on("battle.started" / "battle.turn_started" / "battle.ended")` | `main.lua` — the rain counter |
| `mod.save:get/set` | `main.lua` — per-mod state, not a global |

## Parity, at the mod level

The engine's promise is that a mod-free game is unchanged. This example
makes the same promise one level up: a *player* who installs it but does
not select the ruleset gets vanilla battles.

```lua
if not (ctx.ruleset and ctx.ruleset.exampleWeather and raining()) then
  return next(ctx)
end
```

`next(ctx)` with the arguments it was handed *is* the vanilla call. No
allocation, no rounding, no reordering — the same number the engine would
have produced. Everything above that line is a gate, and every gate that
fails defers.

## Preserving multiple returns

`Damage.compute` returns two values: the damage number and an info table
carrying the crit flag and the type multiplier. A wrapper that returns only
the first silently throws the second away, and the battle log stops saying
"A critical hit!".

```lua
local damage, info = next(ctx)
if type(damage) ~= "number" then return damage, info end
return math.max(1, math.floor(damage * scale)), info
```

Hook chains preserve every return value, so passing `info` back through is
all it takes.

## Deriving a ruleset from vanilla

A ruleset record is the *whole* rule table — `oneIn256Miss`,
`critUsesBaseSpeed`, `randMin`, `randMax` and the rest. Registering one
that only sets `name` would silently drop every Gen 1 quirk. So this mod
reads the vanilla record out of the merged registry and copies it:

```lua
local base = mod.content.rulesets:get("gen1_faithful")
local weather = {}
for key, value in pairs(base) do weather[key] = value end
weather.name = "WEATHER"
weather.exampleWeather = true
```

`:get` on a registry is the public path to engine content. It needs no
permission, and it composes: if another mod patched `gen1_faithful` first,
this ruleset inherits that patch too.

`exampleWeather` is not in the ruleset schema. Unknown fields on a record
registry are preserved rather than rejected — that is what makes rulesets
extensible, and it is how the damage hook recognizes its own ruleset
without a second lookup.

## Missing dependency, handled

If another mod removed `gen1_faithful`, `:get` returns nil. This example
logs a remediation line and returns — the rest of the game keeps working
and the manager shows one attributed message. No `assert`, no crash.

## Credits

- pret/pokered — the damage formula the hook scales.
