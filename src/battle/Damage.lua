-- Gen 1 damage calculation, ported from engine/battle/core.asm
-- (GetDamage / CriticalHitTest / AdjustDamageForMoveType / RandomizeDamage).
--
-- Battlers carry curStats/curTypes (Transform/Conversion can override the
-- species values) plus reflect/lightScreen/focusEnergy volatile flags.

local Stats = require("src.pokemon.Stats")
local TypeChart = require("src.battle.TypeChart")

local Damage = {}

-- Moves with a boosted critical-hit rate (engine/battle/core.asm
-- CriticalHitTest checks these move ids explicitly).
local HIGH_CRIT = {
  KARATE_CHOP = true, RAZOR_LEAF = true, CRABHAMMER = true, SLASH = true,
}

-- Critical chance test, following CriticalHitTest's shift chain exactly
-- (each left shift caps at 255): b = baseSpeed/2, then x2 (or /2 with
-- Focus Energy's famous right-shift bug), then x4 for high-crit moves
-- or /2 for normal ones.  Net rates: normal = speed/512, high-crit =
-- speed*4/256 (capped), Focus Energy bug = 1/4 the usual.
function Damage.critRoll(ruleset, attacker, moveId, rng)
  rng = rng or love.math.random
  local function shl(x) return math.min(255, x * 2) end
  local b = math.floor(attacker.def.baseStats.speed / 2)
  if attacker.focusEnergy then
    if ruleset.focusEnergyBug then
      b = math.floor(b / 2)      -- srl instead of sla
    else
      b = shl(shl(shl(b)))       -- intended: x4 the usual rate
    end
  else
    b = shl(b)
  end
  if HIGH_CRIT[moveId] then
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

local function isSpecial(moveType)
  -- Gen 1: WATER/GRASS/FIRE/ICE/ELECTRIC/PSYCHIC/DRAGON are special
  return moveType == "WATER" or moveType == "GRASS" or moveType == "FIRE"
      or moveType == "ICE" or moveType == "ELECTRIC" or moveType == "PSYCHIC_TYPE"
      or moveType == "DRAGON"
end
Damage.isSpecial = isSpecial

-- Compute damage.  attacker/defender are battler tables.
-- opts: rng, forceCrit, explode (halves defense), typeless (confusion
-- self-hit: no STAB/type/random factor), screens (battler whose
-- Reflect/Light Screen apply when it isn't the defender -- the
-- self-hit reads the opponent's screens).
-- Returns damage, {crit=bool, typeMult=x10}.
function Damage.compute(ruleset, attacker, defender, move, opts)
  opts = opts or {}
  local rng = opts.rng or love.math.random
  if move.power == 0 then
    return 0, { crit = false, typeMult = 10 }
  end

  local crit = opts.forceCrit
  if crit == nil then
    crit = Damage.critRoll(ruleset, attacker, move.id, rng)
  end

  local special = isSpecial(move.type)
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
    local badges = attacker.badges
    if badges then
      if not special and badges.BOULDERBADGE then
        atk = math.floor(atk * 9 / 8)
      elseif special and badges.VOLCANOBADGE then
        atk = math.floor(atk * 9 / 8)
      end
    end
    local dbadges = defender.badges
    if dbadges then
      if not special and dbadges.THUNDERBADGE then
        dfn = math.floor(dfn * 9 / 8)
      elseif special and dbadges.VOLCANOBADGE then
        dfn = math.floor(dfn * 9 / 8)
      end
    end
    -- burn halves physical attack (applied as part of the stat in Gen 1).
    -- hazeStatReset suppresses it: Haze (haze.asm ResetStats) copied the
    -- unmodified attack over the burn-halved battle stat, lifting the
    -- penalty until the next stat recompute.
    if not special and attacker.mon.status == "BRN" and not attacker.hazeStatReset then
      atk = math.max(1, math.floor(atk / 2))
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
