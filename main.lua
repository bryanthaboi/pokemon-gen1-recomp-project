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

local function bootGame()
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
end

function love.load(args)
  local savePath
  for i, a in ipairs(args or {}) do
    if a == "--editor" then
      editorMode = true
    elseif a == "--save" and args[i + 1] and args[i + 1] ~= "" then
      savePath = args[i + 1]
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
  if os.getenv("POKEPORT_FORCE_IMPORT") == "1" or not RomImporter.isReady() then
    Importer = RomImporter.new(function()
      if os.getenv("POKEPORT_IMPORT_ONLY") == "1" then
        love.event.quit()
        return
      end
      Importer = nil
      bootGame()
    end)
    local importPath = os.getenv("POKEPORT_IMPORT_ROM")
    if importPath then Importer:startPath(importPath) end
    return
  end
  bootGame()
end

function love.update(dt)
  if editorMode then return EditorApp.update(dt) end
  if Importer then return Importer:update(dt) end

  if autopilot then
    autopilot.update()
    Game:update(1 / 60) -- deterministic stepping for the autopilot
    return
  end
  if driverCo then
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
end

function love.filedropped(file)
  if editorMode and EditorApp and EditorApp.filedropped then
    return EditorApp.filedropped(file)
  end
  if Importer then Importer:filedropped(file) end
end
