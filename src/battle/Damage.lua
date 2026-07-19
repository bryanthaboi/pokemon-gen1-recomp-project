-- Gen 1 damage calculation, ported from engine/battle/core.asm
-- (GetDamage / CriticalHitTest / AdjustDamageForMoveType / RandomizeDamage).
--
-- Battlers carry curStats/curTypes (Transform/Conversion can override the
-- species values) plus reflect/lightScreen/focusEnergy volatile flags.
-- Battlers built by makeBattler also carry the merged badgeBoosts rows and
-- statuses records; hand-built battlers fall back to the vanilla tables.

local Logger = require("src.core.Logger")
local Runtime = require("src.mods.Runtime")
local Stats = require("src.pokemon.Stats")
local Status = require("src.battle.Status")
local TypeChart = require("src.battle.TypeChart")

local Damage = {}

-- Moves with a boosted critical-hit rate (engine/battle/core.asm
-- CriticalHitTest checks these move ids explicitly).  The move-record
-- highCrit field wins; this list covers pre-existing imported caches.
local HIGH_CRIT = {
  KARATE_CHOP = true, RAZOR_LEAF = true, CRABHAMMER = true, SLASH = true,
}

-- ApplyBadgeStatBoosts (engine/battle/core.asm): x9/8 per badge on the
-- named battle stat.  Data.constants.badgeBoosts replaces this via the
-- battler's badgeBoosts field; these rows are the vanilla values.
Damage.BADGE_BOOSTS = {
  { badge = "BOULDERBADGE", stat = "attack", num = 9, den = 8 },
  { badge = "THUNDERBADGE", stat = "defense", num = 9, den = 8 },
  { badge = "SOULBADGE", stat = "speed", num = 9, den = 8 },
  { badge = "VOLCANOBADGE", stat = "special", num = 9, den = 8 },
}

-- the boost a battler's badge set applies to one battle stat, or nil
local function badgeBoost(battler, stat)
  local badges = battler.badges
  if not badges then return nil end
  for _, row in ipairs(battler.badgeBoosts or Damage.BADGE_BOOSTS) do
    if row.stat == stat and badges[row.badge] then return row end
  end
  return nil
end

-- the merged status record for a battler's persistent condition, or nil
local function statusRecord(battler)
  return Status.recordFor(battler.statuses, battler.mon.status)
end

-- Critical chance test, following CriticalHitTest's shift chain exactly
-- (each left shift caps at 255): b = speed/2, then x2 (or /2 with
-- Focus Energy's famous right-shift bug), then x4 for high-crit moves
-- or /2 for normal ones.  Net rates: normal = speed/512, high-crit =
-- speed*4/256 (capped), Focus Energy bug = 1/4 the usual.
-- critUsesBaseSpeed (default true, the Gen 1 rule) reads the species
-- base speed; a ruleset that sets it false uses the current in-battle
-- speed with stages applied.
function Damage.critRoll(ruleset, attacker, moveId, rng, highCrit)
  rng = rng or love.math.random
  local function shl(x) return math.min(255, x * 2) end
  local speed
  if ruleset.critUsesBaseSpeed == false then
    speed = Stats.applyStage(attacker.curStats.speed,
              attacker.stages and attacker.stages.speed or 0)
  else
    speed = attacker.def.baseStats.speed
  end
  local b = math.floor(speed / 2)
  if attacker.focusEnergy then
    if ruleset.focusEnergyBug then
      b = math.floor(b / 2)      -- srl instead of sla
    else
      b = shl(shl(shl(b)))       -- intended: x4 the usual rate
    end
  else
    b = shl(b)
  end
  if highCrit == nil then highCrit = HIGH_CRIT[moveId] end
  if highCrit then
    b = shl(shl(b))
  else
    b = math.floor(b / 2)
  end
  return rng(0, 255) < b
end

-- Accuracy test: rand(0..255) < floor(accuracy * 255 / 100) adjusted by
-- accuracy/evasion stages.  With oneIn256Miss a max-accuracy move still
-- misses on 255.
function Damage.accuracyRoll(ruleset, move, attacker, defender, rng)
  rng = rng or love.math.random
  -- X ACCURACY sets USING_X_ACCURACY: the move simply never misses
  -- (MoveHitTest returns before any accuracy math, 1/256 included)
  if attacker.xAccuracy then return true end
  local acc = math.floor(move.accuracy * 255 / 100)
  -- CalcHitChance scales by the accuracy stage and the evasion stage as
  -- two separate ratio multiplications, clamping each result
  acc = math.min(255, Stats.applyStage(acc,
          attacker.stages and attacker.stages.accuracy or 0))
  acc = math.min(255, Stats.applyStage(acc,
          -(defender.stages and defender.stages.evasion or 0)))
  if not ruleset.oneIn256Miss and move.accuracy >= 100
     and (attacker.stages.accuracy or 0) >= (defender.stages.evasion or 0) then
    return true
  end
  return rng(0, 255) < acc
end

local warnedTypes = {}

-- Gen 1 splits physical from special by TYPE: the move's own category
-- field wins, then the merged type record's, then physical (with one
-- warning per unknown type).
local function categoryOf(move)
  local category = move.category or TypeChart.category(move.type)
  if category == nil then
    if move.type ~= nil and not warnedTypes[move.type] then
      warnedTypes[move.type] = true
      Logger.warn("move type %s has no category; treated as physical",
                  tostring(move.type))
    end
    category = "physical"
  end
  return category
end

function Damage.isSpecial(moveType)
  return TypeChart.category(moveType) == "special"
