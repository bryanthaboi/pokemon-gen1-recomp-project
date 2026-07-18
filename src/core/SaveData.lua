-- Save/load via love.filesystem.  Game progress lives in save.lua;
-- Options (audio, display, battle preferences) live in a separate
-- options.lua so they survive New Game and aren't tied to a save slot.
-- Both are plain Lua tables serialized as Lua source (deterministic
-- key order).

local Logger = require("src.core.Logger")

local SaveData = {}

local FILENAME = "save.lua"
local OPTIONS_FILENAME = "options.lua"

-- Port + original Options menu defaults.  Missing keys on load are filled
-- from this table so old options.lua files stay compatible.
function SaveData.defaultOptions()
  return {
    -- textSpeed 3 = MEDIUM, matching InitOptions' TEXT_DELAY_MEDIUM
    -- in wOptions (engine/menus/main_menu.asm)
    textSpeed = 3,
    animations = true,
    battleStyle = "shift",
    ruleset = "gen1_faithful",
    -- 0-7 like the GB's NR50 master volume
    musicVol = 7,
    sfxVol = 7,
    musicFilter = 0,
    -- port display options (OptionsMenu / hotkeys 2/3/5)
    colors = "gbc",
    tilt = 0,
    gbcfx = 0,
    -- Native mod enablement is an installation option, not save-slot data.
    -- Missing entries mean enabled so newly installed mods work by default.
    mods = {},
  }
end

-- Merge loaded keys over defaults (shallow).  Unknown keys are kept so
-- future options aren't dropped by older builds writing the file back.
function SaveData.mergeOptions(loaded)
  local opts = SaveData.defaultOptions()
  if type(loaded) == "table" then
    for k, v in pairs(loaded) do
      opts[k] = v
    end
  end
  return opts
end

local function serialize(v, indent)
  indent = indent or 0
  local pad = string.rep("  ", indent)
  local t = type(v)
  if t == "number" or t == "boolean" then
    return tostring(v)
  elseif t == "string" then
    return string.format("%q", v)
  elseif t == "table" then
    local keys = {}
    for k in pairs(v) do table.insert(keys, k) end
    table.sort(keys, function(a, b)
      local ta, tb = type(a), type(b)
      if ta ~= tb then return ta < tb end
      return a < b
    end)
    if next(v) == nil then return "{}" end
    local parts = {}
    for _, k in ipairs(keys) do
      local key
      if type(k) == "string" and k:match("^[%a_][%w_]*$") then
        key = k
      else
        key = "[" .. serialize(k) .. "]"
      end
      table.insert(parts, pad .. "  " .. key .. " = " .. serialize(v[k], indent + 1))
    end
    return "{\n" .. table.concat(parts, ",\n") .. ",\n" .. pad .. "}"
  end
  error("cannot serialize " .. t)
end

function SaveData.encode(data)
  return "return " .. serialize(data) .. "\n"
end

function SaveData.decode(str)
  local loader = loadstring or load
  local chunk, err = loader(str, "@save.lua")
  if not chunk then return nil, err end
  local ok, data = pcall(chunk)
  if not ok then return nil, data end
  if type(data) ~= "table" then return nil, "save root must be a table" end
  return data
end

function SaveData.saveOptions(opts)
  opts = SaveData.mergeOptions(opts)
  local ok, err = love.filesystem.write(OPTIONS_FILENAME, SaveData.encode(opts))
  if not ok then
    Logger.error("options save failed: %s", tostring(err))
  end
  return ok and opts or nil
end

function SaveData.loadOptions()
  if not love.filesystem.getInfo(OPTIONS_FILENAME) then
    return SaveData.defaultOptions()
  end
  local chunk, err = love.filesystem.load(OPTIONS_FILENAME)
  if not chunk then
    Logger.error("options load failed: %s", tostring(err))
    return SaveData.defaultOptions()
  end
  local ok, data = pcall(chunk)
  if not ok or type(data) ~= "table" then
    Logger.error("options load failed: %s", tostring(data))
    return SaveData.defaultOptions()
  end
  return SaveData.mergeOptions(data)
end

-- Game progress only; options are written separately via saveOptions.
-- If `data.options` is present it is also flushed to options.lua so an
-- F1 / in-game save keeps the live settings in sync, then stripped from
-- the game file.
function SaveData.save(data)
  if data.options then
    SaveData.saveOptions(data.options)
  end
  local gameOnly = {}
  for k, v in pairs(data) do
    if k ~= "options" then gameOnly[k] = v end
  end
  local ok, err = love.filesystem.write(FILENAME, SaveData.encode(gameOnly))
  if ok then
    Logger.info("saved game")
  else
    Logger.error("save failed: %s", tostring(err))
  end
  return ok
end

function SaveData.load()
  if not love.filesystem.getInfo(FILENAME) then
    return nil
  end
  local chunk, err = love.filesystem.load(FILENAME)
  if not chunk then
    Logger.error("load failed: %s", tostring(err))
    return nil
  end
  local ok, data = pcall(chunk)
  if not ok then
    Logger.error("load failed: %s", tostring(data))
    return nil
  end
  -- saves from before the trainer ID existed: backfill once on load
  -- (like the OT backfill for old saves)
  if data.player and not data.player.id then
    data.player.id = math.random(0, 65535)
  end
  -- saves from before EVENT_BEAT_ROUTE12/16_SNORLAX existed: the object
  -- was already hidden (Snorlax beaten) but the flag was never added,
  -- and it can never be set again since the hidden object is
  -- unreachable -- backfill it from the toggle so it isn't stuck forever
  if data.objectToggles and data.flags then
    local snorlaxRoutes = {
      { map = "ROUTE_12", obj = "ROUTE12_SNORLAX", flag = "EVENT_BEAT_ROUTE12_SNORLAX" },
      { map = "ROUTE_16", obj = "ROUTE16_SNORLAX", flag = "EVENT_BEAT_ROUTE16_SNORLAX" },
    }
    for _, r in ipairs(snorlaxRoutes) do
      local toggles = data.objectToggles[r.map]
      if toggles and toggles[r.obj] == false and not data.flags[r.flag] then
        data.flags[r.flag] = true
      end
    end
  end
  -- Migrate options that still live inside an old save.lua into the
  -- standalone options file (once), then always prefer options.lua.
  if type(data.options) == "table" and not love.filesystem.getInfo(OPTIONS_FILENAME) then
    SaveData.saveOptions(data.options)
  end
  data.options = SaveData.loadOptions()
  Logger.info("loaded save")
  return data
end

function SaveData.newGame()
  return {
    player = {
      map = "PALLET_TOWN",
      x = 5,
      y = 6,
      facing = "down",
      name = "RED",
      rival = "BLUE",
      -- 16-bit trainer ID rolled at new game (wPlayerID, filled from
      -- hRandomAdd in OakSpeech)
      id = math.random(0, 65535),
    },
    flags = {},
    inventory = {},
    party = {},
    box = {},
    money = 3000,
    defeatedTrainers = {},
    pokedex = { seen = {}, owned = {} },
    -- where blackouts and ESCAPE ROPE return to (updated by nurses)
    lastHeal = { map = "PALLET_TOWN", x = 5, y = 6 },
    repelSteps = 0,
    -- Live options from options.lua (or defaults); New Game keeps the
    -- player's audio/display/battle preferences.
    options = SaveData.loadOptions(),
  }
end

return SaveData
