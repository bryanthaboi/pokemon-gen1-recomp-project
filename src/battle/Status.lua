-- Per-turn status/volatile condition handling (Gen 1 semantics).

local Status = {}

-- Returns canMove, messages, selfHit (true -> hurt itself in confusion)
function Status.beforeMove(battler, rng)
  local mon = battler.mon
  -- Haze curing this mon's sleep/freeze forfeits its pending move for
  -- the turn, silently (haze.asm writes $ff/CANNOT_MOVE to the selected
  -- move; ExecuteMove returns immediately without a message)
  if battler.skipMove then
    battler.skipMove = nil
    return false, {}
  end
  if battler.flinched then
    battler.flinched = false
    return false, { battler.name .. "\nflinched!" }
  end
  if mon.status == "SLP" then
    battler.sleepTurns = (battler.sleepTurns or 1) - 1
    if battler.sleepTurns <= 0 then
      mon.status = nil
      return false, { battler.name .. "\nwoke up!" } -- wakes but loses the turn
    end
    return false, { battler.name .. "\nis fast asleep!" }
  end
  if mon.status == "FRZ" then
    return false, { battler.name .. "\nis frozen solid!" }
  end
  if battler.boundTurns and battler.boundTurns > 0 then
    battler.boundTurns = battler.boundTurns - 1
    return false, { battler.name .. "\ncan't move!" }
  end
  local msgs = {}
  if battler.disabledTurns then
    battler.disabledTurns = battler.disabledTurns - 1
    if battler.disabledTurns <= 0 then
      battler.disabledTurns, battler.disabledSlot = nil, nil
      table.insert(msgs, battler.name .. "'s\ndisabled no more!")
    end
  end
  if battler.confusedTurns then
    battler.confusedTurns = battler.confusedTurns - 1
    if battler.confusedTurns <= 0 then
      battler.confusedTurns = nil
      table.insert(msgs, battler.name .. "\nsnapped out of\nconfusion!")
    else
      table.insert(msgs, battler.name .. "\nis confused!")
      -- cp 50 percent + 1 / jr c: hurt itself on rand >= 128 (128/256)
      if rng(0, 255) < 128 then
        return false, msgs, true -- hurt itself
      end
    end
  end
  -- cp 25 percent / jr nc: fully paralyzed on rand < 63 (63/256)
  if mon.status == "PAR" and rng(0, 255) < 63 then
    table.insert(msgs, battler.name .. "'s\nfully paralyzed!")
    return false, msgs
  end
  return true, msgs
end

-- End-of-turn residual damage; opponent is needed for Leech Seed.
-- Returns messages.
function Status.residual(battler, opponent)
  local msgs = {}
  local mon = battler.mon
  -- the Haze move-forfeit only covers the turn Haze was used; if this
  -- mon had already moved, drop the flag before it leaks into next turn
  battler.skipMove = nil
  if mon.hp <= 0 then return msgs end
  if mon.status == "PSN" or mon.status == "BRN" then
    local base = math.max(1, math.floor(mon.stats.hp / 16))
    local dmg = base
    if battler.toxicCounter then
      dmg = base * battler.toxicCounter
      battler.toxicCounter = battler.toxicCounter + 1
    end
    mon.hp = math.max(0, mon.hp - dmg)
    local what = mon.status == "PSN" and "poison" or "the burn"
    table.insert(msgs, ("%s's\nhurt by %s!"):format(battler.name, what))
  end
  if battler.leechSeeded and mon.hp > 0 and opponent.mon.hp > 0 then
    -- the shared Toxic counter multiplies (and advances on) the seed
    -- drain too -- the Gen 1 Leech Seed glitch
    -- (HandlePoisonBurnLeechSeed_DecreaseOwnHP)
    local dmg = math.max(1, math.floor(mon.stats.hp / 16))
    if battler.toxicCounter then
      dmg = dmg * battler.toxicCounter
      battler.toxicCounter = battler.toxicCounter + 1
    end
    dmg = math.min(dmg, mon.hp)
    mon.hp = mon.hp - dmg
    opponent.mon.hp = math.min(opponent.mon.stats.hp, opponent.mon.hp + dmg)
    table.insert(msgs, ("LEECH SEED saps\n%s!"):format(battler.name))
  end
  return msgs
end

return Status
