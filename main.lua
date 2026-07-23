-- Native LÖVE2D port of Pokemon Red. A packaged build creates its private
-- game-data cache from a user-provided ROM on first boot.
--
-- Set POKEPORT_EDITOR=1 or pass `--editor` to `love .` to boot the save
-- editor tool (tools/save-editor/) instead of the game.

local editorMode = os.getenv("POKEPORT_EDITOR") == "1" or POKEPORT_EDITOR_MODE == true

local Game, EditorApp, Importer

local autopilot -- optional scripted-input dev tool (tests/autopilot.lua)
local driverCo  -- optional frame-driver (POKEPORT_DRIVER=file.lua): a
                -- coroutine that receives `Game` and yields once per
                -- frame; used headless (xvfb) for scripted screenshots

-- --speed N / POKEPORT_SPEED=N: run the logic clock N times faster without
-- touching audio (src/core/GameSpeed.lua).  Overrides the saved option so a
-- bot or screenshot run is not at the mercy of the player's last choice.
local speedOverride = tonumber(os.getenv("POKEPORT_SPEED"))

-- How many times to run a scripted act+step loop per rendered frame.  Only
-- scripted runs use this; interactive play fast-forwards through
-- Game.speedOverride / the GAME SPEED option instead.
local function scriptedIterations()
  if not (autopilot or driverCo) then return 1 end
  return math.max(1, math.floor(require("src.core.GameSpeed").clamp(speedOverride)))
end

local function bootGame(version)
  -- The launcher hands us the chosen game (Red / Blue); scripted and headless
  -- runs fall back to POKEPORT_VERSION, then Red.  Set the active version and
  -- overlay its extracted cache BEFORE anything requires generated data, so
  -- data/generated + assets/generated resolve to that version's files.
  local GameVersion = require("src.core.GameVersion")
  GameVersion.set(version or os.getenv("POKEPORT_VERSION") or "red")
  require("src.import.CacheFs").mountVersion(GameVersion.get())
  if love.window and love.window.setTitle then
    local Version = require("src.core.Version")
    love.window.setTitle(Version.title(
      GameVersion.info().displayName .. " (Gen 1 Recompilation Project)"))
  end
  Game = require("src.core.Game")
  Game:load()
  if os.getenv("POKEPORT_AUTOPILOT") then
    autopilot = require("tests.autopilot")
  end
  local driverPath = os.getenv("POKEPORT_DRIVER")
  if driverPath then
    local fn = assert(loadfile(driverPath))()
    driverCo = coroutine.create(fn)
  end
  -- After the two above are known: a scripted run drives the multiplier
  -- from love.update's loop, so the in-engine one must stay at 1 or the
  -- two would compound (10x10 = 100 steps per observation).
  Game.speedOverride = (autopilot or driverCo) and 1 or speedOverride
end

function love.load(args)
  local savePath
  for i, a in ipairs(args or {}) do
    if a == "--editor" then
      editorMode = true
    elseif a == "--developer" then
      _G.POKEPORT_DEV_MODE = true
    elseif a == "--save" and args[i + 1] and args[i + 1] ~= "" then
      savePath = args[i + 1]
    elseif a == "--speed" and tonumber(args[i + 1]) then
      speedOverride = tonumber(args[i + 1])
    end
  end
  love.graphics.setDefaultFilter("nearest", "nearest")

  if editorMode then
    package.path = love.filesystem.getSource() .. "/tools/save-editor/?.lua;"
                .. love.filesystem.getSource() .. "/tools/save-editor/panels/?.lua;"
                .. package.path
    EditorApp = require("App")
    EditorApp.load(savePath)
    return
  end

  local RomImporter = require("src.import.RomImporter")
  local forceImport = os.getenv("POKEPORT_FORCE_IMPORT") == "1"
  local importPath = os.getenv("POKEPORT_IMPORT_ROM")
  -- Scripted / headless runs pick their game from POKEPORT_VERSION (default
  -- Red); the launcher's per-column choice does not apply to them.
  local scriptedVersion = os.getenv("POKEPORT_VERSION") or "red"
  local ready = RomImporter.isReady(scriptedVersion)
  -- Scripted / headless runs have to reach the game with no human pressing
  -- Play: an autopilot, a frame driver, an import-only build step, or an
  -- explicit ROM path all bypass the interactive launcher and keep today's
  -- import-then-boot (or boot-straight-in) behavior.
  local scripted = os.getenv("POKEPORT_AUTOPILOT") or os.getenv("POKEPORT_DRIVER")
    or os.getenv("POKEPORT_IMPORT_ONLY") == "1" or importPath ~= nil

  if scripted then
    if forceImport or not ready then
      -- The importer detects the dropped/loaded ROM's version by SHA-1 and
      -- passes it to onComplete; boot that version.
      Importer = RomImporter.new(function(version)
        if os.getenv("POKEPORT_IMPORT_ONLY") == "1" then
          love.event.quit()
          return
        end
        Importer = nil
        bootGame(version or scriptedVersion)
      end)
      if importPath then Importer:startPath(importPath) end
      return
    end
    bootGame(scriptedVersion)
    return
  end

  -- Interactive: the launcher always runs.  Red and Blue are each live: a
  -- column shows Play when that game's ROM is already imported, or Choose ROM
  -- / drag-drop when it is not (Yellow is still a placeholder).  Any dropped
  -- .gb is routed to Red or Blue by its SHA-1; pressing Play boots that game.
  Importer = RomImporter.new(function(version)
    Importer = nil
    bootGame(version)
  end, { launcher = true, forceImport = forceImport })