end

-- Compute damage.  attacker/defender are battler tables.
-- opts: rng, forceCrit, explode (halves defense), typeless (confusion
-- self-hit: no STAB/type/random factor), screens (battler whose
-- Reflect/Light Screen apply when it isn't the defender -- the
-- self-hit reads the opponent's screens).
-- Returns damage, {crit=bool, typeMult=x10}.
function Damage.compute(ruleset, attacker, defender, move, opts)
  opts = opts or {}
  local rng = opts.rng or love.math.random
  if move.power == 0 or move.category == "status" then
    return 0, { crit = false, typeMult = 10 }
  end

  local crit = opts.forceCrit
  if crit == nil then
    if Runtime.wantsHook("battle.crit") then
      crit = Runtime.call("battle.crit", function(c)
        return Damage.critRoll(c.ruleset, c.attacker, c.moveId, c.rng, c.highCrit)
      end, { ruleset = ruleset, attacker = attacker, moveId = move.id,
             rng = rng, highCrit = move.highCrit })
    else
      crit = Damage.critRoll(ruleset, attacker, move.id, rng, move.highCrit)
    end
  end

  local special = categoryOf(move) == "special"
  local atkStat = special and "special" or "attack"
  local defStat = special and "special" or "defense"

  local atk, dfn
  if crit and ruleset.critIgnoresStages then
    atk = attacker.curStats[atkStat]
    dfn = defender.curStats[defStat]
  else
    atk = Stats.applyStage(attacker.curStats[atkStat],
                           attacker.stages and attacker.stages[atkStat] or 0)
    dfn = Stats.applyStage(defender.curStats[defStat],
                           defender.stages and defender.stages[defStat] or 0)
    -- badge boosts (x9/8), engine/battle/core.asm ApplyBadgeStatBoosts:
    -- Boulder -> attack, Thunder -> defense, Soul -> speed (TurnOrder),
    -- Volcano -> special
    local atkBoost = badgeBoost(attacker, atkStat)
    if atkBoost then
      atk = math.floor(atk * (atkBoost.num or 9) / (atkBoost.den or 8))
    end
    local defBoost = badgeBoost(defender, defStat)
    if defBoost then
      dfn = math.floor(dfn * (defBoost.num or 9) / (defBoost.den or 8))
    end
    -- burn halves physical attack (applied as part of the stat in Gen 1;
    -- the status record's statPenalty names the stat it cuts).
    -- hazeStatReset suppresses it: Haze (haze.asm ResetStats) copied the
    -- unmodified attack over the burn-halved battle stat, lifting the
    -- penalty until the next stat recompute.
    local record = statusRecord(attacker)
    local penalty = record and record.statPenalty
    if penalty and penalty.stat == atkStat and not attacker.hazeStatReset then
      atk = math.max(1, math.floor(atk / penalty.div))
    end
    -- screens double the effective defense (crits bypass them).  The
    -- confusion self-hit is the quirk case: HandleSelfConfusionDamage
    -- swaps the user's own defense in but leaves the screen check
    -- reading the OPPONENT's battle status, so the typeless path takes
    -- the screen flags from opts.screens (the opponent) and never from
    -- the user itself.
    if not crit then
      local screens = opts.screens
      if screens == nil and not opts.typeless then screens = defender end
      if screens then
        if special and screens.lightScreen then dfn = dfn * 2 end
        if not special and screens.reflect then dfn = dfn * 2 end
      end
    end
  end
  -- GetDamageVars .scaleStats: when either stat no longer fits a byte,
  -- BOTH are quartered (losing low bits), each bumped to at least 1
  if atk > 255 or dfn > 255 then
    atk = math.max(1, math.floor(atk / 4))
    dfn = math.max(1, math.floor(dfn / 4))
  end
  if opts.explode then
    dfn = math.max(1, math.floor(dfn / 2))
  end

  local level = attacker.mon.level
  if crit then level = level * 2 end

  local d = math.floor(math.floor(2 * level / 5) + 2)
  d = math.floor(math.floor(d * move.power * atk / math.max(1, dfn)) / 50)
  d = math.min(d, 997) + 2

  local mult = 10
  if not opts.typeless then
    -- STAB
    local stab = false
    for _, t in ipairs(attacker.curTypes) do
      if t == move.type then stab = true break end
    end
    if stab then
      d = math.floor(d * 3 / 2)
    end

    -- type effectiveness: each TypeEffects row is applied to the
    -- running damage separately with its own floor (0.5*0.5 lands on
    -- floor(floor(d/2)/2), not d*0.25)
    mult = TypeChart.effectiveness(move.type, defender.curTypes)
    if mult == 0 then
      return 0, { crit = false, typeMult = 0 }
    end
    for _, m in ipairs(TypeChart.rows(move.type, defender.curTypes)) do
      d = math.floor(d * m / 10)
    end
    if d == 0 then
      -- a 2-3 damage hit at 0.25x floors to zero: the original flags
      -- the move as missed rather than dealing a minimum 1
      return 0, { crit = false, typeMult = mult, missed = true }
    end
  end

  -- random factor; the typeless confusion self-hit skips RandomizeDamage
  -- along with AdjustDamageForMoveType (HandleSelfConfusionDamage calls
  -- CalculateDamage directly), so it is fully deterministic
  if d > 1 and not opts.typeless then
    local r = rng(ruleset.randMin, ruleset.randMax)
    d = math.floor(d * r / 255)
  end
  return math.max(d, 1), { crit = crit, typeMult = mult }
end

return Damage
