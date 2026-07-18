-- Experience gain (engine/battle/experience.asm):
--   exp = floor(baseExp * enemyLevel / 7) for a single participant
--   (trainer battles multiply by 1.5 in Gen 1)
-- Stat experience: the defeated species' base stats are added to each
-- participant's stat exp.

local Growth = require("src.pokemon.Growth")
local Stats = require("src.pokemon.Stats")

local Experience = {}

-- engine/battle/experience.asm order: baseExp is divided by the
-- participant count FIRST, then *level/7, then the traded x1.5
-- (BoostExp) and finally the trainer x1.5.
--
-- EXP.ALL (core.asm .halveExpDataLoop): the base values are halved,
-- GainExperience runs for the participants, then reruns for the whole
-- party -- and because DivideExpDataByNumMonsGainingExp divides the
-- base values IN PLACE, the second pass inherits the participant
-- division: each party member gets (base/2)/participants/partyCount.
-- Sequential floor divisions equal one floor division by the product,
-- so callers pass numParticipants = 2*participants for the first pass
-- and 2*participants*partyCount for the whole-party pass.
function Experience.gainFor(defeatedDef, level, isTrainer, numParticipants, traded)
  local base = math.floor(defeatedDef.baseExp / math.max(1, numParticipants or 1))
  local exp = math.floor(base * level / 7)
  if traded then
    exp = math.floor(exp * 3 / 2)
  end
  if isTrainer then
    exp = math.floor(exp * 3 / 2)
  end
  return math.max(1, exp)
end

-- Applies exp/stat exp; returns the list of levels gained plus the raw
-- exp delta (wExpAmountGained, printed by _ExpPointsText -- captured
-- before the max-level cap, experience.asm:92-100).
function Experience.apply(data, mon, defeatedDef, level, isTrainer,
                          numParticipants, traded)
  local speciesDef = data.pokemon[mon.species]
  -- stat exp is divided among participants too
  -- (DivideExpDataByNumMonsGainingExp divides wEnemyMonBaseStats)
  local statShare = math.max(1, numParticipants or 1)
  for _, key in ipairs(Stats.ORDER) do
    local gain = math.floor(defeatedDef.baseStats[key] / statShare)
    mon.statExp[key] = math.min(65535, (mon.statExp[key] or 0) + gain)
  end
  local gained = Experience.gainFor(defeatedDef, level, isTrainer,
                                    numParticipants, traded)
  mon.exp = mon.exp + gained

  local levels = {}
  local newLevel = Growth.levelForExp(speciesDef.growthRate, mon.exp)
  while mon.level < math.min(newLevel, 100) do
    mon.level = mon.level + 1
    local old = mon.stats
    mon.stats = Stats.calc(speciesDef, mon.level, mon.dvs, mon.statExp)
    mon.hp = math.min(mon.stats.hp, mon.hp + (mon.stats.hp - old.hp))
    table.insert(levels, mon.level)
  end
  return levels, gained
end

-- Moves learned when reaching exactly `level`.
function Experience.movesLearnedAt(speciesDef, level)
  local out = {}
  for _, entry in ipairs(speciesDef.learnset) do
    if entry.level == level then
      table.insert(out, entry.move)
    end
  end
  return out
end

return Experience
