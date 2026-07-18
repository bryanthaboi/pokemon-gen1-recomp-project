-- Move effect handlers for every effect constant used in
-- data/moves/moves.asm, ported from engine/battle/core.asm and
-- engine/battle/move_effects/*.  Handlers receive the battle plus user and
-- target battler tables and push messages through battle:sayNext.
--
-- Substitutes block status/stat effects and side effects aimed at their
-- owner, like Gen 1.

local Logger = require("src.core.Logger")

local MoveEffects = {}

-- pokered's <USER>/<TARGET> text macros print "Enemy " before the
-- enemy mon's nickname (home/text.asm PlaceMoveUsersName)
local function displayName(b)
  return b.isPlayer and b.name or ("Enemy " .. b.name)
end

local STAT_LABEL = {
  attack = "ATTACK", defense = "DEFENSE", speed = "SPEED",
  special = "SPECIAL", accuracy = "ACCURACY", evasion = "EVADE",
}

-- ---------------------------------------------------------------------
-- stat stages
-- ---------------------------------------------------------------------

local function changeStage(battle, who, stat, delta, fromEnemy)
  if fromEnemy and (who.substituteHP or who.mist) then
    if who.mist then
      return { displayName(who) .. " is\nprotected by MIST!" }
    end
    return { "But, it failed!" }
  end
  local cur = who.stages[stat] or 0
  local new = math.max(-6, math.min(6, cur + delta))
  if new == cur then
    return { ("Nothing happened!") }
  end
  who.stages[stat] = new
  -- effects.asm:505-506: after any stat-stage change, modified stats are
  -- recomputed and QuarterSpeedDueToParalysis/HalveAttackDueToBurn re-run,
  -- re-baking the burn/para penalty and ending Haze's temporary lift.
  who.hazeStatReset = nil
  -- _MonsStatsRoseText/_MonsStatsFellText: "X's / STAT rose!"; the
  -- two-stage variants scroll "greatly" onto a third line
  if delta >= 2 then
    return { ("%s's\n%s\ngreatly rose!"):format(displayName(who), STAT_LABEL[stat]) }
  elseif delta == 1 then
    return { ("%s's\n%s rose!"):format(displayName(who), STAT_LABEL[stat]) }
  elseif delta == -1 then
    return { ("%s's\n%s fell!"):format(displayName(who), STAT_LABEL[stat]) }
  end
  return { ("%s's\n%s\ngreatly fell!"):format(displayName(who), STAT_LABEL[stat]) }
end

local function statUp(stat, delta)
  return function(battle, user, target)
    return changeStage(battle, user, stat, delta, false)
  end
end

local function statDown(stat, delta)
  return function(battle, user, target)
    return changeStage(battle, target, stat, -delta, true)
  end
end

-- ---------------------------------------------------------------------
-- status
-- ---------------------------------------------------------------------

local STATUS_LABEL = {
  SLP = "fell asleep", PSN = "was poisoned", BRN = "was burned",
  FRZ = "was frozen solid",
}

-- opts: toxic (start the Toxic counter), moveType (for the type
-- gates), secondary (side-effect of a damaging move).
local function inflictStatus(battle, target, status, opts)
  opts = opts or {}
  if target.mon.status then return {} end
  -- Substitutes block poison (PoisonEffect calls CheckTargetSubstitute)
  -- and every secondary status, but NOT primary Sleep or Thunder Wave, 
  -- their handlers never check the substitute in Gen 1.
  if target.substituteHP and (opts.secondary or status == "PSN") then
    return {}
  end
  for _, t in ipairs(target.curTypes) do
    -- can't poison Poison-types (primary or secondary)
    if status == "PSN" and t == "POISON" then return {} end
    -- ParalyzeEffect_: Electric-type moves can't paralyze Ground-types
    if status == "PAR" and opts.moveType == "ELECTRIC" and t == "GROUND" then
      return {}
    end
    -- FreezeBurnParalyzeEffect: a secondary status never lands when
    -- the move's type matches either of the target's types (Body Slam
    -- can't paralyze Normals, Fire can't burn Fire, Ice can't freeze Ice)
    if opts.secondary and status ~= "PSN" and opts.moveType == t then
      return {}
    end
    -- keep the canonical immunities for any non-secondary path
    if (status == "BRN" and t == "FIRE") or (status == "FRZ" and t == "ICE") then
      return {}
    end
  end
  target.mon.status = status
  if status == "SLP" then
    target.sleepTurns = battle.rng(1, 7)
  end
  if opts.toxic then
    target.toxicCounter = 1
    -- _BadlyPoisonedText
    return { ("%s's\nbadly poisoned!"):format(displayName(target)) }
  end
  if status == "PAR" then
    -- _ParalyzedMayNotAttackText (primary and secondary paralysis)
    return { ("%s's\nparalyzed! It may\nnot attack!"):format(displayName(target)) }
  end
  return { ("%s\n%s!"):format(displayName(target), STATUS_LABEL[status]) }
end

local function statusMove(status)
  return function(battle, user, target, move)
    if target.mon.status then
      return { "But, it failed!" }
    end
    if status == "PSN" and target.substituteHP then
      return { "But, it failed!" }
    end
    local msgs = inflictStatus(battle, target, status, {
      toxic = move and move.id == "TOXIC",
      moveType = move and move.type,
    })
    if #msgs == 0 then
      return { "But, it failed!" }
    end
    return msgs
  end
end

local function statusSide(status, chance)
  return function(battle, user, target, move)
    -- CheckDefrost: a burn-chance Fire move that lands thaws a frozen
    -- target (regardless of the burn roll)
    if move and move.type == "FIRE" and target.mon.status == "FRZ" then
      target.mon.status = nil
      return { ("Fire defrosted\n%s!"):format(displayName(target)) }
    end
    if battle.rng(0, 255) >= chance then return {} end
    return inflictStatus(battle, target, status, {
      moveType = move and move.type,
      secondary = true,
    })
  end
end

local function statDownSide(stat)
  return function(battle, user, target)
    if target.substituteHP then return {} end
    if battle.rng(0, 255) >= 85 then return {} end -- 33 percent + 1 (85/256)
    -- StatModifierDownEffect's side-effect branch never runs MoveHitTest,
    -- so the drop pierces MIST (only primary stat-lowering moves check it)
    return changeStage(battle, target, stat, -1, false)
  end
end

local function flinchSide(chance)
  return function(battle, user, target)
    if target.substituteHP then return {} end
    if battle.rng(0, 255) < chance then
      target.flinched = true
    end
    return {}
  end
end

local function confuse(battle, target, pierceSub)
  if target.confusedTurns or (target.substituteHP and not pierceSub) then
    return { "But, it failed!" }
  end
  target.confusedTurns = battle.rng(2, 5)
  return { ("%s\nbecame confused!"):format(displayName(target)) }
end

-- ---------------------------------------------------------------------
-- primary (status-only move) handlers
-- ---------------------------------------------------------------------

MoveEffects.primary = {
  ATTACK_UP1_EFFECT = statUp("attack", 1),
  ATTACK_UP2_EFFECT = statUp("attack", 2),
  DEFENSE_UP1_EFFECT = statUp("defense", 1),
  DEFENSE_UP2_EFFECT = statUp("defense", 2),
  SPEED_UP2_EFFECT = statUp("speed", 2),
  SPECIAL_UP1_EFFECT = statUp("special", 1),
  SPECIAL_UP2_EFFECT = statUp("special", 2),
  EVASION_UP1_EFFECT = statUp("evasion", 1),

  ATTACK_DOWN1_EFFECT = statDown("attack", 1),
  DEFENSE_DOWN1_EFFECT = statDown("defense", 1),
  DEFENSE_DOWN2_EFFECT = statDown("defense", 2),
  SPEED_DOWN1_EFFECT = statDown("speed", 1),
  ACCURACY_DOWN1_EFFECT = statDown("accuracy", 1),

  SLEEP_EFFECT = statusMove("SLP"),
  POISON_EFFECT = statusMove("PSN"),
  PARALYZE_EFFECT = statusMove("PAR"),

  CONFUSION_EFFECT = function(battle, user, target)
    return confuse(battle, target)
  end,

  LEECH_SEED_EFFECT = function(battle, user, target)
    -- leech_seed.asm has no substitute check: seeding lands through one
    if target.leechSeeded then
      return { "But, it failed!" }
    end
    for _, t in ipairs(target.curTypes) do
      if t == "GRASS" then return { "But, it failed!" } end
    end
    target.leechSeeded = true
    return { ("%s\nwas seeded!"):format(displayName(target)) }
  end,

  HEAL_EFFECT = function(battle, user, target, move)
    local mon = user.mon
    if move.id == "REST" then
      if mon.hp == mon.stats.hp then return { "But, it failed!" } end
      mon.hp = mon.stats.hp
      mon.status = "SLP"
      user.sleepTurns = 2
      user.toxicCounter = nil
      return { ("%s\nstarted sleeping!"):format(displayName(user)) }
    end
    if mon.hp == mon.stats.hp then return { "But, it failed!" } end
    mon.hp = math.min(mon.stats.hp, mon.hp + math.floor(mon.stats.hp / 2))
    return { ("%s\nregained health!"):format(displayName(user)) }
  end,

  LIGHT_SCREEN_EFFECT = function(battle, user)
    if user.lightScreen then return { "But, it failed!" } end
    user.lightScreen = true
    return { ("%s's\nprotected against\nspecial attacks!"):format(displayName(user)) }
  end,

  REFLECT_EFFECT = function(battle, user)
    if user.reflect then return { "But, it failed!" } end
    user.reflect = true
    return { ("%s\ngained armor!"):format(displayName(user)) }
  end,

  MIST_EFFECT = function(battle, user)
    if user.mist then return { "But, it failed!" } end
    user.mist = true
    -- _ShroudedInMistText (lowercase "mist")
    return { ("%s's\nshrouded in mist!"):format(displayName(user)) }
  end,

  FOCUS_ENERGY_EFFECT = function(battle, user)
    if user.focusEnergy then return { "But, it failed!" } end
    user.focusEnergy = true
    return { ("%s's\ngetting pumped!"):format(displayName(user)) }
  end,

  HAZE_EFFECT = function(battle, user, target)
    for _, b in ipairs({ user, target }) do
      b.stages = {}
      b.confusedTurns = nil
      b.leechSeeded = nil
      b.toxicCounter = nil
      b.reflect, b.lightScreen, b.mist, b.focusEnergy = nil, nil, nil, nil
      -- haze.asm also zeroes both disabled-move slots and clears
      -- USING_X_ACCURACY on both sides
      b.disabledSlot, b.disabledTurns = nil, nil
      b.xAccuracy = nil
      -- haze.asm ResetStats copies each side's UNMODIFIED stats (8 bytes,
      -- not HP) over its battle stats, which temporarily lifts the burn
      -- Attack-halving and paralysis Speed-quartering on BOTH battlers
      -- until the next stat recompute (a stage change or switch-in).
      b.hazeStatReset = true
    end
    -- Gen 1 also removes the enemy's major status; if that cured sleep
    -- or freeze, the target forfeits its move this turn (haze.asm
    -- writes $ff/CANNOT_MOVE to its selected move)
    if target.mon.status == "SLP" or target.mon.status == "FRZ" then
      target.skipMove = true
    end
    target.mon.status = nil
    return { "All STATUS changes\nare eliminated!" }
  end,

  SUBSTITUTE_EFFECT = function(battle, user)
    if user.substituteHP then return { ("%s\nhas a SUBSTITUTE!"):format(displayName(user)) } end
    local cost = math.floor(user.mon.stats.hp / 4)
    -- substitute.asm only fails on subtraction underflow (current HP
    -- strictly below maxHP/4); at equality the substitute is built and
    -- the user is left standing on exactly 0 HP (it faints only when
    -- the engine next checks HP, not here)
    if user.mon.hp < cost then
      return { "Too weak to make\na SUBSTITUTE!" }
    end
    user.mon.hp = user.mon.hp - cost
    user.substituteHP = cost + 1
    -- _SubstituteText
    return { "It created a\nSUBSTITUTE!" }
  end,

  CONVERSION_EFFECT = function(battle, user, target)
    -- conversion.asm fails against a mid-Fly/Dig target (INVULNERABLE)
    if target.invulnerable then
      return { "But, it failed!" }
    end
    user.curTypes = { target.curTypes[1], target.curTypes[2] }
    -- _ConvertedTypeText
    return { ("Converted type to\n%s's!"):format(displayName(target)) }
  end,

  -- MIMIC_EFFECT lives in BattleState:resolveMimic: MimicEffect
  -- (effects.asm:1203-1273) runs mid-move -- hit test first, then the
  -- player's copy menu pauses the message queue, which a table of
  -- returned strings can't express.

  TRANSFORM_EFFECT = function(battle, user, target)
    -- transform.asm:31-53 (AnimationTransformMon) morphs the user's
    -- on-screen pic into the target species; the port swaps user.sprite
    -- via the same getImage/monPalette path makeBattler uses so the
    -- change is visible (the renderer draws battler.sprite directly).
    user.sprite = battle:speciesSprite(target.mon.species, user.isPlayer)
                  or user.sprite
    user.curStats = {
      hp = user.mon.stats.hp, -- HP is kept
      attack = target.curStats.attack, defense = target.curStats.defense,
      speed = target.curStats.speed, special = target.curStats.special,
    }
    user.curTypes = { target.curTypes[1], target.curTypes[2] }
    -- transform.asm:130-132 copies the target's stat MODS into the user
    -- (wEnemyMonStatMods -> wPlayerMonStatMods), it does NOT clear them;
    -- deep copy so later stage changes on either mon stay independent
    user.stages = {}
    for stat, stage in pairs(target.stages) do user.stages[stat] = stage end
    user.curMoves = {}
    for _, mv in ipairs(target.curMoves) do
      table.insert(user.curMoves, { id = mv.id, pp = 5, mimic = true })
    end
    -- _TransformedText: the copied name prints bare (wNameBuffer)
    return { ("%s\ntransformed into\n%s!"):format(displayName(user), target.name) }
  end,

  DISABLE_EFFECT = function(battle, user, target)
    if target.disabledSlot then return { "But, it failed!" } end
    local usable = {}
    for i, mv in ipairs(target.curMoves) do
      if mv.pp > 0 then table.insert(usable, i) end
    end
    if #usable == 0 then return { "But, it failed!" } end
    local slot = usable[battle.rng(1, #usable)]
    target.disabledSlot = slot
    target.disabledTurns = battle.rng(1, 8)
    local id = target.curMoves[slot].id
    -- _MoveWasDisabledText: "X's / MOVE was / disabled!"
    return { ("%s's\n%s was\ndisabled!"):format(displayName(target),
                                                battle.data.moves[id].name) }
  end,

  SPLASH_EFFECT = function()
    return { "No effect!" }
  end,
}

-- ---------------------------------------------------------------------
-- secondary (after-damage) side effects
-- ---------------------------------------------------------------------

MoveEffects.secondary = {
  BURN_SIDE_EFFECT1 = statusSide("BRN", 26),
  BURN_SIDE_EFFECT2 = statusSide("BRN", 77),
  FREEZE_SIDE_EFFECT1 = statusSide("FRZ", 26),
  PARALYZE_SIDE_EFFECT1 = statusSide("PAR", 26),
  PARALYZE_SIDE_EFFECT2 = statusSide("PAR", 77),
  POISON_SIDE_EFFECT1 = statusSide("PSN", 52),
  POISON_SIDE_EFFECT2 = statusSide("PSN", 103),
  FLINCH_SIDE_EFFECT1 = flinchSide(26),
  FLINCH_SIDE_EFFECT2 = flinchSide(77),
  ATTACK_DOWN_SIDE_EFFECT = statDownSide("attack"),
  DEFENSE_DOWN_SIDE_EFFECT = statDownSide("defense"),
  SPEED_DOWN_SIDE_EFFECT = statDownSide("speed"),
  SPECIAL_DOWN_SIDE_EFFECT = statDownSide("special"),
  CONFUSION_SIDE_EFFECT = function(battle, user, target)
    if target.confusedTurns then return {} end
    -- cp 10 percent (no +1): 25/256; ConfusionSideEffect never calls
    -- CheckTargetSubstitute, so secondary confusion pierces a substitute
    if battle.rng(0, 255) >= 25 then return {} end
    return confuse(battle, target, true)
  end,
  TWINEEDLE_EFFECT = function(battle, user, target)
    -- the second hit reroutes to PoisonEffect with POISON_SIDE_EFFECT1:
    -- 20 percent + 1 (52/256)
    if battle.rng(0, 255) >= 52 then return {} end
    return inflictStatus(battle, target, "PSN", { secondary = true })
  end,
}

-- effects fully handled inside BattleState's damage pipeline
MoveEffects.special = {
  NO_ADDITIONAL_EFFECT = true, TWO_TO_FIVE_ATTACKS_EFFECT = true,
  ATTACK_TWICE_EFFECT = true, SPECIAL_DAMAGE_EFFECT = true,
  SUPER_FANG_EFFECT = true, OHKO_EFFECT = true, RECOIL_EFFECT = true,
  DRAIN_HP_EFFECT = true, DREAM_EATER_EFFECT = true, CHARGE_EFFECT = true,
  FLY_EFFECT = true, TRAPPING_EFFECT = true, THRASH_PETAL_DANCE_EFFECT = true,
  JUMP_KICK_EFFECT = true, EXPLODE_EFFECT = true, HYPER_BEAM_EFFECT = true,
  PAY_DAY_EFFECT = true, SWIFT_EFFECT = true, RAGE_EFFECT = true,
  BIDE_EFFECT = true, SWITCH_AND_TELEPORT_EFFECT = true,
  METRONOME_EFFECT = true, MIRROR_MOVE_EFFECT = true,
  TWINEEDLE_EFFECT = true, MIMIC_EFFECT = true,
}

local warned = {}

function MoveEffects.warnUnknown(effect)
  if not warned[effect] then
    warned[effect] = true
    Logger.warn("move effect %s not implemented; treated as plain damage", effect)
  end
end

return MoveEffects
