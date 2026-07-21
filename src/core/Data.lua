-- Loads generated data from either the private first-boot cache or the
-- optional source-tree developer build.

local Logger = require("src.core.Logger")

local Data = {}

local MODULES = {
  "constants", "maps", "tilesets", "text", "text_pointers",
  "trainer_headers", "font", "sprites", "pokemon", "moves", "items",
  "type_chart", "trainers", "encounters", "field", "battle_anims",
}

-- Optional for compatibility with developer and stale caches.
local OPTIONAL = { "audio", "palettes", "icons" }

-- The rules the engine still carries as literals.  The constants registry
-- deep-merges over these, so a value has to exist before a mod can patch
-- it; each one is the number the engine hard-codes today, so seeding them
-- changes nothing on a mod-free boot.
local CONSTANT_DEFAULTS = {
  bagSize = 20,                 -- BAG_ITEM_CAPACITY (src/inventory/Bag.lua)
  partyMax = 6,                 -- PARTY_LENGTH (src/pokemon/Party.lua)
  boxCount = 12, boxSize = 20,  -- Bill's PC (src/pokemon/Boxes.lua)
  moveMax = 4,
  levelCap = 100,
  coinCap = 9999,               -- MAX_COINS (src/ui/SlotMachine.lua)
  -- move-slot repair when a scrub empties a mon (src/core/SaveData.lua);
  -- a total conversion without TACKLE patches this to its own floor
  fallbackMove = "TACKLE",
  hmMoves = { "CUT", "FLY", "SURF", "STRENGTH", "FLASH" }, -- IsMoveHM
  -- gym order (data/scripts/victories.lua); list position is the badge
  -- number the trainer card draws
  badges = {
    { id = "BOULDERBADGE" }, { id = "CASCADEBADGE" }, { id = "THUNDERBADGE" },
    { id = "RAINBOWBADGE" }, { id = "SOULBADGE" },    { id = "MARSHBADGE" },
    { id = "VOLCANOBADGE" }, { id = "EARTHBADGE" },
  },
}

-- field.boot is the total-conversion override point for the new game; the
-- values match what SaveData.newGame and the Oak speech used to inline.
local BOOT_DEFAULTS = {
  -- special_warps.asm NewGameWarp: REDS_HOUSE_2F, 3, 6 -- the bedroom, not
  -- the tile outside the house. lastHeal is deliberately absent: SaveData
  -- derives the vanilla blackout point, and seeding it here would leak into
  -- total conversions that patch the spawn without naming a heal point.
  startMap = "REDS_HOUSE_2F", startX = 3, startY = 6, startFacing = "down",
  playerName = "RED", rivalName = "BLUE",
  startMoney = 3000,
  screens = { splash = "IntroMovie", title = "TitleState", newGame = "OakSpeech" },
}

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do out[k] = copy(v) end
  return out
end

