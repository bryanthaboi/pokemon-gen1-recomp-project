-- Options: text speed, battle animation on/off, battle style SHIFT/SET
-- (engine/menus/main_menu.asm DisplayOptionMenu), the battle ruleset
-- (cycles the merged rulesets registry; gen1_faithful keeps the original
-- quirks), plus the port's audio rows and display rows: music/SFX
-- volume (0-7), music low-pass filter (OFF/1X/2X/3X), COLORS / TILT /
-- GBC FX, and the MODS row that opens the mod manager.
-- Rows are descriptors fed through the ui.options.rows hook, so mods can
-- add their own; CANCEL is appended after the hook and stays fixed on the
-- bottom line like pokered's.

local PaletteFX = require("src.render.PaletteFX")
local Tilt = require("src.render.Tilt")
local GBCFX = require("src.render.GBCFX")
local Logger = require("src.core.Logger")
local Runtime = require("src.mods.Runtime")
local OptionRows = require("src.ui.OptionRows")

local OptionsMenu = {}
OptionsMenu.__index = OptionsMenu
OptionsMenu.isOpaque = true

-- TextSpeedOptionData frame delays with the original labels
local SPEEDS = { { 1, "FAST" }, { 3, "MEDIUM" }, { 5, "SLOW" } }
-- no-loader fallback for the ruleset row, same pair BattleState keeps
local Rulesets = {
  gen1_faithful = require("src.battle.rulesets.gen1_faithful"),
  modern_clean = require("src.battle.rulesets.modern_clean"),
}
local FILTERS = { "OFF", "1X", "2X", "3X" }

local function speedIndex(game)
  -- default matches InitOptions' TEXT_DELAY_MEDIUM in wOptions
  local cur = game.save.options.textSpeed or 3
  for i, s in ipairs(SPEEDS) do
    if s[1] == cur then return i end
  end
  return 2 -- MEDIUM
end

