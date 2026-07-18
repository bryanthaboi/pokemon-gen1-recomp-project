-- Gen 1 catch algorithm (engine/items/item_effects.asm, ItemUseBall).

local Catching = {}

local BALL_RAND_MAX = { MASTER_BALL = 0, POKE_BALL = 255, GREAT_BALL = 200,
                        ULTRA_BALL = 150, SAFARI_BALL = 150 }
local BALL_HP_FACTOR = { POKE_BALL = 12, GREAT_BALL = 8, ULTRA_BALL = 12,
                         SAFARI_BALL = 12 }

-- Returns caught, shakes (0-3).  rateOverride replaces the species catch
-- rate (the Safari game's BAIT/ROCK-modified wEnemyMonActualCatchRate).
--
-- On failure the ball wobbles per the original's shake calculation:
-- Y = rate*100/ballFactor2 (255/200/150), Z = X*Y/255 + status2 (5/10)
-- where X is the HP factor; Z<10: 0 shakes, <30: 1, <70: 2, else 3.
-- (We use the HP factor for X on both failure paths; the original reads
-- a stale quotient when the first roll fails.)
function Catching.attempt(ball, targetMon, targetDef, rng, rateOverride)
  rng = rng or love.math.random
  if ball == "MASTER_BALL" then return true, 3 end
  local randMax = BALL_RAND_MAX[ball] or 255
  local rate = rateOverride or targetDef.catchRate

  local statusBonus = 0
  local s = targetMon.status
  if s == "SLP" or s == "FRZ" then
    statusBonus = 25
  elseif s == "PSN" or s == "BRN" or s == "PAR" then
    statusBonus = 12
  end

  -- HP factor (X)
  local maxhp = targetMon.stats.hp
  local hpQuarter = math.max(1, math.floor(targetMon.hp / 4))
  local factor = BALL_HP_FACTOR[ball] or 12
  -- the 255 cap applies only after BOTH divisions (ItemUseBall keeps
  -- the intermediate in 16 bits); capping early collapses the value
  local f = math.min(255, math.floor(math.floor(maxhp * 255 / factor) / hpQuarter))

  local function shakes()
    local ballFactor2 = ball == "POKE_BALL" and 255
                        or ball == "GREAT_BALL" and 200 or 150
    local y = math.floor(rate * 100 / ballFactor2)
    local z
    if y > 255 then
      z = 255
    else
      z = math.floor(f * y / 255)
    end
    if s == "SLP" or s == "FRZ" then
      z = z + 10
    elseif s then
      z = z + 5
    end
    if z < 10 then return 0 elseif z < 30 then return 1
    elseif z < 70 then return 2 else return 3 end
  end

  local r = rng(0, randMax) - statusBonus
  if r < 0 then return true, 3 end
  if r > rate then return false, shakes() end
  if rng(0, 255) <= f then return true, 3 end
  return false, shakes()
end

return Catching
