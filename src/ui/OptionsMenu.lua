-- Options: text speed, battle animation on/off, battle style SHIFT/SET
-- (engine/menus/main_menu.asm DisplayOptionMenu), the battle ruleset
-- (gen1_faithful keeps the original quirks; modern_clean removes the
-- 1/256 miss etc), plus the port's audio rows and display rows: music/SFX
-- volume (0-7), music low-pass filter (OFF/1X/2X/3X), COLORS / TILT /
-- GBC FX.
-- Option boxes scroll through a four-box viewport; CANCEL stays fixed on
-- the bottom line like pokered's.

local Font = require("src.render.Font")
local PaletteFX = require("src.render.PaletteFX")
local Tilt = require("src.render.Tilt")
local GBCFX = require("src.render.GBCFX")

local OptionsMenu = {}
OptionsMenu.__index = OptionsMenu
OptionsMenu.isOpaque = true

local CURSOR = 0xED     -- "▶" (charmap.asm $ED)
local DOWN_ARROW = 0xEE -- "▼" (charmap.asm $EE): more rows below
-- TextSpeedOptionData frame delays with the original labels
local SPEEDS = { { 1, "FAST" }, { 3, "MEDIUM" }, { 5, "SLOW" } }
local RULES = { "gen1_faithful", "modern_clean" }
local FILTERS = { "OFF", "1X", "2X", "3X" }
-- 3 original options + OG GLITCHES / MUSIC VOL / SFX VOL / MUSIC FILTER
-- + COLORS / TILT / GBC FX + CANCEL
local OPTION_ROWS = 10
local ROWS = 11
local CANCEL_ROW = 11
local VISIBLE = 4 -- option boxes on screen at once (4 tiles each)

function OptionsMenu.new(game)
  return setmetatable({ game = game, index = 1, scroll = 0 }, OptionsMenu)
end

local function speedIndex(game)
  -- default matches InitOptions' TEXT_DELAY_MEDIUM in wOptions
  local cur = game.save.options.textSpeed or 3
  for i, s in ipairs(SPEEDS) do
    if s[1] == cur then return i end
  end
  return 2 -- MEDIUM
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

local function stepColors(opts, dir)
  local i = colorIndex(opts)
  i = wrapIndex(i - 1 + dir, #PaletteFX.MODES) + 1
  opts.colors = PaletteFX.MODES[i]
  PaletteFX.setMode(opts.colors)
end

local function stepTilt(opts, dir)
  opts.tilt = wrapIndex((opts.tilt or 0) + dir, 4)
  Tilt.setLevel(opts.tilt)
end

local function stepGbcfx(opts, dir)
  opts.gbcfx = wrapIndex((opts.gbcfx or 0) + dir, 5)
  GBCFX.setLevel(opts.gbcfx)
end

function OptionsMenu:update(dt)
  local input = self.game.input
  local opts = self.game.save.options
  local changed = false
  if input:wasPressed("up") then
    self.index = self.index > 1 and self.index - 1 or ROWS
  elseif input:wasPressed("down") then
    self.index = self.index < ROWS and self.index + 1 or 1
  elseif input:wasPressed("left") or input:wasPressed("right")
      or input:wasPressed("a") then
    local dir = input:wasPressed("left") and -1 or 1
    if self.index == 1 then
      local i = speedIndex(self.game) % #SPEEDS + 1
      opts.textSpeed = SPEEDS[i][1]
      changed = true
    elseif self.index == 2 then
      opts.animations = opts.animations == false and true or false
      changed = true
    elseif self.index == 3 then
      opts.battleStyle = opts.battleStyle == "set" and "shift" or "set"
      changed = true
    elseif self.index == 4 then
      opts.ruleset = opts.ruleset == RULES[1] and RULES[2] or RULES[1]
      changed = true
    elseif self.index == 5 then
      opts.musicVol = stepVolume(opts.musicVol, dir)
      require("src.core.Music").setVolumeLevel(opts.musicVol)
      changed = true
    elseif self.index == 6 then
      opts.sfxVol = stepVolume(opts.sfxVol, dir)
      require("src.core.Sound").setVolumeLevel(opts.sfxVol)
      changed = true
    elseif self.index == 7 then
      opts.musicFilter = ((opts.musicFilter or 0) + dir) % #FILTERS
      require("src.core.Music").setFilterLevel(opts.musicFilter)
      changed = true
    elseif self.index == 8 then
      stepColors(opts, dir)
      changed = true
    elseif self.index == 9 then
      stepTilt(opts, dir)
      changed = true
    elseif self.index == 10 then
      stepGbcfx(opts, dir)
      changed = true
    elseif input:wasPressed("a") then -- CANCEL
      self.game.stack:pop()
    end
  elseif input:wasPressed("b") or input:wasPressed("start") then
    self.game.stack:pop()
  end
  if changed and self.game.writeOptions then
    self.game:writeOptions()
  end
  -- keep the cursor's box inside the viewport; CANCEL shows the tail
  if self.index >= CANCEL_ROW then
    self.scroll = OPTION_ROWS - VISIBLE
  elseif self.index <= self.scroll then
    self.scroll = self.index - 1
  elseif self.index > self.scroll + VISIBLE then
    self.scroll = self.index - VISIBLE
  end
end

function OptionsMenu:draw()
  local opts = self.game.save.options
  -- one bordered box per option, label line + value line, with CANCEL
  -- below (main_menu.asm DisplayOptionMenu layout, extended with the
  -- port's rows; a ▼ marks option boxes scrolled off below)
  local rows = {
    { "TEXT SPEED", SPEEDS[speedIndex(self.game)][2] },
    { "BATTLE ANIMATION", opts.animations == false and "OFF" or "ON" },
    { "BATTLE STYLE", opts.battleStyle == "set" and "SET" or "SHIFT" },
    { "OG GLITCHES", opts.ruleset == "modern_clean" and "OFF" or "ON" },
    { "MUSIC VOL", volLabel(opts.musicVol) },
    { "SFX VOL", volLabel(opts.sfxVol) },
    { "MUSIC FILTER", FILTERS[(opts.musicFilter or 0) + 1] },
    { "COLORS", PaletteFX.modeLabel(opts.colors or "gbc") },
    { "TILT", Tilt.levelLabel(opts.tilt or 0) },
    { "GBC FX", GBCFX.levelLabel(opts.gbcfx or 0) },
  }
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 144)
  local scroll = self.scroll or 0
  for slot = 1, VISIBLE do
    local i = scroll + slot
    local row = rows[i]
    Font.drawBox(0, (slot - 1) * 4, 20, 4)
    love.graphics.setColor(0, 0, 0, 1)
    Font.draw(row[1], 16, ((slot - 1) * 4 + 1) * 8)
    Font.draw(row[2], 24, ((slot - 1) * 4 + 2) * 8)
    if i == self.index then
      Font.drawCode(CURSOR, 8, ((slot - 1) * 4 + 1) * 8)
    end
  end
  if scroll + VISIBLE < #rows then
    Font.drawCode(DOWN_ARROW, 144, 128)
  end
  Font.draw("CANCEL", 16, 136)
  if self.index == CANCEL_ROW then Font.drawCode(CURSOR, 8, 136) end
  love.graphics.setColor(1, 1, 1, 1)
end

return OptionsMenu