end

function love.update(dt)
  if editorMode then return EditorApp.update(dt) end
  if Importer then return Importer:update(dt) end

  -- Scripted runs (autopilot / POKEPORT_DRIVER) observe and act exactly
  -- once per Game:update, so they must keep a 1:1 relationship with the
  -- logic step.  Fast-forwarding them by scaling the step inside
  -- Game:update would run N steps per observation: a held direction walks
  -- through all N, the player slides past the waypoint, and the script
  -- re-plans from an overshot cell.  So iterate the whole act+step loop
  -- instead -- same script, just more of it per rendered frame.
  local iterations = scriptedIterations()

  if autopilot then
    for _ = 1, iterations do
      autopilot.update()
      Game:update(1 / 60) -- deterministic stepping for the autopilot
    end
    return
  end
  if driverCo then
    for _ = 1, iterations do
      local ok, err = coroutine.resume(driverCo, Game)
      if not ok then
        print("driver error: " .. tostring(err))
        love.event.quit(1)
        return
      end
      if coroutine.status(driverCo) == "dead" then
        love.event.quit()
        return
      end
      Game:update(1 / 60)
    end
    return
  end
  Game:update(dt)
end

function love.draw()
  if editorMode then return EditorApp.draw() end
  if Importer then return Importer:draw() end

  Game:draw()
  -- frame capture requested by a driver
  if Game.capturePath then
    local path = Game.capturePath
    Game.capturePath = nil
    love.graphics.captureScreenshot(function(imagedata)
      local fd = imagedata:encode("png")
      local f = io.open(path, "wb")
      if f then
        f:write(fd:getString())
        f:close()
      end
    end)
  end
end

function love.keypressed(key, scancode, isrepeat)
  if editorMode then return EditorApp.keypressed(key) end
  if Importer then return Importer:keypressed(key) end
  Game:keypressed(key)
end

function love.keyreleased(key)
  if editorMode then return end
  if Importer then return end
  Game:keyreleased(key)
end

function love.gamepadpressed(joystick, button)
  if editorMode then return end
  if Importer then return end
  Game:gamepadpressed(joystick, button)
end

function love.gamepadreleased(joystick, button)
  if editorMode then return end
  if Importer then return end
  Game:gamepadreleased(joystick, button)
end

function love.gamepadaxis(joystick, axis, value)
  if editorMode then return end
  if Importer then return end
  Game:gamepadaxis(joystick, axis, value)
end

function love.joystickremoved(joystick)
  if editorMode then return end
  if Importer then return end
  Game:joystickremoved(joystick)
end

-- f is true on focus gained, false on focus lost (e.g. alt-tab). A held
-- direction's key-up can be delivered to the OS instead of the game while
-- unfocused, so reset input on either transition rather than trust it.
function love.focus(f)
  if editorMode then return end
  if Importer then
    if Importer.focus then Importer:focus(f) end
    return
  end
  Game:focus(f)
end

-- v is true when the window becomes visible again, false on minimize.
function love.visible(v)
  if editorMode then return end
  if Importer then return end
  Game:visible(v)
end

function love.touchpressed(id, x, y, dx, dy, pressure)
  if editorMode then return end
  if Importer then return Importer:mousepressed(x, y, 1) end
  Game:touchpressed(id, x, y)
end

function love.touchmoved(id, x, y, dx, dy, pressure)
  if editorMode then return end
  if Importer then return end
  Game:touchmoved(id, x, y)
end

