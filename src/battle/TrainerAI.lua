-- Trainer/wild move selection with the per-class "move choice
-- modification" layers from data/trainers/move_choices.asm
-- (engine/battle/trainer_ai.asm):
--   mod 1: heavily discourage zero-power status-ailment moves when the
--          player already has a status condition (they would fail)
--   mod 2: encourage stat-modifying (and neighbouring) move effects,
--          but only on the second move selection per enemy mon
--          (wAILayer2Encouragement == 1)
--   mod 3: encourage moves whose type is super effective against the
--          player (even non-damaging ones), discourage not-very-
--          effective/no-effect types when a "better move" is known
-- Faithful port of AIEnemyTrainerChooseMoves
-- (engine/battle/trainer_ai.asm:3-257): every candidate move starts at a
-- base score of 10; mod 1 adds 5, mod 2 subtracts 1, mod 3 subtracts 1
-- (super-effective) or adds 1 (not-effective when a better move exists);
-- the MINIMUM-scored move is chosen, ties broken uniformly among the
-- tied minima (core.asm:2971-3002).  A non-minimal move is never
-- selectable.  Respects PP, Disable and Transform/Mimic move overrides.

local TypeChart = require("src.battle.TypeChart")

local TrainerAI = {}

local HEAL_AMOUNT = { POTION = 20, SUPER_POTION = 50, HYPER_POTION = 200 }
local X_STAT = { X_ATTACK = "attack", X_DEFEND = "defense", X_SPEED = "speed" }

-- Item use / switching per trainer class (engine/battle/trainer_ai.asm
-- via data/scripts/ai_classes.lua).  Runs before move choice each enemy
-- turn; returns an action { special = "aiItem"/"aiSwitch", ... } or nil.
-- battle.aiUses is initialized per enemy Pokémon (wAICount).
function TrainerAI.classAction(battle)
  if battle.kind ~= "trainer" or not battle.trainer then return nil end
  local class = require("data.scripts.ai_classes")[battle.trainer.id]
  if not class then return nil end
  if (battle.aiUses or 0) <= 0 then return nil end
  local rng = battle.rng
  local enemy = battle.enemy
  local roll = rng(0, 255)

  -- Agatha's dedicated switch roll comes before her item roll
  if class.switchChance and roll < class.switchChance then
    return TrainerAI.switchAction(battle)
  end

  if class.onStatus then
    if enemy.mon.status then
      return { special = "aiItem", item = class.item }
    end
    return nil
  end

  if class.chance and roll >= class.chance then return nil end

  if class.switch then
    return TrainerAI.switchAction(battle)
  end
  if class.hpBelow
     and enemy.mon.hp >= math.floor(enemy.mon.stats.hp / class.hpBelow) then
    if class.switchBelow
       and enemy.mon.hp < math.floor(enemy.mon.stats.hp / class.switchBelow) then
      return TrainerAI.switchAction(battle)
    end
    return nil
  end
  return { special = "aiItem", item = class.item }
end

-- AISwitchIfEnoughMons (engine/battle/trainer_ai.asm:554-582): counts ALL
-- unfainted party mons including the active one and switches when that
-- total is >= 2 (cp 2 / jp nc) -- i.e. whenever at least ONE non-active
-- mon can still fight.  Switch to the first (lowest-index) such backup,
-- matching EnemySendOutFirstMon (core.asm:1292-1341).
function TrainerAI.switchAction(battle)
  local alive = {}
  for i, mon in ipairs(battle.enemyParty or {}) do
    if mon.hp > 0 and i ~= battle.enemyIndex then
      table.insert(alive, i)
    end
  end
  if #alive < 1 then return nil end
  return { special = "aiSwitch", index = alive[1] }
end

-- Apply an aiItem action to the enemy battler; returns messages.
function TrainerAI.useItem(battle, item)
  local enemy = battle.enemy
  local trainerName = battle.trainer.name
  local itemName = battle.data.items[item] and battle.data.items[item].name or item
  local msgs = { ("%s\nused %s!"):format(trainerName, itemName) }
  if item == "FULL_HEAL" then
    enemy.mon.status = nil
    enemy.toxicCounter = nil
  elseif item == "FULL_RESTORE" then
    enemy.mon.hp = enemy.mon.stats.hp
    enemy.mon.status = nil
    enemy.toxicCounter = nil
  elseif HEAL_AMOUNT[item] then
    enemy.mon.hp = math.min(enemy.mon.stats.hp, enemy.mon.hp + HEAL_AMOUNT[item])
  elseif X_STAT[item] then
    local stat = X_STAT[item]
    enemy.stages[stat] = math.min(6, (enemy.stages[stat] or 0) + 1)
    table.insert(msgs, ("%s's\n%s rose!"):format(enemy.name, stat:upper()))
  elseif item == "GUARD_SPEC" then
    enemy.mist = true
    table.insert(msgs, ("%s's\nprotected against\nstat changes!"):format(enemy.name))
  end
  return msgs
end

-- AIMoveChoiceModification1's StatusAilmentMoveEffects table: the two
-- sleep effects (EFFECT_01 is the unused one), poison and paralysis.
local STATUS_EFFECTS = {
  EFFECT_01 = true, SLEEP_EFFECT = true, POISON_EFFECT = true,
  PARALYZE_EFFECT = true,
}

