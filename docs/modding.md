# Native modding

The game has a built-in Lua mod runtime. Mods are installed under the LÖVE
save directory in `mods/<id>/` and are loaded after the verified ROM data has
been imported but before the title screen is created.

## Minimal mod

```text
mods/example_mod/
├── manifest.json
└── main.lua
```

`manifest.json`:

```json
{
  "id": "example_mod",
  "name": "Example Mod",
  "version": "1.0.0",
  "entry": "main.lua",
  "priority": 0,
  "dependencies": [],
  "optional_dependencies": [],
  "conflicts": []
}
```

`main.lua`:

```lua
return function(mod)
  mod.log:info("hello from a native mod")

  mod.content.pokemon:override("PIKACHU", {
    name = "PIKACHU",
    types = { "ELECTRIC" },
    base_stats = { hp = 35, attack = 55, defense = 40, speed = 90, special = 50 },
  })

  mod.events:on("battle.start", function(context)
    context.mod_message = "A native mod changed this battle."
  end)
end
```

Mods should use registries and events instead of requiring private engine
modules. Registries currently cover Pokémon, moves, items, maps, tilesets,
encounters, trainers, sprites, music, audio, text, scripts, and UI.

Enablement is stored in the normal persistent `options.lua` file alongside
audio, display, and battle settings, so starting a new game does not disable
the selected mods. Changes take effect after restarting the game.

The loader deliberately does not import or execute arbitrary ROM-hack patches.
The supported content source remains the verified base Pokémon Red ROM plus
native mods.
