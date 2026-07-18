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

function Data:load()
  for _, name in ipairs(MODULES) do
    local ok, mod = pcall(require, "data.generated." .. name)
    if not ok then
      error(("missing generated data module 'data/generated/%s.lua'.\n" ..
             "Import the ROM again or rebuild developer data.\n(%s)")
            :format(name, mod))
    end
    self[name] = mod
  end
  for _, name in ipairs(OPTIONAL) do
    local ok, mod = pcall(require, "data.generated." .. name)
    self[name] = ok and mod or nil
    if not ok then
      Logger.warn("optional data module '%s' missing (feature disabled)", name)
    end
  end
  Logger.info("generated data loaded (%d maps, %d species, %d moves)",
              (function() local n = 0 for _ in pairs(self.maps) do n = n + 1 end return n end)(),
              (function() local n = 0 for _ in pairs(self.pokemon) do n = n + 1 end return n end)(),
              (function() local n = 0 for _ in pairs(self.moves) do n = n + 1 end return n end)())
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
