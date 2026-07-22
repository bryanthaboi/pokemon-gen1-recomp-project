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
local ModRuntime = require("src.mods.Runtime")
local Screens = require("src.ui.Screens")

local Game = {}

-- dev-mode gate for the F5/backtick hotkeys; false keeps every src/dev
-- module unloaded, so a player boot never touches a byte of dev code
local devMode = os.getenv("POKEPORT_DEV") == "1" or _G.POKEPORT_DEV_MODE == true

-- the boot screen ids (field.boot.screens); a plain function so the
-- headless harness can borrow makeTitleState onto a stub game
local function bootScreens(game)
  local boot = game.data and game.data.field and game.data.field.boot
  return (boot and boot.screens) or {}
end

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
  -- menu cursor/border/geometry constants; field.theme restyles them
  require("src.ui.Theme").load(Data)

  self.stack = StateStack
  StateStack:init()

  self.save = SaveData.newGame(self:bootConfig())
  -- seed=true keeps what entry chunks wrote through mod.save before any
  -- save existed; the skeleton fires save.created exactly once
  self:adoptSave(self.save, true)
  ModRuntime.emit("save.created", { save = self.save })
  -- apply the persisted audio + display options before anything plays
  self:applyOptions(self.save.options)

  FixedStep:init(function(step) self:step(step) end)
  self.fixedStep = FixedStep

  local OverworldState = require("src.world.OverworldController")
  self.overworld = OverworldState

  -- Discord Rich Presence: map name / battle status on the player's profile.
  -- Soft-fail: missing Discord / IPC errors must never block boot.
  pcall(function() require("src.core.DiscordPresence").init(self) end)

  -- every service is up but nothing is on the stack yet; this payload is
  -- the sanctioned way for a mod to obtain the Game object
  ModRuntime.emit("game.ready", { game = self })

  -- boot into the title screen (engine/movie/title.asm); NEW GAME runs
  -- the Oak speech + naming, CONTINUE restores the save.  The headless
  -- autopilot skips straight into the overworld.
  if os.getenv("POKEPORT_AUTOPILOT") then
    StateStack:push(OverworldState, self.save.player.map,
                    self.save.player.x, self.save.player.y, self.save.player.facing)
  else
    local titleState = self:makeTitleState()
    -- the copyright splash + Nidorino-vs-Gengar attract movie plays
    -- before the title (engine/movie/splash.asm + intro.asm); the ids come
    -- from field.boot.screens so a total conversion owns the whole boot
    Screens.push(self, bootScreens(self).splash or "IntroMovie", function()
      StateStack:push(titleState)
    end)
  end

  Logger.info("game loaded")
end

-- the merged field.boot: spawn, names, money and the naming presets a
-- total conversion overrides.  Threaded into SaveData so persistence stays
-- free of a Data dependency.
function Game:bootConfig()
  return self.data and self.data.field and self.data.field.boot
end

-- the title screen with its NEW GAME / CONTINUE wiring; used at boot
-- and by the START-menu QUIT confirmation
function Game:makeTitleState()
  local OverworldState = require("src.world.OverworldController")
  local factory = Screens.get(self, bootScreens(self).title or "TitleState")
  local title = factory.new(self, {
    onNewGame = function()
      while self.stack:top() do self.stack:pop() end
      -- New Game keeps the standalone options.lua preferences
      self.save = SaveData.newGame(self:bootConfig())
      -- no bucket carry-over: mod state from an abandoned session must
      -- not leak into a fresh slot; mods seed via save.created instead
      self:adoptSave(self.save)
      ModRuntime.emit("save.created", { save = self.save })
      self:applyOptions(self.save.options)
      self.stack:push(OverworldState, self.save.player.map,
                      self.save.player.x, self.save.player.y,
                      self.save.player.facing)
      Screens.push(self, bootScreens(self).newGame or "OakSpeech",
                   function() end)
    end,
    onContinue = function()
      local loaded, recovered = SaveData.load()
      if loaded then
        self:restoreSave(loaded, recovered)
      end
    end,
  })
  title.screenId = title.screenId or "TitleState"
  return title
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
  -- Music.update is NOT serviced here: it decrements fade counters and
  -- drives ChipAudio once per call, so running it inside the logic step
  -- would pitch music and sfx up under fast-forward. Game:update advances
  -- it on its own real-time 60Hz accumulator instead.
end

-- The logic multiplier for this frame. Read live rather than cached so the
-- Options row takes effect immediately; speedOverride is the --speed /
-- POKEPORT_SPEED run argument, which wins over the saved option so a bot
-- or screenshot run does not depend on whatever the player last chose.
function Game:logicSpeed()
  local GameSpeed = require("src.core.GameSpeed")
  if self.speedOverride then return GameSpeed.clamp(self.speedOverride) end
  local opts = self.save and self.save.options
  return GameSpeed.clamp(opts and opts.speed or GameSpeed.DEFAULT)
end

