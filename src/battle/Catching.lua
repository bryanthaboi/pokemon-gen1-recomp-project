-- Gen 1 catch algorithm (engine/items/item_effects.asm, ItemUseBall).

local Status = require("src.battle.Status")

local Catching = {}

-- randMax is the ceiling of the catch roll, hpFactor the X of the HP term,
-- wobbleFactor the ballFactor2 divisor of the wobble math.  MASTER_BALL
-- never rolls (autoCatch), so its factors are unused.  tossAnim picks the
-- TossBallAnimation arc and flicker the Master/Ultra OBJ-palette strobe
-- (DoBallTossSpecialEffects).
local BALLS = {
  MASTER_BALL = { randMax = 0, autoCatch = true,
                  tossAnim = "ULTRATOSS_ANIM", flicker = true },
  POKE_BALL   = { randMax = 255, hpFactor = 12, wobbleFactor = 255,
                  tossAnim = "TOSS_ANIM" },
  GREAT_BALL  = { randMax = 200, hpFactor = 8,  wobbleFactor = 200,
                  tossAnim = "GREATTOSS_ANIM" },
  ULTRA_BALL  = { randMax = 150, hpFactor = 12, wobbleFactor = 150,
                  tossAnim = "ULTRATOSS_ANIM", flicker = true },
  SAFARI_BALL = { randMax = 150, hpFactor = 12, wobbleFactor = 150,
                  tossAnim = "ULTRATOSS_ANIM" },
}
Catching.BALLS = BALLS

-- an unknown ball falls back to POKE_BALL's roll and the 150 wobble
-- divisor, which is what the old per-field `or` defaults resolved to
local DEFAULT_BALL = { randMax = 255, hpFactor = 12, wobbleFactor = 150 }

function Catching.registerInto(registry, _, owner)
  for id, record in pairs(BALLS) do
    registry:register(id, record, owner)
  end
end

-- The stock ItemUseBall math.  On failure the ball wobbles per the
-- original's shake calculation: Y = rate*100/ballFactor2 (255/200/150),
-- Z = X*Y/255 + status2 (5/10) where X is the HP factor; Z<10: 0 shakes,
-- <30: 1, <70: 2, else 3.  (We use the HP factor for X on both failure
-- paths; the original reads a stale quotient when the first roll fails.)
local function stockAttempt(def, targetMon, targetDef, rng, rateOverride, statuses)
  if def.autoCatch then return true, 3 end
  local randMax = def.randMax
  local rate = rateOverride or targetDef.catchRate

  -- the status subtraction and the wobble bonus come off the merged
  -- status record (SLP/FRZ 25 and +10, the rest 12 and +5)
  local s = targetMon.status
  local record = Status.recordFor(statuses, s)
  local statusBonus = record and record.catchBonus or 0

  -- HP factor (X)
  local maxhp = targetMon.stats.hp
  local hpQuarter = math.max(1, math.floor(targetMon.hp / 4))
  local factor = def.hpFactor or DEFAULT_BALL.hpFactor
  -- the 255 cap applies only after BOTH divisions (ItemUseBall keeps
  -- the intermediate in 16 bits); capping early collapses the value
  local f = math.min(255, math.floor(math.floor(maxhp * 255 / factor) / hpQuarter))

  local function shakes()
    local ballFactor2 = def.wobbleFactor or DEFAULT_BALL.wobbleFactor
    local y = math.floor(rate * 100 / ballFactor2)
    local z
    if y > 255 then
      z = 255
    else
      z = math.floor(f * y / 255)
    end
    if s then
      z = z + ((record and record.shakeBonus) or 5)
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

-- Returns caught, shakes (0-3).  rateOverride replaces the species catch
-- rate (the Safari game's BAIT/ROCK-modified wEnemyMonActualCatchRate).
-- opts (all optional): ballDef = the merged ball record, statuses = the
-- merged statuses table, battle = the running battle.  A ball record's
-- attempt fn supersedes the whole formula; its ctx.vanillaAttempt() runs
-- the stock math with the ctx's (possibly rewritten) rateOverride.
function Catching.attempt(ball, targetMon, targetDef, rng, rateOverride, opts)
  rng = rng or love.math.random
  opts = opts or {}
  local def = opts.ballDef or BALLS[ball] or DEFAULT_BALL
  local statuses = opts.statuses
  if def.attempt then
    local ctx = {
      ballDef = def, targetMon = targetMon, targetDef = targetDef,
      rng = rng, rateOverride = rateOverride, battle = opts.battle,
    }
    ctx.vanillaAttempt = function()
      return stockAttempt(def, targetMon, targetDef, rng, ctx.rateOverride,
                          statuses)
    end
    return def.attempt(ctx)
  end
  return stockAttempt(def, targetMon, targetDef, rng, rateOverride, statuses)
end

return Catching
