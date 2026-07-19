# Jukebox Example

Adds one song authored note-by-note in Lua, swaps it in as the Pallet Town
theme, replaces Mew's cry, and ships a jukebox screen that lists every song
in the merged registry.

**Persona: the Musician.** Nothing here is a `.ogg`. The song is a
Game Boy channel program assembled at load time by `ChipAsm`.

## Try it

```sh
python3 tools/modkit.py validate mods/examples/example_jukebox --base imported
luajit mods/examples/example_jukebox/tests/example_jukebox_test.lua

# render the song to a wav to hear it without launching the game
python3 tools/modkit.py bounce Music_ExamplePalletRain --seconds 20 --out bounce
```

Enable it (`example_jukebox = true` under `mods` in `options.lua`, or the
F10 manager), then open **OPTIONS → JUKEBOX**.

## What it demonstrates

| Seam | Where |
|---|---|
| `content.music:register` (ChipAsm DSL) | `song.lua` + `main.lua` |
| `content.cries:override` (chip program) | `main.lua` |
| `hooks:wrap("music.select")` | `main.lua` — one choke point covers map, battle and jingle music |
| `content.screens:register` | `main.lua` — a screen factory the engine instantiates by id |
| `hooks:wrap("ui.options.rows")` | `main.lua` — how the player reaches the screen |
| `content.music:each` | `main.lua` — the jukebox list is the merged view, not a hard-coded array |
| `mod:read` | `main.lua` — loading a sibling file through the loader's filesystem |

## Authoring a song

`song.lua` returns what `ChipAsm.song{...}` builds: a self-contained
program blob plus its channel layout. Events are Lua tables, one per
command:

```lua
{ duty = 2 },
{ notetype = { speed = 12, volume = 11, fade = 2 } },
{ octave = 4 },
{ label = "lead" },
{ note = "E", len = 6 }, { note = "D", len = 2 },
{ loop = { count = 0, to = "lead" } },
```

The assembler is the validator. An unknown note name or an out-of-range
length raises *there*, naming the channel and event index, and `main.lua`
turns that into one mod-attributed load error. The music system never
latches on a bad program, because a bad program never reaches it.

Two shapes share the `music` registry and are dispatched per definition,
not by a global flag: `{ chip = ... }` for an authored program and
`{ file = "..." }` for an audio file. This example uses the first; a file
track is one line:

```lua
mod.content.music:register("Music_MyTheme", { file = mod.path .. "/theme.ogg" })
```

Note the cry uses `ChipAsm.sfx{...}.chip` — the assembler returns
`{ chip = program }`, and a cry record wants the program under its own
`chip` key.

## Deferring is the parity guarantee

```lua
mod.hooks:wrap("music.select", function(next, chosen, ctx)
  if ctx and ctx.reason == "map" and ctx.mapId == "PALLET_TOWN" then
    return next(SONG_ID, ctx)
  end
  return next(chosen, ctx)
end)
```

Every path that is not Pallet Town calls `next(chosen, ctx)` with the
argument it was given, so playback everywhere else is exactly what it was
before the mod loaded.

## Empty state

The jukebox is a `ListMenu`, which draws `Nothing here.` when its item list
is empty rather than an empty frame. That cannot happen with the engine's
45 songs present, but it is the behavior a mod screen owes the player.

## Permissions

This mod declares `engine_internals`, because playing a song from a screen
currently needs `require("src.core.Music")` — the mod surface has no audio
playback facade yet. Declaring it is the honest path: `modkit validate`
accepts a declared require and flags an undeclared one.

## Credits

- Pallet Rain arrangement: this project.
- pret/pokered: the channel command set `ChipAsm` assembles to.
