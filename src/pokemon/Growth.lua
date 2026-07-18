-- Experience growth curves, ported from engine/pokemon/experience.asm
-- (GrowthRateTable coefficients).

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

function Growth.expForLevel(growthRate, level)
  local curve = CURVES[growthRate] or CURVES.MEDIUM_FAST
  return math.max(0, curve(level))
end

function Growth.levelForExp(growthRate, exp)
  local level = 1
  while level < 100 and Growth.expForLevel(growthRate, level + 1) <= exp do
    level = level + 1
  end
  return level
end

return Growth
