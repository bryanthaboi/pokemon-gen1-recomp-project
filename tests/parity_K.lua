-- Parity test,  Workstream K.
-- Self-contained: run via `luajit tests/parity_K.lua`; also dofile'd by
-- tests/run_tests.lua's aggregator.
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end
local TypeChart = require("src.battle.TypeChart")
TypeChart.load(Data)
local TrainerAI = require("src.battle.TrainerAI")
local S = require("tests.harness").suite("parity K")
local check, eq = S.check, S.eq

local rngLo = function(a, b) return a end  -- picks first minimum
local rngHi = function(a, b) return b end  -- picks last minimum

-- === CASE mod1: base-10 additive scoring, MINIMUM selection ===
-- TOXIC (power 0, POISON_EFFECT) vs a statused player scores 10+5=15;
-- TACKLE scores 10.  The min-score move (TACKLE) is chosen deterministically
-- regardless of the RNG, and the discouraged status move is NEVER selectable.
do
  local aiMon = { curMoves = { { id = "TOXIC", pp = 10 }, { id = "TACKLE", pp = 10 } } }
  local aiBattle = { enemyAIMods = { 1 }, data = Data,
                     player = { mon = { status = "PAR" }, curTypes = { "NORMAL" } } }
  eq(TrainerAI.chooseMove(aiMon, rngLo, aiBattle).id, "TACKLE",
     "mod1: discouraged status move never wins (rng low)")
  local aiMon2 = { curMoves = { { id = "TOXIC", pp = 10 }, { id = "TACKLE", pp = 10 } } }
  eq(TrainerAI.chooseMove(aiMon2, rngHi, aiBattle).id, "TACKLE",
     "mod1: discouraged status move never wins (rng high)")
end

-- A single-move mon still returns that move (minimum of one).
do
  local solo = { curMoves = { { id = "TOXIC", pp = 10 } } }
  local aiBattle = { enemyAIMods = { 1 }, data = Data,
                     player = { mon = { status = "PAR" }, curTypes = { "NORMAL" } } }
  eq(TrainerAI.chooseMove(solo, rngLo, aiBattle).id, "TOXIC",
     "mod1: single move is the minimum of one")
end

-- === CASE mod2: 2nd-selection gating + -1 encouragement ===
-- GROWL (ATTACK_DOWN1_EFFECT) is encouraged only when aiLayer2 == 1.
do
  local aiMon = { curMoves = { { id = "GROWL", pp = 10 }, { id = "TACKLE", pp = 10 } } }
  local aiBattle = { enemyAIMods = { 2 }, data = Data,
                     player = { mon = {}, curTypes = { "NORMAL" } } }
  -- 1st selection (aiLayer2 0->1, no encouragement): tie 10/10, rng low -> GROWL
  eq(TrainerAI.chooseMove(aiMon, rngLo, aiBattle).id, "GROWL",
     "mod2: no encouragement on the first selection (tie, first min)")
  -- 2nd selection (aiLayer2 1->2, encouraged): GROWL 9 < TACKLE 10 -> GROWL any rng
  eq(TrainerAI.chooseMove(aiMon, rngHi, aiBattle).id, "GROWL",
     "mod2: stat move encouraged on the second selection")
  -- 3rd selection (aiLayer2 2->3, no encouragement): tie again, rng high -> TACKLE
  eq(TrainerAI.chooseMove(aiMon, rngHi, aiBattle).id, "TACKLE",
     "mod2: encouragement expires after the second selection")
end

-- === CASE mod3: first-row super-effective lookup on a non-damaging move ===
-- THUNDER_WAVE (ELECTRIC) vs WATER reads row 20 -> 9; TACKLE (NORMAL) has no
-- NORMAL->WATER row -> 10.  THUNDER_WAVE is the minimum for any rng.
do
  local aiMon = { curMoves = { { id = "THUNDER_WAVE", pp = 10 }, { id = "TACKLE", pp = 10 } } }
  local aiBattle = { enemyAIMods = { 3 }, data = Data,
                     player = { mon = {}, curTypes = { "WATER" } } }
  eq(TrainerAI.chooseMove(aiMon, rngLo, aiBattle).id, "THUNDER_WAVE",
     "mod3: super-effective non-damaging move is the minimum (rng low)")
  local aiMon2 = { curMoves = { { id = "THUNDER_WAVE", pp = 10 }, { id = "TACKLE", pp = 10 } } }
  eq(TrainerAI.chooseMove(aiMon2, rngHi, aiBattle).id, "THUNDER_WAVE",
     "mod3: super-effective non-damaging move is the minimum (rng high)")
