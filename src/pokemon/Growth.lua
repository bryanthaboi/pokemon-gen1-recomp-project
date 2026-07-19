-- Experience growth curves, ported from engine/pokemon/experience.asm
-- (GrowthRateTable coefficients).  The merged Data.growth_rates registry
-- serves records over these curves; callers that pass it get mod curves,
-- callers that don't keep the vanilla six.

local Logger = require("src.core.Logger")

local Growth = {}

local CURVES = {
  MEDIUM_FAST = function(n) return n * n * n end,
  SLIGHTLY_FAST = function(n) return math.floor((3 * n * n * n) / 4) + 10 * n * n - 30 end,
  SLIGHTLY_SLOW = function(n) return math.floor((3 * n * n * n) / 4) + 20 * n * n - 70 end,
  MEDIUM_SLOW = function(n)
    return math.floor((6 * n * n * n) / 5) - 15 * n * n + 100 * n - 140
  end,
  FAST = function(n) return math.floor((4 * n * n * n) / 5) end,
  SLOW = function(n) return math.floor((5 * n * n * n) / 4) end,
}
Growth.CURVES = CURVES

local warned = {}

-- rates is the merged Data.growth_rates (optional); an unknown curve
-- name logs once and falls back to MEDIUM_FAST instead of mis-leveling
-- silently
function Growth.expForLevel(growthRate, level, rates)
  local record = rates and rates[growthRate]
  if record and record.expForLevel then
    return math.max(0, record.expForLevel(level))
  end
  local curve = CURVES[growthRate]
  if not curve then
    if growthRate ~= nil and not warned[growthRate] then
      warned[growthRate] = true
      Logger.warn("unknown growth rate %s; using MEDIUM_FAST", tostring(growthRate))
    end
    curve = CURVES.MEDIUM_FAST
  end
  return math.max(0, curve(level))
end

-- one record per curve, each closing over the same clamped evaluation the
-- engine calls, so a registry lookup and Growth.expForLevel cannot diverge
function Growth.registerInto(registry, _, owner)
  for id in pairs(CURVES) do
    registry:register(id, { expForLevel = function(level)
      return Growth.expForLevel(id, level)
    end }, owner)
  end
end

function Growth.levelForExp(growthRate, exp, cap, rates)
  cap = cap or 100
  local level = 1
  while level < cap and Growth.expForLevel(growthRate, level + 1, rates) <= exp do
    level = level + 1
  end
  return level
end

return Growth
