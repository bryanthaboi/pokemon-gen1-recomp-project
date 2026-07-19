-- Wild encounters from generated encounter tables.
-- Gen 1: on each step into a grass/water cell, a battle starts when
-- rand(0..255) < map encounter rate; the slot is picked with the original
-- probability buckets.

local FieldDefaults = require("src.world.FieldDefaults")

local Encounter = {}

-- Cumulative slot thresholds out of 256 (engine/battle/wild_encounters.asm),
-- now constants.encounterBuckets.  An encounter def may also carry its own
-- `buckets` of any length, as long as the last entry is 256 and there are
-- as many slots as buckets.
local buckets = FieldDefaults.CONSTANTS.encounterBuckets

-- Collision.load's idiom: the overworld hands the dataset over on entry so
-- the pure roll stays free of a Data reference.
function Encounter.load(data)
  buckets = FieldDefaults.constant(data, "encounterBuckets")
end

function Encounter.roll(encounterDef, rng)
  rng = rng or love.math.random
  if not encounterDef then return nil end
  local grass = encounterDef.grass
  if not grass or grass.rate == 0 then return nil end
  if rng(0, 255) >= grass.rate then return nil end
  local pick = rng(0, 255)
  for i, threshold in ipairs(grass.buckets or buckets) do
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