end

-- === CASE class-shaped coverage (real per-class aiMods) ===
-- MISTY {1,3}, RIVAL2/RIVAL3 {1,3}, LORELEI {1,2,3}: against an unstatused
-- Water player, THUNDER_WAVE gets mod3 -1 while mod1/mod2 are no-ops.
for _, class in ipairs({ { "MISTY", { 1, 3 } }, { "RIVAL2/3", { 1, 3 } }, { "LORELEI", { 1, 2, 3 } } }) do
  local aiMon = { curMoves = { { id = "THUNDER_WAVE", pp = 10 }, { id = "TACKLE", pp = 10 } } }
  local aiBattle = { enemyAIMods = class[2], data = Data,
                     player = { mon = {}, curTypes = { "WATER" } } }
  eq(TrainerAI.chooseMove(aiMon, rngHi, aiBattle).id, "THUNDER_WAVE",
     "class " .. class[1] .. ": mod3 super-effective pick, mod1/2 no-op")
end

-- BRUNO/AGATHA {1}: an UNSTATUSED player makes mod1 a no-op, so scores tie
-- and the first minimum is chosen.
do
  local aiMon = { curMoves = { { id = "TOXIC", pp = 10 }, { id = "TACKLE", pp = 10 } } }
  local aiBattle = { enemyAIMods = { 1 }, data = Data,
                     player = { mon = {}, curTypes = { "NORMAL" } } }
  eq(TrainerAI.chooseMove(aiMon, rngLo, aiBattle).id, "TOXIC",
     "class BRUNO/AGATHA: mod1 no-op vs unstatused player (tie, first min)")
end

-- === Min filter: a clearly-worse move is NEVER returned, across RNG values ===
-- TOXIC scores 15 (mod1 +5 vs statused player) while TACKLE and GROWL tie at
-- 10; the minima are {TACKLE, GROWL} and TOXIC can never be selected.
do
  local aiBattle = { enemyAIMods = { 1 }, data = Data,
                     player = { mon = { status = "SLP" }, curTypes = { "NORMAL" } } }
  for _, rng in ipairs({ rngLo, rngHi, function(a, b) return a end }) do
    local aiMon = { curMoves = { { id = "TOXIC", pp = 10 }, { id = "TACKLE", pp = 10 },
                                 { id = "GROWL", pp = 10 } } }
    check(TrainerAI.chooseMove(aiMon, rng, aiBattle).id ~= "TOXIC",
          "min filter: the +5-discouraged move is never selectable")
  end
end

-- === Wild / no-mod uniform pick guard is preserved ===
do
  local aiMon = { curMoves = { { id = "TACKLE", pp = 10 }, { id = "GROWL", pp = 10 } } }
  eq(TrainerAI.chooseMove(aiMon, rngLo, { enemyAIMods = {}, data = Data }).id, "TACKLE",
     "no-mod guard: uniform pick (rng low -> first)")
  local aiMon2 = { curMoves = { { id = "TACKLE", pp = 10 }, { id = "GROWL", pp = 10 } } }
  eq(TrainerAI.chooseMove(aiMon2, rngHi, { enemyAIMods = {}, data = Data }).id, "GROWL",
     "no-mod guard: uniform pick (rng high -> last)")
end

-- === STRUGGLE fallback when nothing is usable ===
do
  local aiMon = { curMoves = { { id = "TACKLE", pp = 0 } } }
  local pick = TrainerAI.chooseMove(aiMon, rngLo, { enemyAIMods = { 1 }, data = Data,
                                                    player = { mon = {}, curTypes = {} } })
  check(pick and pick.struggle and pick.id == "STRUGGLE", "STRUGGLE fallback when no PP")
end

-- === switchAction off-by-one fix (matches AISwitchIfEnoughMons cp 2) ===
-- Switch when >= 1 non-active unfainted backup exists (active + 1 backup = 2
-- total unfainted, the oracle's threshold).
do
  local withBackup = { enemyParty = { { hp = 50 }, { hp = 50 } }, enemyIndex = 1 }
  local act = TrainerAI.switchAction(withBackup)
  check(act and act.special == "aiSwitch" and act.index == 2,
        "switchAction: switches with one unfainted backup")
  local noBackup = { enemyParty = { { hp = 50 }, { hp = 0 } }, enemyIndex = 1 }
  eq(TrainerAI.switchAction(noBackup), nil,
     "switchAction: no switch when no backup is unfainted")
end

S.finish()
