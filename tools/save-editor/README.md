# Save Editor

```bash
# from repo root, game closed
love . --editor
# or
POKEPORT_EDITOR=1 love .
# open a specific save (any path)
love . --editor --save "/path/to/save.lua"
```

By default loads the game's LÖVE save:

- macOS: `~/Library/Application Support/LOVE/pokemon-love2d/save.lua`
- Linux: `~/.local/share/love/pokemon-love2d/save.lua`
- Windows: `%APPDATA%\love\pokemon-love2d\save.lua`

If the file isn't there (or you want another copy), use **Open...**, drop a
`save.lua` onto the window, or pass `--save`. Each write makes
`save.lua.bak-YYYYMMDD-HHMMSS` first.

## Headless tests

Run from repo root (use `lua5.4` or the same Lua 5.4 binary as `tests/run_tests.lua`):

```bash
lua5.4 tests/run_save_editor_tests.lua      # core logic + Party/MonEditor (60 tests)
lua5.4 tests/save_editor_task6_tests.lua    # Boxes + Items panels
lua5.4 tests/save_editor_task7_tests.lua      # Events + Dex panels
lua5.4 tests/save_editor_task8_tests.lua      # Map browser + set location
```

The task-specific suites are separate files (each defines its own harness) so they can be run independently without colliding with the main runner.
