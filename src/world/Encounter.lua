-- Wild encounters from generated encounter tables.
-- Gen 1: on each step into a grass/water cell, a battle starts when
-- rand(0..255) < map encounter rate; the slot is picked with the original
-- probability buckets.

local Encounter = {}

-- cumulative slot thresholds out of 256 (engine/battle/wild_encounters.asm)
local SLOT_BUCKETS = { 51, 102, 141, 166, 191, 216, 229, 242, 253, 256 }

function Encounter.roll(encounterDef, rng)
  rng = rng or love.math.random
  if not encounterDef then return nil end
  local grass = encounterDef.grass
  if not grass or grass.rate == 0 then return nil end
  if rng(0, 255) >= grass.rate then return nil end
  local pick = rng(0, 255)
  for i, threshold in ipairs(SLOT_BUCKETS) do
    if pick < threshold then
      local slot = grass.slots[i]
      if slot then
        return { species = slot.species, level = slot.level }
      end
      return nil
    end
  end
  return nil
end

return Encounter
