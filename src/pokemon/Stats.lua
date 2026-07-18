-- Gen 1 stat calculation (home/move_mon.asm CalcStat):
--   stat = floor(((base + DV) * 2 + floor(ceil(sqrt(statExp)) / 4)) * level / 100) + 5
--   HP adds level + 10 instead of 5.
-- The HP DV is derived from the low bits of the other four DVs.

local Stats = {}

local ORDER = { "hp", "attack", "defense", "speed", "special" }
Stats.ORDER = ORDER

function Stats.randomDVs(rng)
  rng = rng or love.math.random
  local dvs = {
    attack = rng(0, 15),
    defense = rng(0, 15),
    speed = rng(0, 15),
    special = rng(0, 15),
  }
  dvs.hp = (dvs.attack % 2) * 8 + (dvs.defense % 2) * 4 +
           (dvs.speed % 2) * 2 + (dvs.special % 2)
  return dvs
end

local function calcOne(base, dv, statExp, level, isHP)
  -- CalcStat .statExpLoop finds the smallest b with b*b >= statExp
  -- (a ceiling sqrt), capped at 255, and quarters it
  local ev = math.floor(math.min(255, math.ceil(math.sqrt(statExp or 0))) / 4)
  local v = math.floor(((base + dv) * 2 + ev) * level / 100)
  if isHP then
    return v + level + 10
  end
  return v + 5
end

function Stats.calc(speciesDef, level, dvs, statExp)
  statExp = statExp or {}
  local out = {}
  for _, key in ipairs(ORDER) do
    out[key] = calcOne(speciesDef.baseStats[key], dvs[key] or 0,
                       statExp[key], level, key == "hp")
  end
  return out
end

-- Battle stat stage multipliers (data/battle/stat_modifiers.asm): stages
-- -6..+6 map to N/D pairs 25/100 .. 400/100.
local STAGE_MULT = {
  [-6] = { 25, 100 }, [-5] = { 28, 100 }, [-4] = { 33, 100 }, [-3] = { 40, 100 },
  [-2] = { 50, 100 }, [-1] = { 66, 100 }, [0] = { 100, 100 }, [1] = { 150, 100 },
  [2] = { 200, 100 }, [3] = { 250, 100 }, [4] = { 300, 100 }, [5] = { 350, 100 },
  [6] = { 400, 100 },
}

function Stats.applyStage(value, stage)
  local m = STAGE_MULT[math.max(-6, math.min(6, stage or 0))]
  local v = math.floor(value * m[1] / m[2])
  return math.max(1, math.min(999, v))
end

return Stats
