-- The move-effect execution surface: the ctx facade handed to every
-- move_effects record callback, and the staged damaging pipeline that
-- performMove drives through the record's stage fields
-- (gate/neverMiss/hitCount/beforeAccuracy/chooseDamage/onMiss/afterDamage
-- plus the post-damage secondary run).  The ctx is the only supported
-- surface handlers receive; everything else is engine-internal.

local MoveEffects = require("src.battle.MoveEffects")
local Runtime = require("src.mods.Runtime")
local StatusRegistry = require("src.battle.StatusRegistry")

local EffectRegistry = {}

-- pokered's <USER>/<TARGET> text macros print "Enemy " before the enemy
-- mon's nickname (home/text.asm PlaceMoveUsersName)
local function displayName(b)
  return b.isPlayer and b.name or ("Enemy " .. b.name)
end
EffectRegistry.displayName = displayName

-- built once per performMove call; closes over the battle
function EffectRegistry.makeCtx(battle, user, target, move, moveInst, isCalled)
  local ctx
  ctx = {
    battle = battle, data = battle.data, rng = battle.rng,
    ruleset = battle.ruleset,
    user = user, target = target, move = move, moveInst = moveInst,
    isCalled = isCalled or false,
    field = battle.field,
    displayName = displayName,
    say = function(text) battle:sayNext(text) end,
    sayNext = function(text) battle:sayNext(text) end,
    anim = function(animName, isPlayer)
      battle:animNext(animName, isPlayer == nil and user.isPlayer or isPlayer)
    end,
    drain = function() battle:drainNext() end,
    -- applyDamage plus the faint queue, like the crash/self-hit paths
    damage = function(who, amount)
      local dealt = battle:applyDamage(who, amount)
      if who.mon.hp <= 0 then battle:onFaint(who) end
      return dealt
    end,
    inflict = function(who, statusId, opts)
      return StatusRegistry.inflict(battle, who, statusId, opts)
    end,
    cure = function(who)
      who.mon.status = nil
      who.toxicCounter = nil
    end,
    changeStage = function(who, stat, delta, fromEnemy)
      return MoveEffects.changeStage(battle, who, stat, delta, fromEnemy)
    end,
    computeDamage = function(opts)
      return battle:computeDamage(user, target, move, opts)
    end,
    accuracyRoll = function()
      return battle:accuracyRoll(move, user, target)
    end,
    callMove = function(moveId)
      return battle:performMove(user, target, { id = moveId, pp = 1 }, true)
    end,
    side = function(who) return battle:sideOf(who) end,
  }
  return ctx
end

