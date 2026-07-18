-- Turn order, from engine/battle/core.asm MainInBattleLoop: compare
-- effective speed; ties are a coin flip.  QUICK_ATTACK moves first and
-- COUNTER last (Gen 1 has only these two priority moves, checked by id).

local Stats = require("src.pokemon.Stats")

local TurnOrder = {}

local function effectiveSpeed(battler)
  local spd = Stats.applyStage(battler.curStats.speed,
                               battler.stages and battler.stages.speed or 0)
  -- ApplyBadgeStatBoosts: the SOULBADGE (bit 4) boosts speed
  if battler.badges and battler.badges.SOULBADGE then
    spd = math.floor(spd * 9 / 8)
  end
  -- paralysis quarters speed; hazeStatReset suppresses it because Haze
  -- (haze.asm ResetStats) copied the unmodified speed over the quartered
  -- battle stat, lifting the penalty until the next stat recompute.
  if battler.mon.status == "PAR" and not battler.hazeStatReset then
    spd = math.max(1, math.floor(spd / 4))
  end
  return spd
end

local function priority(moveId)
  if moveId == "QUICK_ATTACK" then return 1 end
  if moveId == "COUNTER" then return -1 end
  return 0
end

-- Returns true when battler a moves before battler b.  invertTie flips
-- the coin-flip result only: lockstep link battles share one RNG
-- stream, so the guest inverts the tie roll to agree with the host on
-- who moves first.
function TurnOrder.firstMover(a, aMove, b, bMove, rng, invertTie)
  rng = rng or love.math.random
  local pa, pb = priority(aMove and aMove.id), priority(bMove and bMove.id)
  if pa ~= pb then return pa > pb end
  local sa, sb = effectiveSpeed(a), effectiveSpeed(b)
  if sa ~= sb then return sa > sb end
  local aFirst = rng(0, 1) == 0
  if invertTie then aFirst = not aFirst end
  return aFirst
end

TurnOrder.effectiveSpeed = effectiveSpeed

return TurnOrder
