-- Parity test,  Workstream L.
-- Self-contained: run via `luajit tests/parity_L.lua`; also dofile'd by
-- tests/run_tests.lua's aggregator.
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end
local S = require("tests.harness").suite("parity L")
local check, eq = S.check, S.eq

local MoveEffects = require("src.battle.MoveEffects")
local Damage      = require("src.battle.Damage")
local TurnOrder   = require("src.battle.TurnOrder")
local TypeChart   = require("src.battle.TypeChart")
-- TypeChart is normally loaded by BattleState.newBattle; Damage.compute
-- needs its matchup index, so wire it up directly for this unit test.
TypeChart.load(Data)

-- Minimal battler factory covering every volatile Haze touches.
local function battler(o)
  o = o or {}
  return {
    stages       = o.stages or {},
    confusedTurns = o.confusedTurns,
    leechSeeded  = o.leechSeeded,
    toxicCounter = o.toxicCounter,
    reflect      = o.reflect,
    lightScreen  = o.lightScreen,
    mist         = o.mist,
    focusEnergy  = o.focusEnergy,
    disabledSlot = o.disabledSlot,
    disabledTurns = o.disabledTurns,
    xAccuracy    = o.xAccuracy,
    mon          = o.mon or {},
    curStats     = o.curStats,
    curTypes     = o.curTypes,
    badges       = o.badges,
    name         = o.name or "MON",
  }
end

-- =====================================================================
-- (A) Already-faithful Haze cells (haze.asm HazeEffect_ / CureVolatileStatuses)
-- =====================================================================

-- The USER carries every clearable volatile plus a *badly*-poisoned status.
local u = battler{
  stages = { attack = 3, defense = -2, speed = 1, special = 4, accuracy = 2, evasion = -1 },
  confusedTurns = 5, leechSeeded = true, toxicCounter = 3,
  reflect = true, lightScreen = true, mist = true, focusEnergy = true,
  disabledSlot = 2, disabledTurns = 4, xAccuracy = true,
  mon = { status = "PSN" }, name = "USER",
}
-- The TARGET is asleep and also carries volatiles, to prove both sides clear.
local t = battler{
  stages = { defense = 2, speed = -3 },
  confusedTurns = 4, leechSeeded = true, toxicCounter = 6,
  reflect = true, lightScreen = true, mist = true, focusEnergy = true,
  disabledSlot = 1, disabledTurns = 2, xAccuracy = true,
  mon = { status = "SLP" }, name = "TARGET",
}
local msg = MoveEffects.primary.HAZE_EFFECT(nil, u, t)

check(next(u.stages) == nil, "Haze clears all of the user's stat stages")
check(next(t.stages) == nil, "Haze clears all of the target's stat stages")

local function volatilesCleared(b, who)
  check(b.confusedTurns == nil, who .. ": confusion cleared")
  check(b.leechSeeded  == nil, who .. ": leech seed cleared")
  check(b.toxicCounter == nil, who .. ": badly-poisoned bit cleared (toxic -> regular)")
  check(b.reflect      == nil, who .. ": reflect cleared")
  check(b.lightScreen  == nil, who .. ": light screen cleared")
  check(b.mist         == nil, who .. ": mist cleared")
  check(b.focusEnergy  == nil, who .. ": focus energy cleared")
  check(b.disabledSlot == nil, who .. ": disabled slot cleared")
  check(b.disabledTurns == nil, who .. ": disabled turns cleared")
  check(b.xAccuracy    == nil, who .. ": X ACCURACY cleared")
end
volatilesCleared(u, "user")
volatilesCleared(t, "target")

-- User's own non-volatile status is intentionally KEPT (haze.asm cures the
-- target only); the badly-poisoned USER reverts to regular poison.
eq(u.mon.status, "PSN", "user's own major status is kept (still poisoned)")
-- Target's major status is cured; its SLP forfeits the move this turn.
eq(t.mon.status, nil, "target's major status is cured")
check(t.skipMove == true, "curing target's sleep forfeits its move (skipMove)")
eq(msg[1], "All STATUS changes\nare eliminated!", "Haze prints the elimination text")

-- FRZ target also forfeits its move.
local frz = battler{ mon = { status = "FRZ" }, name = "FROZEN" }
MoveEffects.primary.HAZE_EFFECT(nil, battler{ mon = {} }, frz)
eq(frz.mon.status, nil, "target's freeze is cured")
check(frz.skipMove == true, "curing target's freeze forfeits its move")

