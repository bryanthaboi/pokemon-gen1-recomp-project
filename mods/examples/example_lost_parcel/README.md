# The Lost Parcel

A courier in Viridian City dropped a parcel somewhere in Pewter City.
Fetch it and he pays you a NUGGET.

**Persona: the Quest Author.** Two towns, two vanilla NPCs, a branching
conversation, a key item, a reward and some ambience — and not one line of
map data or engine source changed.

## Try it

```sh
python3 tools/modkit.py validate mods/examples/example_lost_parcel --base imported
luajit mods/examples/example_lost_parcel/tests/example_lost_parcel_test.lua
```

Enable it (`example_lost_parcel = true` under `mods` in `options.lua`, or
the F10 manager), then:

```
     VIRIDIAN CITY                     PEWTER CITY
  ┌───────────────────┐             ┌───────────────────┐
  │   GAMBLER  ◀──────┼── accept ───┼──▶ SUPER NERD     │
  │   (quest giver)   │             │    (has the       │
  │       ▲           │             │     parcel)       │
  └───────┼───────────┘             └─────────┬─────────┘
          └──────────── return ───────────────┘
```

Talk to the gambler in Viridian (the one south of the Poké Mart), say
`SURE`, walk to Pewter, talk to the super nerd by the museum, walk back.

## What it demonstrates

| Seam | Where |
|---|---|
| `content.map_scripts:register` (compose) | `main.lua` — two maps, no map edits |
| talk override on a real `TEXT_` constant | `main.lua` — `TEXT_VIRIDIANCITY_GAMBLER1`, `TEXT_PEWTERCITY_SUPER_NERD1` |
| `choice` + `label` + `jump_if_true/false` | `main.lua` — a five-branch conversation |
| `MOD_` flag convention | `main.lua` — `MOD_EXAMPLE_LOST_PARCEL_*` |
| `set_field "mod:key"` | `main.lua` — quest scratch state in `save.modData[mod.id]` |
| `mod.save:get/set` | `main.lua` — the same value through the loader-side namespace |
| `content.commands:register` (table form) | `main.lua` — a `foreground` verb of the mod's own |
| `MapScripts.baseTalk` (replay the overridden handler) | `main.lua` — `example_lost_parcel:base_nerd_chat` |
| `content.tokens:register` | `main.lua` — `{EXAMPLE_PARCEL_REWARD}` |
| `content.items:register` | `main.lua` — the parcel key item |
| a parallel ambient script | `main.lua` — `scripts.example_nerd_pace` + `onEnter` |
| `events:on` / `events:emit` | `main.lua` — announcing completion under `mod.<id>.*` |

## How the compose merge works

`map_scripts` is a **compose** registry, not a record registry. Registering
does not replace the engine's contribution for a map; it prepends to an
ordered chain, and each key composes by its own rule
(`09-scripting-and-quests.md` §4.4):

| key | rule |
|---|---|
| `talk`, `scripts` | single winner per name; `false` suppresses and falls through |
| `onEnter`, `onVictory`, `onBoulderMoved` | all contributions run, each `pcall`-guarded |
| `onStep`, `onInteract` | first truthy return consumes the step |

So this mod's `onEnter` for Pewter City runs *alongside* the engine's, not
instead of it. Its `talk` entry for `TEXT_PEWTERCITY_SUPER_NERD1` does win
outright — the engine's handler for that constant stops being dispatched
the moment this mod loads. Giving it back is the last branch's whole job:

```lua
{ "label", "vanilla" },
{ "example_lost_parcel:base_nerd_chat" },
```

```lua
local base = MapScripts.baseTalk("PEWTER_CITY", "TEXT_PEWTERCITY_SUPER_NERD1")
base(ctx.game, ctx.overworld, ctx.npc, function() ctx.runner:resume() end)
ctx.runner:yield()
```

`MapScripts.baseTalk` reaches the engine handler still sitting behind the
override (`09-scripting-and-quests.md` §6) — the supported replacement for
re-wrapping it. A `{ "show_text", "TEXT_PEWTERCITY_SUPER_NERD1" }` row
*looks* like it does the same thing and does not: this NPC's base handler
is a Lua function that asks YES/NO and answers with one of two follow-ups,
while `show_text` resolves the constant to its opening line and stops. So
before the quest starts and after the parcel is taken, the player gets the
whole conversation they always got, choice included. The test drives both
answers, in both states, and asserts every line.

This is also why the manifest declares `engine_internals`: replaying a base
handler means requiring `src.script.MapScripts`.

## Flags, fields and mod state

Three storage routes, three jobs:

- **`MOD_`-prefixed flags** — the quest's public state machine. In the
  normal flag namespace so `check_flag` works, prefixed so it can never
  collide with a pokered event constant.
- **`set_field "mod:asked_count"`** — script-visible scratch state, routed
  into `save.modData[mod.id]` by the owning contribution's attribution.
  Two copies of a quest cannot collide on one key.
- **`mod.save:get/set`** — the same namespace from Lua, for code that is
  not a script row.

## Verb metadata

The custom verb is registered in the table form:

```lua
mod.content.commands:register("example_lost_parcel:count_ask", {
  foreground = true,
  fn = function(ctx) ... end,
})
```

`foreground = true` marks it illegal inside a parallel script, so the
ambient runner can never touch quest state. Namespacing the verb with the
mod id keeps it from colliding with another mod's — `register` on a name
the engine already owns is an error, and replacing one requires `override`.

## Validation

Every row is checked against the merged command set once all entry chunks
have run. Typo a verb or jump to a label that does not exist and this mod
fails at *load* with the row number, is rolled back whole, and says so in
the manager — it never half-loads into a broken conversation.

## Credits

- pret/pokered — the `TEXT_` constants and base conversations this
  composes with.
