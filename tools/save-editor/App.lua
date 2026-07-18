-- Save editor app shell: boots the game's generated Data + a save file,
-- and draws a tabbed immediate-mode UI over it via Kit. Panels own their
-- own tab content; this module owns the chrome (save/reload/status/tabs)
-- and the modal MonEditor overlay.

local Data = require("src.core.Data")
local TileRenderer = require("src.render.TileRenderer")
local SaveIO = require("SaveIO")
local Catalog = require("Catalog")
local State = require("State")
local Kit = require("Kit")

local Party = require("Party")
local Boxes = require("Boxes")
local Items = require("Items")
local Events = require("Events")
local MapBrowser = require("MapBrowser")
local Dex = require("Dex")
local MonEditor = require("MonEditor")

local App = {}
local S
local mouseClicked = false

local TABS = {
  { id = "party", label = "Party" },
  { id = "boxes", label = "Boxes" },
  { id = "items", label = "Items" },
  { id = "events", label = "Events" },
  { id = "map", label = "Map" },
  { id = "dex", label = "Dex" },
}

local function fileExists(path)
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return false
end

-- Apply a load attempt for `path` into the current State (S must exist).
local function applyLoaded(path, statusVerb)
  statusVerb = statusVerb or "Loaded"
  S.path = path
  local existed = fileExists(path)
  local save, err = SaveIO.load(path)
  if save then
    S.save = save
    S.status = statusVerb .. " " .. path
    S.mapId = save.player.map
    S.loadError = false
    S.allowSave = true
  elseif existed then
    -- File is present but SaveIO.load couldn't decode it: treat it as a
    -- real (corrupt) save, not a missing one. Editing a stub here is fine,
    -- but Save must stay disabled so we never clobber the corrupt file
    -- until the user fixes it and Reload succeeds.
    S.save = require("src.core.SaveData").newGame()
    S.status = "Corrupt save at " .. path .. " (" .. tostring(err) ..
      "),  Save disabled, use Reload after fixing the file"
    S.mapId = S.save.player.map
    S.loadError = true
    S.allowSave = false
  else
    S.save = require("src.core.SaveData").newGame()
    S.status = "No save at " .. path .. " (" .. tostring(err) ..
      "),  editing new game stub"
    S.mapId = S.save.player.map
    S.loadError = false
    S.allowSave = true
  end
  S.dirty = false
  S._quitArmed = false
  S._openArmed = false
  S.editingMon = nil
  require("src.pokemon.Boxes").ensure(S.save)
end

-- pathOverride lets tests point App.load at a scratch file instead of the
-- real default save path (used to exercise the corrupt-save branch below).
function App.load(pathOverride)
  S = State.new()
  S.data = Data
  Data:load()
  S.cat = Catalog.build(Data)
  S.events = Catalog.scrapeEvents("data/scripts", "data/generated/trainer_headers.lua")
  applyLoaded(pathOverride or SaveIO.defaultPath(), "Loaded")
end

-- Switch to another save file (Open button, drag-drop, or --save arg).
-- If there are unsaved edits, the first call arms a confirm; call again
-- (or pass force=true) to discard and open.
function App.openPath(path, force)
  if not path or path == "" then return false end
  if not S then return false end
  if S.dirty and not force and not S._openArmed then
    S._openArmed = true
    S.status = "Unsaved changes,  open again to discard and load " .. path
    return false
  end
  applyLoaded(path, "Opened")
  return true
end

function App.chooseAndOpen()
  local path = SaveIO.choosePath()
  if path then
    App.openPath(path)
  else
    local osName = love and love.system and love.system.getOS
      and love.system.getOS()
    if osName ~= "OS X" and osName ~= "Windows" and osName ~= "Linux" then
      S.status = "File picker unavailable,  drop a save.lua onto the window"
    end
  end
end

function App.filedropped(file)
  if not file then return end
  local path = file.getFilename and file:getFilename() or nil
  if not path or path == "" then
    S.status = "Could not read dropped file path"
    return
  end
  App.openPath(path)
end

-- Test hook: App.load keeps its state in a module-local so headless tests
-- can drive App.load/App.draw against a scratch path and then inspect the
-- resulting flags/status without loving a real save file.
function App.getState()
  return S
end

function App.update(dt)
  -- Immediate-mode UI: nothing to simulate per-frame; input is sampled
  -- directly in App.draw() via Kit.beginFrame. Tile animation (water,
  -- flowers) still needs ticking so the Map tab isn't static.
  TileRenderer.tick()
end

function App.mousepressed(x, y, button)
  if button == 1 then mouseClicked = true end
end

function App.draw()
  local mx, my = love.mouse.getPosition()
  Kit.beginFrame(mx, my, mouseClicked)
  mouseClicked = false

  local wasDirty = S.dirty

  love.graphics.clear(0.08, 0.08, 0.1)
  Kit.label(12, 10, "Save Editor")

  local saveLabel = S.dirty and "Save*" or "Save"
  if S.loadError then saveLabel = saveLabel .. " (disabled)" end
  if Kit.button(110, 6, 80, 28, saveLabel) then
    if not S.allowSave then
      S.status = "Save disabled,  corrupt save loaded; fix the file and Reload first"
    else
      local ok, err = SaveIO.save(S.path, S.save)
      if ok then
        S.dirty = false
        S._quitArmed = false
        S.status = "Saved " .. S.path
      else
        S.status = "Save failed: " .. tostring(err)
      end
    end
  end

  if Kit.button(200, 6, 80, 28, "Reload") then
    local save, err = SaveIO.load(S.path)
    if save then
      S.save = save
      S.dirty = false
      S.loadError = false
      S.allowSave = true
      S._quitArmed = false
      S._openArmed = false
      S.status = "Reloaded " .. S.path
      require("src.pokemon.Boxes").ensure(S.save)
    else
      S.status = "Reload failed: " .. tostring(err)
    end
  end

  if Kit.button(290, 6, 80, 28, "Open...") then
    App.chooseAndOpen()
  end

  Kit.label(380, 12, S.status)

  local newTab = Kit.tabs(12, 44, TABS, S.tab)
  if newTab then S.tab = newTab end

  local panelY = 80
  if S.tab == "party" then Party.draw(S, Kit, 12, panelY)
  elseif S.tab == "boxes" then Boxes.draw(S, Kit, 12, panelY)
  elseif S.tab == "items" then Items.draw(S, Kit, 12, panelY)
  elseif S.tab == "events" then Events.draw(S, Kit, 12, panelY)
  elseif S.tab == "map" then MapBrowser.draw(S, Kit, 12, panelY)
  elseif S.tab == "dex" then Dex.draw(S, Kit, 12, panelY)
  end

  if S.editingMon then
    MonEditor.draw(S, Kit, 640, panelY)
  end

  -- Any panel above may have just set S.dirty = true; re-arm the quit
  -- confirmation so a fresh round of edits needs its own "quit again".
  if not wasDirty and S.dirty then
    S._quitArmed = false
  end
end

function App.keypressed(key)
  if key == "escape" then S.editingMon = nil end
  if S.tab == "map" and MapBrowser.keypressed then
    MapBrowser.keypressed(S, key)
  end
end

function App.wheelmoved(x, y)
  if S.tab == "map" and MapBrowser.wheelmoved then
    MapBrowser.wheelmoved(S, y)
  end
end

function App.quit()
  if S.dirty then
    -- simple: block quit once and set status; user saves or force-quits again
    if not S._quitArmed then
      S._quitArmed = true
      S.status = "Unsaved changes,  save or press quit again"
      return true
    end
  end
  return false
end

return App
