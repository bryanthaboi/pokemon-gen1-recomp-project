-- Central game object: owns the data, renderer, input, state stack, world
-- and save state.  Everything else reaches shared services through here.

local Data = require("src.core.Data")
local FixedStep = require("src.core.FixedStep")
local Input = require("src.core.Input")
local Logger = require("src.core.Logger")
local Renderer = require("src.render.Renderer")
local SaveData = require("src.core.SaveData")
local StateStack = require("src.core.StateStack")
local TouchInput = require("src.core.TouchInput")
local ModLoader = require("src.mods.Loader")

local Game = {}

function Game:load()
  self.data = Data
  Data:load()

  -- Mods are a native engine subsystem.  They load after the verified ROM
  -- data exists, so mods can register or override the same definitions that
  -- the rest of the game consumes.  A broken mod is reported and skipped by
  -- the loader without preventing the base game from booting.
  self.mods = ModLoader.new()
  self.mods:load(Data)
  self.modStatus = self.mods:status()

  self.input = Input
  Input:init()

  self.touchInput = TouchInput
  TouchInput:init()

  self.renderer = Renderer
  Renderer:init()

  require("src.render.Font").load(Data)

  self.stack = StateStack
  StateStack:init()

  self.save = SaveData.newGame()
  -- apply the persisted audio + display options before anything plays
  self:applyOptions(self.save.options)

  FixedStep:init(function(step) self:step(step) end)
  self.fixedStep = FixedStep

  local OverworldState = require("src.world.OverworldController")
  self.overworld = OverworldState

  -- boot into the title screen (engine/movie/title.asm); NEW GAME runs
  -- the Oak speech + naming, CONTINUE restores the save.  The headless
  -- autopilot skips straight into the overworld.
  if os.getenv("POKEPORT_AUTOPILOT") then
    StateStack:push(OverworldState, self.save.player.map,
                    self.save.player.x, self.save.player.y, self.save.player.facing)
  else
    local titleState = self:makeTitleState()
    -- the copyright splash + Nidorino-vs-Gengar attract movie plays
    -- before the title (engine/movie/splash.asm + intro.asm)
    local IntroMovie = require("src.ui.IntroMovie")
    StateStack:push(IntroMovie.new(self, function()
      StateStack:push(titleState)
    end))
  end

  Logger.info("game loaded")
end

-- the title screen with its NEW GAME / CONTINUE wiring; used at boot
-- and by the START-menu QUIT confirmation
function Game:makeTitleState()
  local TitleState = require("src.ui.TitleState")
  local OverworldState = require("src.world.OverworldController")
  return TitleState.new(self, {
    onNewGame = function()
      while self.stack:top() do self.stack:pop() end
      -- New Game keeps the standalone options.lua preferences
      self.save = SaveData.newGame()
      self:applyOptions(self.save.options)
      self.stack:push(OverworldState, self.save.player.map,
                      self.save.player.x, self.save.player.y,
                      self.save.player.facing)
      local OakSpeech = require("src.ui.OakSpeech")
      self.stack:push(OakSpeech.new(self, function() end))
    end,
    onContinue = function()
      local loaded = SaveData.load()
      if loaded then
        self:restoreSave(loaded)
      end
    end,
  })
end

-- QUIT from the START menu: back to the title like a power-cycle,
-- unsaved progress discarded.  TitleState:enter restarts the title
-- theme; stop() keeps the map song from bleeding over in the meantime.
function Game:returnToTitle()
  require("src.core.Music").stop()
  while self.stack:top() do self.stack:pop() end
  self.stack:push(self:makeTitleState())
end

function Game:step(dt)
  self.input:step()
  -- serviced unconditionally: a link battle's ENet transport must not
  -- stall just because PartyMenu/ChoiceBox/NamingScreen is temporarily
  -- on top of BattleState (see LinkBattle.new)
  if self.linkNet and not self.linkNet.closed then
    self.linkNet:update()
  end
  self.stack:update(dt)
  -- play time for the trainer card / save screen
  self.save.playTime = (self.save.playTime or 0) + dt
  require("src.core.Music").update(Data)
end

function Game:update(dt)
  -- Touch timers / prior-frame auto-releases before the fixed step so
  -- deferred A and edge pulses land in Input's press queue for this step.
  TouchInput:update(dt)
  FixedStep:update(dt)
  -- Overworld tilt toggle tween: presentational, so it runs on the real
  -- frame dt (not the fixed logic step) for a smooth ~0.25s glide.
  require("src.render.Tilt").update(dt)
end