-- AIMoveChoiceModification2 encourages the two effect ranges
-- ATTACK_UP1_EFFECT..BIDE_EFFECT and ATTACK_UP2_EFFECT..POISON_EFFECT
-- (both exclusive of the upper bound): every stat modifier plus the
-- effects laid out between them in the constant list.
local ENCOURAGE_EFFECTS = {
  -- $0A ATTACK_UP1_EFFECT .. $19 HAZE_EFFECT
  ATTACK_UP1_EFFECT = true, DEFENSE_UP1_EFFECT = true, SPEED_UP1_EFFECT = true,
  SPECIAL_UP1_EFFECT = true, ACCURACY_UP1_EFFECT = true, EVASION_UP1_EFFECT = true,
  PAY_DAY_EFFECT = true, SWIFT_EFFECT = true,
  ATTACK_DOWN1_EFFECT = true, DEFENSE_DOWN1_EFFECT = true, SPEED_DOWN1_EFFECT = true,
  SPECIAL_DOWN1_EFFECT = true, ACCURACY_DOWN1_EFFECT = true, EVASION_DOWN1_EFFECT = true,
  CONVERSION_EFFECT = true, HAZE_EFFECT = true,
  -- $32 ATTACK_UP2_EFFECT .. $41 REFLECT_EFFECT
  ATTACK_UP2_EFFECT = true, DEFENSE_UP2_EFFECT = true, SPEED_UP2_EFFECT = true,
  SPECIAL_UP2_EFFECT = true, ACCURACY_UP2_EFFECT = true, EVASION_UP2_EFFECT = true,
  HEAL_EFFECT = true, TRANSFORM_EFFECT = true,
  ATTACK_DOWN2_EFFECT = true, DEFENSE_DOWN2_EFFECT = true, SPEED_DOWN2_EFFECT = true,
  SPECIAL_DOWN2_EFFECT = true, ACCURACY_DOWN2_EFFECT = true, EVASION_DOWN2_EFFECT = true,
  LIGHT_SCREEN_EFFECT = true, REFLECT_EFFECT = true,
}

-- AIMoveChoiceModification3 .betterMoveFound: a "better move" is any
-- known move (PP and Disable ignored) with the Super Fang, fixed-damage
-- or Fly effect, or any damaging move of a different type than the move
-- being judged.
local BETTER_EFFECTS = {
  SUPER_FANG_EFFECT = true, SPECIAL_DAMAGE_EFFECT = true, FLY_EFFECT = true,
}

local function hasBetterMove(battler, judged, battle)
  for _, mv in ipairs(battler.curMoves) do
    local d = battle.data.moves[mv.id]
    if d then
      if BETTER_EFFECTS[d.effect] then return true end
      if d.type ~= judged.type and d.power > 0 then return true end
    end
  end
  return false
end

function TrainerAI.chooseMove(battler, rng, battle)
  rng = rng or love.math.random
  local usable = {}
  for i, mv in ipairs(battler.curMoves) do
    if mv.pp > 0 and battler.disabledSlot ~= i then
      table.insert(usable, mv)
    end
  end
  if #usable == 0 then
    return { id = "STRUGGLE", pp = 1, struggle = true }
  end

  -- wAILayer2Encouragement starts at 0 on each enemy send-out and gains
  -- 1 per executed enemy move, so layer 2 (which needs it == 1) only
  -- fires on the second move selection of each enemy mon.  The port
  -- counts selections instead of executions; they only diverge across
  -- turns locked into a multi-turn move, which skip selection entirely.
  local encourageTurn = (battler.aiLayer2 or 0) == 1
  battler.aiLayer2 = (battler.aiLayer2 or 0) + 1

  local mods = battle and battle.enemyAIMods or nil
  if not mods or #mods == 0 or not battle then
    return usable[rng(1, #usable)]
  end

  -- AIEnemyTrainerChooseMoves (engine/battle/trainer_ai.asm:3-257): every
  -- usable move starts at a base score of 10; the class's modification
  -- functions adjust it additively, then the MINIMUM-scored move is chosen
  -- with ties broken uniformly among the minima (core.asm:2971-3002 rolls a
  -- fresh byte among the value-1 slots).  A non-minimal move is never
  -- selectable.
  local target = battle.player
  local scores = {}
  for i, mv in ipairs(usable) do
    local def = battle.data.moves[mv.id]
    local s = 10
    for _, mod in ipairs(mods) do
      if mod == 1 and def and target.mon.status
         and def.power == 0 and STATUS_EFFECTS[def.effect] then
        -- AIMoveChoiceModification1: `add $5` -- heavily discourage a
        -- zero-power status move that would fail (player already statused)
        s = s + 5
      elseif mod == 2 and def and encourageTurn
         and ENCOURAGE_EFFECTS[def.effect] then
        -- AIMoveChoiceModification2: `dec [hl]` -- slightly encourage
        s = s - 1
      elseif mod == 3 and def then
        -- AIMoveChoiceModification3 via AIGetTypeEffectiveness only reads
        -- the FIRST matching TypeEffects row for (move type vs either
        -- defender type) -- no dual-type product -- and runs for
        -- non-damaging moves too.  The table holds no value-10 rows, so
        -- >10 / <10 reproduces the oracle's compare against $10.
        local row = TypeChart.rows(def.type, target.curTypes)[1]
        if row and row > 10 then
          s = s - 1 -- `dec [hl]`: encourage a super-effective move
        elseif row and row < 10 and hasBetterMove(battler, def, battle) then
          s = s + 1 -- `inc [hl]`: discourage when a better move is known
        end
      end
    end
    scores[i] = s
  end
  local best = math.huge
  for _, s in ipairs(scores) do
    if s < best then best = s end
  end
  local minima = {}
  for i, s in ipairs(scores) do
    if s == best then minima[#minima + 1] = usable[i] end
  end
  if #minima == 1 then return minima[1] end
  return minima[rng(1, #minima)]
end

return TrainerAI