function Game:update(dt)
  -- Touch timers / prior-frame auto-releases before the fixed step so
  -- deferred A and edge pulses land in Input's press queue for this step.
  TouchInput:update(dt)
  -- Fast-forward scales only the logic clock (see src/core/GameSpeed.lua).
  -- Give the accumulator room for one full frame at the current speed,
  -- or the anti-spiral clamp quietly caps every level above ~15X.
  local speed = self:logicSpeed()
  FixedStep.maxAccum = math.max(0.25, speed * FixedStep.STEP * 1.5)
  FixedStep:update(dt * speed)
  -- Audio runs off real time at a fixed 60Hz regardless of game speed or
  -- display refresh, so fades and chip synthesis keep their intended tempo
  -- whether we are at 1X, 10X, or running with vsync disabled.
  local step = FixedStep.STEP
  self.audioAccum = math.min((self.audioAccum or 0) + dt, 0.25)
  while self.audioAccum >= step do
    self.audioAccum = self.audioAccum - step
    require("src.core.Music").update(Data)
  end
  -- Overworld tilt toggle tween: presentational, so it runs on the real
  -- frame dt (not the fixed logic step) for a smooth ~0.25s glide.
  require("src.render.Tilt").update(dt)
  pcall(function() require("src.core.DiscordPresence").update(dt) end)
end

-- render.zones' identity default: unhooked, the zone list reaches the blit
-- exactly as the owning state computed it
local function sameZones(_, zones) return zones end

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
  -- 14's render.zones: weather/lighting overlays and custom colorization
  -- recolor or add zones before the blit
  if ModRuntime.wantsHook("render.zones") then
    zones = ModRuntime.call("render.zones", sameZones, self, zones)
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
  if devMode and key == "f5" then
    require("src.dev.HotReload").run(self)
    return
  end
  if devMode and key == "`" then
    self.stack:push(require("src.dev.Console").new(self))
    return
  end
  if key == "f10" then
    -- toggle: the manager no longer swallows the keyboard, so a second
    -- press reaches this branch and closes it instead of stacking another
    local top = self.stack:top()
    if top and top.screenId == "ManagerState" then
      self.stack:pop()
    else
      Screens.push(self, "ManagerState")
    end
    return
  end
  if key == "f1" then
    self:writeSave()
    return
  elseif key == "f2" then
    local loaded, recovered = SaveData.load()
    if loaded then self:restoreSave(loaded, recovered) end
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
  -- BindingsMenu's pad capture rides the same top-state routing as keys
  local top = self.stack and self.stack:top()
  if top and top.onGamepadPressed then
    top:onGamepadPressed(button)
    return
  end
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

-- Point the loader's mod.save backing at this save's modData so per-mod
-- state persists with the slot.  seedBuckets is boot-only: it keeps what
-- entry chunks wrote before any save existed, while NEW GAME and
-- CONTINUE replace the backing outright.
function Game:adoptSave(save, seedBuckets)
  save.modData = save.modData or {}
  local loader = self.mods
  if not loader then return end
  if seedBuckets then
    for id, bucket in pairs(loader.modSave or {}) do
      if save.modData[id] == nil then save.modData[id] = bucket end
    end
  end
  loader.modSave = save.modData
end

-- Capture the live world state into the save table and persist it.
-- Options are flushed to options.lua as part of SaveData.save.
function Game:writeSave()
  if self.overworld and self.overworld.captureSave then
    self.overworld:captureSave(self.save)
  end
  -- stamp here so the save.writing payload carries the exact meta the
  -- file gets; mods snapshot runtime state into their namespace now
  self.save.meta = SaveData.buildMeta(
    self.modStatus and self.modStatus.loaded, self.save.meta)
  if ModRuntime.wants("save.writing") then
    ModRuntime.emit("save.writing", { save = self.save, meta = self.save.meta })
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
  require("src.core.VideoMode").applyOptions(opts)
end

function Game:restoreSave(loaded, recovered)
  if ModRuntime.wants("save.loading") then
    ModRuntime.emit("save.loading", { raw = loaded })
  end
  -- mod chains replay before validation so a mod repairs its own data
  -- instead of watching it get quarantined; core steps already ran in
  -- SaveData.load and skip on the format guard
  local activeMods = self.modStatus and self.modStatus.loaded
  SaveData.runMigrations(loaded, self.mods and self.mods.migrations, activeMods)
  local modsDiff = SaveData.modsDiff(loaded, activeMods)
  local report = SaveData.validate(loaded, self.data)
  report.recovered = recovered
  report.modsDiff = modsDiff
  self.save = loaded
  self:adoptSave(loaded)
  -- SaveData.load already attached the standalone options.lua table
  self:applyOptions(loaded.options)
  -- saves from before OT/ID stamping: backfill with the player's (after
  -- the scrub, so every mon the stamp loop sees is known)
  local stamp = require("src.battle.BattleState").stampOT
  for _, mon in ipairs(loaded.party or {}) do stamp(loaded, mon) end
  for _, box in ipairs(loaded.boxes or {}) do
    for _, mon in ipairs(box) do stamp(loaded, mon) end
  end
  -- rebuild the state stack from the save
  while self.stack:top() do self.stack:pop() end
  self.stack:push(self.overworld, loaded.player.map,
                  loaded.player.x, loaded.player.y, loaded.player.facing)
  self.saveReport = report
  if not SaveData.emptyReport(report) then
    -- the report screen is a Screens id so mods (or the ui milestone) own
    -- its looks; until one exists the log keeps a quarantine from being
    -- silent
    local ok = pcall(Screens.push, self, "QuarantineReport", report)
    if not ok then
      Logger.warn("load report: %d mons quarantined, %d items removed, %d maps remapped%s",
        #report.lostMons, #report.lostItems, #report.remappedMaps,
        recovered and (", recovered from " .. recovered) or "")
      local notice = SaveData.modsDiffNotice(modsDiff, loaded.meta)
      if notice then Logger.warn("%s", notice) end
    end
  end
  if ModRuntime.wants("save.loaded") then
    ModRuntime.emit("save.loaded",
      { save = loaded, meta = loaded.meta, modsDiff = modsDiff })
  end
end

return Game
