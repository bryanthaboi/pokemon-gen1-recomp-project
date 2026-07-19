function love.conf(t)
  local editor = os.getenv("POKEPORT_EDITOR") == "1"
  if arg then
    for _, a in ipairs(arg) do
      if a == "--editor" then editor = true end
    end
  end
  -- main.lua runs in the same Lua state right after conf.lua; stash the
  -- decision in a global so it doesn't need to reparse `arg`.
  _G.POKEPORT_EDITOR_MODE = editor

  if editor then
    t.identity = os.getenv("POKEPORT_IDENTITY") or "pokemon-love2d-editor"
    t.window.title = "Pokemon Save Editor"
    t.window.width = 1280
    t.window.height = 800
  else
    t.identity = os.getenv("POKEPORT_IDENTITY") or "pokemon-love2d"
    -- Version.lua has zero requires, so it is loadable this early; fall
    -- back to the plain title if the source is not mounted yet
    local ok, Version = pcall(require, "src.core.Version")
    t.window.title = ok and Version.title()
      or "Pokemon Red (Gen 1 Recompilation Project)"
    t.window.width = 160 * 4
    t.window.height = 144 * 4
  end
  t.version = "11.5"
  t.window.vsync = 1
  t.modules.joystick = true
  t.modules.physics = false

  -- love.system is not loaded during love.conf; love._os is set by the
  -- engine before conf runs (LÖVE 11.x / 11.5).
  local osName = love._os
  local mobile = osName == "Android" or osName == "iOS"
  if mobile then
    -- On Android/iOS, width/height aspect picks portrait vs landscape
    -- (fullscreen alone is not enough). Use a tall portrait size; the
    -- OS then resizes to the real display. highdpi is required for
    -- Retina iOS (Android always behaves as highdpi).
    t.window.width = 1080
    t.window.height = 1920
    t.window.fullscreen = true
    t.window.highdpi = true
  else
    t.window.resizable = true
  end
end