-- Fills only what the cache is missing, so an importer that learns to
-- stamp one of these keys silently takes over from the engine.
function Data:seedDefaults()
  local constants = self.constants
  for key, value in pairs(CONSTANT_DEFAULTS) do
    if constants[key] == nil then constants[key] = copy(value) end
  end
  -- derived, not literal: a dataset with a different roster gets the right
  -- upper bound without 151 being written down anywhere
  if constants.dexSize == nil then
    local highest = 0
    for _, def in pairs(self.pokemon) do
      if def.dex and def.dex > highest then highest = def.dex end
    end
    constants.dexSize = highest
  end
  if constants.dexDigits == nil then
    constants.dexDigits = math.max(3, #tostring(constants.dexSize))
  end
  local boot = self.field.boot
  if boot == nil then
    boot = {}
    self.field.boot = boot
  end
  for key, value in pairs(BOOT_DEFAULTS) do
    if boot[key] == nil then boot[key] = copy(value) end
  end
  -- the naming screen presets the importer already extracts but nothing
  -- ever read (field.presetNames)
  if boot.namePresets == nil then
    local presets = self.field.presetNames or {}
    boot.namePresets = {
      player = copy(presets.player) or { "RED", "ASH", "JACK" },
      rival = copy(presets.rival) or { "BLUE", "GARY", "JOHN" },
    }
  end
  -- the overworld's Kanto literals, same fill-if-absent contract; required
  -- here rather than at the top so core keeps out of src/world at load time
  require("src.world.FieldDefaults").seed(self)
  -- Cinnabar's quiz trainers are text_asm (no def_trainers), so the
  -- extractor never writes headers for them.  Seed the EVENT_BEAT_* /
  -- after-battle rows so Blaine's SetEventRange deactivation and talk
  -- after-text work like the other gyms (scripts/CinnabarGym.asm).
  self:seedCinnabarGymTrainerHeaders()
end

function Data:seedCinnabarGymTrainerHeaders()
  local headers = self.trainer_headers
  if not headers or headers.CinnabarGym then return end
  local gym = {}
  for i = 0, 6 do
    local n = i + 1
    -- object indices 2..8 are SUPER_NERD1..7; range 0 -- they only
    -- engage via talk / wrong quiz answer, never sight lines
    gym[i + 2] = {
      event = "EVENT_BEAT_CINNABAR_GYM_TRAINER_" .. i,
      range = 0,
      battle = "_CinnabarGymSuperNerd" .. n .. "BattleText",
      won = "_CinnabarGymSuperNerd" .. n .. "EndBattleText",
      after = "_CinnabarGymSuperNerd" .. n .. "AfterBattleText",
    }
  end
  headers.CinnabarGym = gym
end

-- POKEPORT_DATA_DIR points a test runner at another dataset root (the
-- ROM-free fixture set, tests/fixture_data); unset -- every shipped build
-- -- the generated modules load exactly as before.  loadfile skips the
-- require cache, so each overridden load hands back fresh tables.
local function loadModule(dir, name)
  if dir then
    local chunk, err = loadfile(dir .. "/" .. name .. ".lua")
    if not chunk then return false, err end
    return pcall(chunk)
  end
  return pcall(require, "data.generated." .. name)
end

function Data:load()
  local dir = os.getenv("POKEPORT_DATA_DIR")
  for _, name in ipairs(MODULES) do
    local ok, mod = loadModule(dir, name)
    if not ok then
      if dir then
        error(("missing data module '%s/%s.lua' (POKEPORT_DATA_DIR).\n(%s)")
              :format(dir, name, mod))
      end
      error(("missing generated data module 'data/generated/%s.lua'.\n" ..
             "Import the ROM again or rebuild developer data.\n(%s)")
            :format(name, mod))
    end
    self[name] = mod
  end
  for _, name in ipairs(OPTIONAL) do
    local ok, mod = loadModule(dir, name)
    self[name] = ok and mod or nil
    if not ok then
      Logger.warn("optional data module '%s' missing (feature disabled)", name)
    end
  end
  -- before the mod loader runs: the deep registries fold over these
  self:seedDefaults()
  -- the top-level keys a pristine load leaves behind, so reloadGenerated can
  -- strip whatever a mod merge added since; kept on self (assigned before the
  -- scan so it counts itself) because tests load other tables through this
  -- method, and a shared upvalue would let them clobber the singleton's set
  local pristine = {}
  self._pristineKeys = pristine
  for key in pairs(self) do pristine[key] = true end
  Logger.info("generated data loaded (%d maps, %d species, %d moves)",
              (function() local n = 0 for _ in pairs(self.maps) do n = n + 1 end return n end)(),
              (function() local n = 0 for _ in pairs(self.pokemon) do n = n + 1 end return n end)(),
              (function() local n = 0 for _ in pairs(self.moves) do n = n + 1 end return n end)())
end

-- dev-mode hot reload only (src/dev/HotReload.lua): drop every namespace the
-- mod merge created, then re-require the generated modules so base records
-- return to their on-disk values even where a mod edited them in place
function Data:reloadGenerated()
  local pristine = self._pristineKeys
  if pristine then
    for key in pairs(self) do
      if not pristine[key] then self[key] = nil end
    end
  end
  for _, name in ipairs(MODULES) do
    package.loaded["data.generated." .. name] = nil
  end
  for _, name in ipairs(OPTIONAL) do
    package.loaded["data.generated." .. name] = nil
  end
  self:load()
end

-- Resolve a dotted target path, creating empty tables on the way.  Only the
-- mod merge calls this; a vanilla boot never does, so an unmodded Data
-- table is byte-identical to a pre-registry-v2 one.
function Data.ensure(data, path)
  local node = data
  for key in path:gmatch("[^%.]+") do
    if node[key] == nil then node[key] = {} end
    node = node[key]
  end
  return node
end

-- Resolve a TEXT_* constant on a map to a plain string (or nil if the text
-- needs a hand-ported script; see data/scripts/).
function Data:resolveText(mapLabel, textConst)
  local entry = self:textEntry(mapLabel, textConst)
  if not entry then return nil end
  if entry.text then
    local s = self.text[entry.text]
    if s then return s, entry.asm end
  end
  return nil, entry.asm
end

-- The raw text-pointer entry (carries mart/nurse/pc markers and the label).
function Data:textEntry(mapLabel, textConst)
  local perMap = self.text_pointers[mapLabel]
  return perMap and perMap[textConst] or nil
end

-- Trainer sight/dialogue header for a map object (or nil).
function Data:trainerHeader(mapLabel, objIndex)
  local perMap = self.trainer_headers[mapLabel]
  return perMap and perMap[objIndex] or nil
end

return Data