-- multi-hit count: the record's hitCount wins, then the move's multiHit
-- field, then a single hit
local function hitCount(ctx, record)
  if record and record.hitCount then
    return record.hitCount(ctx) or 1
  end
  local dist = ctx.move.multiHit
  if dist == nil then return 1 end
  if type(dist) == "number" then return dist end
  local r = ctx.rng(0, #dist - 1)
  return dist[r + 1]
end

-- The damaging pipeline, extracted from the performMove monolith: every
-- stage keeps the original's exact check order and rng consumption
-- (invulnerability -> gate -> hit count -> pre-accuracy -> accuracy ->
-- damage choice -> hits -> messages -> after-damage -> secondary run).
function EffectRegistry.runDamaging(battle, ctx, record)
  local user, target = ctx.user, ctx.target
  local move, moveInst = ctx.move, ctx.moveInst
  local neverMiss = record and record.neverMiss

  -- Swift ignores semi-invulnerability (MoveHitTest returns hit for
  -- SWIFT_EFFECT before the INVULNERABLE check)
  if target.invulnerable and not neverMiss then
    -- Explosion/Selfdestruct still animate on a miss (HandleIfPlayerMoveMissed)
    if not (record and record.explode) then battle:cancelMoveAnim() end
    battle:sayNext(("%s's\nattack missed!"):format(displayName(user)))
    return
  end

  -- OHKO speed gate, Dream Eater sleep gate
  if record and record.gate then
    local ok, failMsg = record.gate(ctx)
    if not ok then
      battle:cancelMoveAnim()
      if failMsg then battle:sayNext(failMsg) end
      return
    end
  end

  local hits = hitCount(ctx, record)

  if record and record.beforeAccuracy then record.beforeAccuracy(ctx) end

  if not neverMiss then
    if not battle:accuracyRoll(move, user, target) then
      -- Explosion/Selfdestruct still animate on a miss (HandleIfPlayerMoveMissed)
      if not (record and record.explode) then battle:cancelMoveAnim() end
      battle:sayNext(("%s's\nattack missed!"):format(displayName(user)))
      -- Jump Kick crash, Explode self-destruct
      if record and record.onMiss then record.onMiss(ctx, "accuracy") end
      user.trappingTurns = nil
      return
    end
  end

  -- damage per hit
  local dmg, info
  if move.id == "COUNTER" then
    -- HandleCounterMove: 2x the last damage dealt in battle, only if
    -- the opponent's last move was counterable with >0 power (and not
    -- Counter itself); wDamage is shared, so any last damage counts.
    -- counterable defaults to the Normal/Fighting whitelist.
    local lastId = target.lastMove
    local lm = lastId and lastId ~= "COUNTER" and battle.data.moves[lastId]
    local counterable = false
    if lm and (lm.power or 0) > 0 then
      if lm.counterable ~= nil then
        counterable = lm.counterable
      else
        counterable = lm.type == "NORMAL" or lm.type == "FIGHTING"
      end
    end
    if not counterable or (battle.lastDamage or 0) == 0 then
      battle:cancelMoveAnim()
      battle:sayNext(("%s's\nattack missed!"):format(displayName(user)))
      return
    end
    dmg = math.min(65535, battle.lastDamage * 2)
    info = { crit = false, typeMult = 10 }
  elseif record and record.chooseDamage then
    -- Counter/Super Fang/OHKO/fixed damage; (nil, msg) means the move
    -- failed with that text already chosen
    local chosen, extra = record.chooseDamage(ctx)
    if not chosen then
      battle:cancelMoveAnim()
      if extra then battle:sayNext(extra) end
      return
    end
    dmg, info = chosen, extra or { crit = false, typeMult = 10 }
  else
    dmg, info = battle:computeDamage(user, target, move,
      { rng = battle.rng, explode = (record and record.explode) or nil })
  end

  if info.typeMult == 0 then
    -- type immunity zeros damage and sets wMoveMissed in Gen 1, so no anim
    if not (record and record.explode) then battle:cancelMoveAnim() end
    battle:sayNext(("It doesn't affect\n%s!"):format(displayName(target)))
    if record and record.onMiss then record.onMiss(ctx, "immune") end
    return
  end
  if info.missed then
    -- 0.25x floored the damage to zero: the original registers a miss
    if not (record and record.explode) then battle:cancelMoveAnim() end
    battle:sayNext(("%s's\nattack missed!"):format(displayName(user)))
    if record and record.onMiss then record.onMiss(ctx, "floored") end
    return
  end
  battle.lastDamage = dmg -- wDamage (shared by both sides, read by Counter)

  -- the hit blink + damage sound ride the queue behind the animation:
  -- on the move's anim row when one was announced, else on a bare hit
  -- row (thrash/rage continuations), placed BEFORE the drain rows the
  -- hits loop inserts so the blink precedes the bar drain
  local hitRow = battle.moveAnimRow
  if not hitRow then
    battle.nextInsert = (battle.nextInsert or 0) + 1
    hitRow = { hitRow = true }
    table.insert(battle.queue, battle.nextInsert, hitRow)
  end

  local totalDealt = 0
  local landed, brokeSub = 0, false
  for h = 1, hits do
    if target.mon.hp <= 0 then break end
    local hadSub = target.substituteHP ~= nil
    local dealt = battle:applyDamage(target, dmg)
    totalDealt = totalDealt + dealt
    landed = h
    if Runtime.wants("battle.damage_dealt") then
      Runtime.emit("battle.damage_dealt", {
        battle = battle, user = user, target = target, move = move,
        damage = dealt, crit = info.crit, typeMult = info.typeMult,
      })
    end
    if hadSub and not target.substituteHP then
      -- AttackSubstitute: breaking the substitute ends a multi-hit move
      brokeSub = true
      break
    end
  end
  hits = landed > 0 and landed or hits
  if totalDealt > 0 then
    -- the original's per-hit sound: normal / super / not-very-effective
    local hitSfx = info.typeMult > 10 and "Super_Effective"
                   or info.typeMult < 10 and "Not_Very_Effective" or "Damage"
    hitRow.hit = { sfx = hitSfx,
                   blink = battle:animationsOn() and target or nil }
  end
  -- PrintCriticalOHKOText prints "Critical hit!"/"One-hit KO!" right
  -- after the damage lands, BEFORE DisplayEffectiveness (core.asm
  -- .moveDidNotMiss); the multi-hit count follows the last hit
  if info.crit then battle:sayNext("Critical hit!") end
  if info.ohko then battle:sayNext("One-hit KO!") end
  if info.typeMult > 10 then
    battle:sayNext("It's super\neffective!")
  elseif info.typeMult < 10 then
    battle:sayNext("It's not very\neffective...")
  end
  if hits > 1 then
    -- player: _MultiHitText; enemy: _HitXTimesText (always plural)
    if user.isPlayer then
      battle:sayNext(("Hit the enemy\n%d times!"):format(hits))
    else
      battle:sayNext(("Hit %d times!"):format(hits))
    end
  end

  -- post-damage effect bookkeeping (recoil/drain/trap/thrash/...)
  ctx.rawDamage, ctx.totalDealt = dmg, totalDealt
  ctx.brokeSub, ctx.hits = brokeSub, hits
  if record and record.afterDamage then
    record.afterDamage(ctx, totalDealt)
  elseif moveInst.struggle then
    -- struggle recoils even when its effect id resolves to no record
    local recoil = math.max(1, math.floor(dmg / 2))
    battle:sayNext(("%s's\nhit with recoil!"):format(displayName(user)))
    battle:applyDamage(user, recoil)
  end

  -- secondary side effects (blocked by fainting)
  if record and record.run and record.kind ~= "primary"
     and target.mon.hp > 0 and totalDealt > 0 then
    for _, m in ipairs(record.run(ctx)) do
      battle:sayNext(m)
    end
  end
  if record == nil then
    MoveEffects.warnUnknown(move.effect)
  end

  if target.mon.hp <= 0 then
    battle:onFaint(target)
  end
  if user.mon.hp <= 0 then
    battle:onFaint(user)
  end
end

return EffectRegistry