-- Badly-poisoned TARGET: status cured, no forfeit, toxic counter gone.
local psnT = battler{ mon = { status = "PSN" }, toxicCounter = 4, name = "PSN_T" }
MoveEffects.primary.HAZE_EFFECT(nil, battler{ mon = {} }, psnT)
eq(psnT.mon.status, nil, "badly-poisoned target is fully cured of poison")
check(psnT.toxicCounter == nil, "badly-poisoned target's toxic counter cleared")
check(not psnT.skipMove, "curing poison does NOT forfeit the target's move")

-- BRN / PAR targets: cured, no forfeit.
for _, st in ipairs({ "BRN", "PAR" }) do
  local tb = battler{ mon = { status = st }, name = st }
  MoveEffects.primary.HAZE_EFFECT(nil, battler{ mon = {} }, tb)
  eq(tb.mon.status, nil, "target's " .. st .. " is cured")
  check(not tb.skipMove, st .. " target keeps its move (no sleep/freeze forfeit)")
end

-- A burned USER keeps its own burn (status not the one Haze cures).
local burnedUser = battler{ mon = { status = "BRN" }, name = "BURNER" }
MoveEffects.primary.HAZE_EFFECT(nil, burnedUser, battler{ mon = {} })
eq(burnedUser.mon.status, "BRN", "user's own burn is not cured by Haze")

-- =====================================================================
-- (B) New quirk: Haze temporarily lifts the burn Attack-halving
--     (haze.asm ResetStats copies unmodified stats over battle stats).
-- =====================================================================

local ruleset = { randMin = 255, randMax = 255 }  -- identity random factor
local move = { id = "TACKLE", type = "NORMAL", power = 80 } -- physical
local rng = function(_, b) return b end
local defender = {
  curStats = { attack = 50, defense = 50, special = 50, speed = 50, hp = 100 },
  stages = {}, curTypes = { "NORMAL" },
  mon = { level = 50, stats = { hp = 100 } }, name = "DEF",
}
local function attacker(status, hz)
  return {
    curStats = { attack = 100, defense = 50, special = 50, speed = 50, hp = 100 },
    stages = {}, curTypes = { "WATER" }, -- WATER so a NORMAL move gets no STAB
    mon = { status = status, level = 50, stats = { hp = 100 } },
    hazeStatReset = hz, name = "ATK",
  }
end
local opts = { forceCrit = false, rng = rng }
local dHealthy   = Damage.compute(ruleset, attacker(nil,  nil),  defender, move, opts)
local dBurnedRaw = Damage.compute(ruleset, attacker("BRN", nil),  defender, move, opts)
local hazedAtk   = attacker("BRN", true)
local dBurnedHaze = Damage.compute(ruleset, hazedAtk, defender, move, opts)

check(dBurnedRaw < dHealthy, "burn halves a burned mon's physical damage (sanity)")
eq(dBurnedHaze, dHealthy, "Haze lifts the burn Attack-halving (damage == unburned)")

-- A stat-stage change re-bakes the penalty (effects.asm:505-506). Bump the
-- attacker's DEFENSE (irrelevant to its own offense) so only hazeStatReset flips.
MoveEffects.primary.DEFENSE_UP1_EFFECT(nil, hazedAtk, nil)
check(hazedAtk.hazeStatReset == nil, "a stat-stage change re-arms the burn penalty")
local dAfter = Damage.compute(ruleset, hazedAtk, defender, move, opts)
eq(dAfter, dBurnedRaw, "burn Attack-halving returns after the stage change")

-- =====================================================================
-- (C) New quirk: Haze temporarily lifts the paralysis Speed-quartering.
-- =====================================================================

local para = battler{
  curStats = { speed = 100, attack = 50, defense = 50, special = 50, hp = 100 },
  mon = { status = "PAR", level = 50, stats = { hp = 100 } }, name = "PARA",
}
eq(TurnOrder.effectiveSpeed(para), 25, "paralysis quarters speed before Haze (100 -> 25)")
MoveEffects.primary.HAZE_EFFECT(nil, para, battler{ mon = {} })
eq(TurnOrder.effectiveSpeed(para), 100, "Haze lifts paralysis Speed-quartering")
-- Re-arm via an ATTACK stage change (irrelevant to the speed calc).
MoveEffects.primary.ATTACK_UP1_EFFECT(nil, para, nil)
check(para.hazeStatReset == nil, "stage change re-arms the paralysis penalty")
eq(TurnOrder.effectiveSpeed(para), 25, "Speed-quartering resumes after the stage change")

S.finish()