function Game:draw()
  -- the UI canvas clears transparent when the overworld's world pass
  -- shows through beneath it; opaque full-screen states get the classic
  -- white clear
  local base = self.stack:visibleBase()
  local worldBelow = self.stack.states[base] == self.overworld
  Renderer:beginFrame(worldBelow)
  self.stack:draw()
  -- SGB colorization: the topmost state that knows its palette owns the
  -- screen (overlays like text boxes inherit from what's beneath them);
  -- the overworld's world pass colors each visible map area separately
  local zones, worldZones
  for i = #self.stack.states, 1, -1 do
    local s = self.stack.states[i]
    if s.sgbPalettes then
      zones = s:sgbPalettes(self)
      break
    end
  end
  if worldBelow and self.overworld.sgbWorldZones then
    worldZones = self.overworld:sgbWorldZones()
  end
  Renderer:endFrame(zones, worldZones)
end

-- overworld survey zoom: wheel up / '=' zooms in, wheel down / '-' out
function Game:zoomStep(delta)
  local Zoom = require("src.render.Zoom")
  if not Zoom.gateOK(self.stack:top(), self.overworld) then return end
  Zoom.step(delta, Renderer:fitScale())
end

function Game:wheelmoved(_, dy)
  if dy > 0 then
    self:zoomStep(1)
  elseif dy < 0 then
    self:zoomStep(-1)
  end
end

function Game:keypressed(key)
  if self.stack and self.stack:top() and self.stack:top().onKeyPressed then
    self.stack:top():onKeyPressed(key)
    return
  end
  if key == "f10" then
    local ManagerState = require("src.mods.ManagerState")
    self.stack:push(ManagerState.new(self))
    return
  end
  if key == "f1" then
    self:writeSave()
    return
  elseif key == "f2" then
    local loaded = SaveData.load()
    if loaded then self:restoreSave(loaded) end
    return
  elseif key == "-" then
    self:zoomStep(-1)
    return
  elseif key == "=" then
    self:zoomStep(1)
    return
  elseif key == "2" then
    -- cycle COLORS (GBC / OG / OG INV / GBC INV / CLASSIC); always on
    local PaletteFX = require("src.render.PaletteFX")
    self.save.options.colors = PaletteFX.cycleMode()
    self:writeOptions()
    return
  elseif key == "3" then
    -- cycle TILT OFF → 15 → 35 → 50 → OFF (mnemonic: 3D), free-roam only
    local Tilt = require("src.render.Tilt")
    if Tilt.gateOK(self.stack:top(), self.overworld) then
      self.save.options.tilt = Tilt.cycle()
      self:writeOptions()
    end
    return
  elseif key == "5" then
    -- cycle GBC FX OFF → 1 → 2 → 3 → 4 (unlit-GBC ladder); always on
    local GBCFX = require("src.render.GBCFX")
    self.save.options.gbcfx = GBCFX.cycle()
    self:writeOptions()
    return
  end
  Input:keypressed(key)
end

-- Mod enablement is stored with persistent options.  Restarting the actual
-- LÖVE process ensures scripts, registries, and assets are all rebuilt from
-- the newly selected mod state.
function Game:restartWithMods()
  if love.event and love.event.quit then
    love.event.quit("restart")
  end
end

function Game:keyreleased(key)
  Input:keyreleased(key)
end

function Game:gamepadpressed(joystick, button)
  Input:gamepadpressed(joystick, button)
end

function Game:gamepadreleased(joystick, button)
  Input:gamepadreleased(joystick, button)
end

function Game:gamepadaxis(joystick, axis, value)
  Input:gamepadaxis(joystick, axis, value)
end

function Game:touchpressed(id, x, y)
  TouchInput:touchpressed(id, x, y)
end

function Game:touchmoved(id, x, y)
  TouchInput:touchmoved(id, x, y)
end

function Game:touchreleased(id, x, y)
  TouchInput:touchreleased(id, x, y)
end

-- Capture the live world state into the save table and persist it.
-- Options are flushed to options.lua as part of SaveData.save.
function Game:writeSave()
  if self.overworld and self.overworld.captureSave then
    self.overworld:captureSave(self.save)
  end
  SaveData.save(self.save)
end

-- Persist options.lua only (Options menu / hotkeys 2-5).  Keeps settings
-- across New Game without touching the progress save.
function Game:writeOptions()
  if not (self.save and self.save.options) then return end
  SaveData.saveOptions(self.save.options)
end

-- Push the live options table into audio + display subsystems.
function Game:applyOptions(opts)
  opts = opts or (self.save and self.save.options) or {}
  local Music = require("src.core.Music")
  local Sound = require("src.core.Sound")
  if Music.applyOptions then Music.applyOptions(opts) end
  if Sound.applyOptions then Sound.applyOptions(opts) end
  require("src.render.PaletteFX").applyOptions(opts)
  require("src.render.Tilt").applyOptions(opts)
  require("src.render.GBCFX").applyOptions(opts)
end

function Game:restoreSave(loaded)
  self.save = loaded
  -- SaveData.load already attached the standalone options.lua table
  self:applyOptions(loaded.options)
  -- saves from before OT/ID stamping: backfill with the player's
  local stamp = require("src.battle.BattleState").stampOT
  for _, mon in ipairs(loaded.party or {}) do stamp(loaded, mon) end
  for _, box in ipairs(loaded.boxes or {}) do
    for _, mon in ipairs(box) do stamp(loaded, mon) end
  end
  -- rebuild the state stack from the save
  while self.stack:top() do self.stack:pop() end
  self.stack:push(self.overworld, loaded.player.map,
                  loaded.player.x, loaded.player.y, loaded.player.facing)
end

return Game