function love.touchreleased(id, x, y, dx, dy, pressure)
  if editorMode then return end
  if Importer then return end
  Game:touchreleased(id, x, y)
end

function love.wheelmoved(x, y)
  if editorMode then
    if EditorApp.wheelmoved then return EditorApp.wheelmoved(x, y) end
    return
  end
  if Importer then return end
  Game:wheelmoved(x, y)
end

function love.mousepressed(x, y, button)
  if Importer then return Importer:mousepressed(x, y, button) end
  if editorMode and EditorApp.mousepressed then
    return EditorApp.mousepressed(x, y, button)
  end
end

function love.mousereleased(x, y, button)
  if Importer then return end
  if editorMode and EditorApp.mousereleased then
    return EditorApp.mousereleased(x, y, button)
  end
end

function love.textinput(text)
  if Importer then return end
  if editorMode and EditorApp.textinput then
    return EditorApp.textinput(text)
  end
end

function love.quit()
  if editorMode and EditorApp.quit then
    return EditorApp.quit() -- return true to abort quit
  end
  pcall(function()
    require("src.core.DiscordPresence").shutdown()
  end)
end

function love.filedropped(file)
  if editorMode and EditorApp and EditorApp.filedropped then
    return EditorApp.filedropped(file)
  end
  if Importer then Importer:filedropped(file) end
end

-- Frame pacing (issue #88): on a machine whose driver control panel forces
-- vsync off, the 160x144 game is so cheap that love.run presents thousands
-- of frames a second, which over hours degrades the graphics driver until a
-- restart (and burns power with the window merely open in the background).
-- A hard render cap bounds it.  Render-only: the logic clock is fixed-step
-- off dt (src/core/FixedStep.lua), so capping present() leaves timing,
-- audio, and determinism untouched, and vsync (conf.lua) is left alone.
--
-- Scripted / headless runs must keep full speed so CI screenshot and bot
-- tooling is not throttled, so they opt out entirely -- same env vars
-- love.load already reads for the scripted-boot path.
local function pacingEnabled()
  if os.getenv("POKEPORT_AUTOPILOT") then return false end
  if os.getenv("POKEPORT_DRIVER") then return false end
  if os.getenv("POKEPORT_IMPORT_ONLY") == "1" then return false end
  return true
end

-- LÖVE 11.5's default run loop, copied faithfully, with a frame-pacing sleep
-- swapped in for the stock trailing love.timer.sleep(0.001).  Kept resilient:
-- with no love.timer (headless) nothing sleeps, exactly as today.
function love.run()
  if love.load then love.load(love.arg.parseGameArguments(arg), arg) end

  -- don't let love.load's cost land in the first frame's dt
  if love.timer then love.timer.step() end

  local FrameCap = require("src.core.FrameCap")
  local paced = pacingEnabled()
  -- The deadline the next present() should not beat.  Carried forward one
  -- budget per frame so pacing stays even instead of drifting with the
  -- per-frame sleep-granularity jitter.
  local nextFrame = love.timer and love.timer.getTime() or 0
  local dt = 0

  return function()
    -- process events
    if love.event then
      love.event.pump()
      for name, a, b, c, d, e, f in love.event.poll() do
        if name == "quit" then
          if not love.quit or not love.quit() then
            return a or 0
          end
        end
        love.handlers[name](a, b, c, d, e, f)
      end
    end

    -- update dt
    if love.timer then dt = love.timer.step() end

    -- call update and draw
    if love.update then love.update(dt) end

    if love.graphics and love.graphics.isActive() then
      love.graphics.origin()
      love.graphics.clear(love.graphics.getBackgroundColor())
      if love.draw then love.draw() end
      love.graphics.present()
    end

    if love.timer then
      if paced then
        -- Sleep out the remainder of the frame budget, measured from the
        -- carried deadline, in small chunks so the OS timer stays
        -- responsive.  vsync is untouched: when it already paces slower
        -- than the cap the remainder is <= 0 and this rounds to a no-op.
        local budget = 1 / FrameCap.current
        nextFrame = nextFrame + budget
        local now = love.timer.getTime()
        -- A stall (alt-tab, a GC pause, a blocked import) can leave the
        -- deadline more than a full budget in the past; re-anchor to now so
        -- we pace the next frame rather than burst uncapped to catch up.
        if now - nextFrame > budget then
          nextFrame = now
        end
        while true do
          local remaining = nextFrame - love.timer.getTime()
          if remaining <= 0 then break end
          love.timer.sleep(remaining < 0.001 and remaining or 0.001)
        end
      else
        love.timer.sleep(0.001)
      end
    end
  end
end
