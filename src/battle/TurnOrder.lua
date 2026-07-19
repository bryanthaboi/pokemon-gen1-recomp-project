-- Turn order, from engine/battle/core.asm MainInBattleLoop: compare
-- effective speed; ties are a coin flip.  Move priority reads the move
-- record's priority field; the id table below covers pre-existing
-- imported caches (Gen 1 has only QUICK_ATTACK first and COUNTER last).

local Damage = require("src.battle.Damage")
local Stats = require("src.pokemon.Stats")
local Status = require("src.battle.Status")

local TurnOrder = {}

local function effectiveSpeed(battler)
  local spd = Stats.applyStage(battler.curStats.speed,
                               battler.stages and battler.stages.speed or 0)
  -- ApplyBadgeStatBoosts: the SOULBADGE boosts speed; the rows come from
  -- the battler's merged badgeBoosts with the vanilla list as fallback
  local badges = battler.badges
  if badges then
    for _, row in ipairs(battler.badgeBoosts or Damage.BADGE_BOOSTS) do
      if row.stat == "speed" and badges[row.badge] then
        spd = math.floor(spd * (row.num or 9) / (row.den or 8))
        break
      end
    end
  end
  -- paralysis quarters speed (the status record's statPenalty);
  -- hazeStatReset suppresses it because Haze (haze.asm ResetStats)
  -- copied the unmodified speed over the quartered battle stat, lifting
  -- the penalty until the next stat recompute.
  local record = Status.recordFor(battler.statuses, battler.mon.status)
  local penalty = record and record.statPenalty
  if penalty and penalty.stat == "speed" and not battler.hazeStatReset then
    spd = math.max(1, math.floor(spd / penalty.div))
  end
  return spd
end

local PRIORITY = { QUICK_ATTACK = 1, COUNTER = -1 }

local function priority(move)
  if not move then return 0 end
  if move.priority then return move.priority end
  return PRIORITY[move.id] or 0
end

-- Returns true when battler a moves before battler b.  invertTie flips
-- the coin-flip result only: lockstep link battles share one RNG
-- stream, so the guest inverts the tie roll to agree with the host on
-- who moves first.
function TurnOrder.firstMover(a, aMove, b, bMove, rng, invertTie)
  rng = rng or love.math.random
  local pa, pb = priority(aMove), priority(bMove)
  if pa ~= pb then return pa > pb end
  local sa, sb = effectiveSpeed(a), effectiveSpeed(b)
  if sa ~= sb then return sa > sb end
  local aFirst = rng(0, 1) == 0
  if invertTie then aFirst = not aFirst end
  return aFirst
end

TurnOrder.effectiveSpeed = effectiveSpeed

return TurnOrder