-- the ruleset row cycles the sorted non-hidden ids of the merged
-- registry (07-battle-extensibility.md 4.6), so mod-registered
-- rulesets are selectable; hidden marks a total conversion's exclusions
local function rulesetIds(game)
  local rulesets = game.data and game.data.rulesets or Rulesets
  local ids = {}
  for id, record in pairs(rulesets) do
    if not record.hidden then ids[#ids + 1] = id end
  end
  table.sort(ids)
  return ids
end

local function rulesetIndex(game, ids)
  local constants = game.data and game.data.constants
  local cur = game.save.options.ruleset
              or (constants and constants.defaultRuleset) or "gen1_faithful"
  for i, id in ipairs(ids) do
    if id == cur then return i end
  end
  return 1
end

local function rulesetName(game)
  local rulesets = game.data and game.data.rulesets or Rulesets
  local ids = rulesetIds(game)
  local id = ids[rulesetIndex(game, ids)] or game.save.options.ruleset
  local record = id and rulesets[id]
  return record and record.name or id or "----"
end

-- 0-7 volume level display (0 = OFF)
local function volLabel(v)
  v = v or 7
  return v == 0 and "OFF" or tostring(v)
end

-- volume rows clamp at the ends, like pokered's text-speed cursor
-- (.pressedLeftInTextSpeed stays at FAST rather than wrapping)
local function stepVolume(v, dir)
  return math.max(0, math.min(7, (v or 7) + dir))
end

local function colorIndex(opts)
  local cur = opts.colors or "gbc"
  for i, m in ipairs(PaletteFX.MODES) do
    if m == cur then return i end
  end
  return 1
end

local function wrapIndex(i, n)
  i = i % n
  if i < 0 then i = i + n end
  return i
end

local function sameRows(_, rows) return rows end

-- the vanilla rows as descriptors; each step body is the old per-index
-- ladder's, so the save.options mutations are unchanged
local function buildRows(game)
  return {
    { id = "textSpeed", label = "TEXT SPEED",
      value = function(g) return SPEEDS[speedIndex(g)][2] end,
      step = function(g)
        local i = speedIndex(g) % #SPEEDS + 1
        g.save.options.textSpeed = SPEEDS[i][1]
        return true
      end },
    { id = "animations", label = "BATTLE ANIMATION",
      value = function(g)
        return g.save.options.animations == false and "OFF" or "ON"
      end,
      step = function(g)
        local o = g.save.options
        o.animations = o.animations == false and true or false
        return true
      end },
    { id = "battleStyle", label = "BATTLE STYLE",
      value = function(g)
        return g.save.options.battleStyle == "set" and "SET" or "SHIFT"
      end,
      step = function(g)
        local o = g.save.options
        o.battleStyle = o.battleStyle == "set" and "shift" or "set"
        return true
      end },
    { id = "ruleset", label = "RULESET",
      value = function(g) return rulesetName(g) end,
      step = function(g, dir)
        local ids = rulesetIds(g)
        if #ids == 0 then return false end
        local i = rulesetIndex(g, ids)
        g.save.options.ruleset = ids[wrapIndex(i - 1 + dir, #ids) + 1]
        return true
      end },
    { id = "musicVol", label = "MUSIC VOL",
      value = function(g) return volLabel(g.save.options.musicVol) end,
      step = function(g, dir)
        local o = g.save.options
        o.musicVol = stepVolume(o.musicVol, dir)
        require("src.core.Music").setVolumeLevel(o.musicVol)
        return true
      end },
    { id = "sfxVol", label = "SFX VOL",
      value = function(g) return volLabel(g.save.options.sfxVol) end,
      step = function(g, dir)
        local o = g.save.options
        o.sfxVol = stepVolume(o.sfxVol, dir)
        require("src.core.Sound").setVolumeLevel(o.sfxVol)
        return true
      end },
    { id = "musicFilter", label = "MUSIC FILTER",
      value = function(g)
        return FILTERS[(g.save.options.musicFilter or 0) + 1]
      end,
      step = function(g, dir)
        local o = g.save.options
        o.musicFilter = ((o.musicFilter or 0) + dir) % #FILTERS
        require("src.core.Music").setFilterLevel(o.musicFilter)
        return true
      end },
    { id = "colors", label = "COLORS",
      value = function(g)
        return PaletteFX.modeLabel(g.save.options.colors or "gbc")
      end,
      step = function(g, dir)
        local o = g.save.options
        local i = colorIndex(o)
        i = wrapIndex(i - 1 + dir, #PaletteFX.MODES) + 1
        o.colors = PaletteFX.MODES[i]
        PaletteFX.setMode(o.colors)
        return true
      end },
    { id = "tilt", label = "TILT",
      value = function(g) return Tilt.levelLabel(g.save.options.tilt or 0) end,
      step = function(g, dir)
        local o = g.save.options
        o.tilt = wrapIndex((o.tilt or 0) + dir, 4)
        Tilt.setLevel(o.tilt)
        return true
      end },
    { id = "gbcfx", label = "GBC FX",
      value = function(g)
        return GBCFX.levelLabel(g.save.options.gbcfx or 0)
      end,
      step = function(g, dir)
        local o = g.save.options
        o.gbcfx = wrapIndex((o.gbcfx or 0) + dir, 5)
        GBCFX.setLevel(o.gbcfx)
        return true
      end },
    -- the manager's discoverable home (18-mod-manager-ux); inert until
    -- opened, so the row costs a vanilla install nothing
    { id = "mods", label = "MODS",
      value = function(g)
        local status = g.modStatus or {}
        return ("%d INSTALLED"):format(#(status.available or {}))
      end,
      activate = function(g)
        require("src.ui.Screens").push(g, "ManagerState")
      end },
    -- rebinding UI (gap C2, 12-ui-extensibility 4.4); captured inputs
    -- live in options.bindings, so the row costs a vanilla install nothing
    { id = "controls", label = "CONTROLS",
      activate = function(g)
        require("src.ui.Screens").push(g, "BindingsMenu")
      end },
  }
end

function OptionsMenu.new(game)
  local rows = buildRows(game)
  local hooked = Runtime.call("ui.options.rows", sameRows, game, rows)
  if type(hooked) == "table" then
    rows = hooked
  else
    Logger.error("ui.options.rows returned %s; keeping the vanilla rows",
                 type(hooked))
  end
  return setmetatable({ game = game, rows = rows, index = 1, scroll = 0 },
                      OptionsMenu)
end

function OptionsMenu:update(dt)
  local input = self.game.input
  local rows = self.rows
  -- CANCEL sits below the hook-built rows so a mod cannot orphan the exit
  local cancelRow = #rows + 1
  local changed = false
  if input:wasPressed("up") then
    self.index = self.index > 1 and self.index - 1 or cancelRow
  elseif input:wasPressed("down") then
    self.index = self.index < cancelRow and self.index + 1 or 1
  elseif input:wasPressed("left") or input:wasPressed("right")
      or input:wasPressed("a") then
    local dir = input:wasPressed("left") and -1 or 1
    local row = rows[self.index]
    if row and row.activate then
      if input:wasPressed("a") then row.activate(self.game) end
    elseif row and row.step then
      changed = row.step(self.game, dir) and true or false
    elseif input:wasPressed("a") then -- CANCEL
      self.game.stack:pop()
    end
  elseif input:wasPressed("b") or input:wasPressed("start") then
    self.game.stack:pop()
  end
  if changed and self.game.writeOptions then
    self.game:writeOptions()
  end
  self.scroll = OptionRows.clampScroll(self.index, self.scroll or 0,
                                       #rows, cancelRow)
end

function OptionsMenu:draw()
  OptionRows.draw(self.game, self.rows, self.index, self.scroll or 0,
                  "CANCEL", #self.rows + 1)
end

return OptionsMenu
