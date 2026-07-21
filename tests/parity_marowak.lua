-- Parity test: the ghost MAROWAK battle opens with NO Silph Scope check
-- at the trigger, and the Poke Doll escape counts as defeating it.
--
-- PokemonTower6FDefaultScript (scripts/PokemonTower6F.asm) fires on
-- (10,16), shows _PokemonTower6FBeGoneText, and starts the RESTLESS SOUL
-- battle unconditionally -- the SILPH_SCOPE is only consulted inside the
-- battle (IsGhostBattle: disguised sprite, "too scared to move", balls
-- dodged). Our port used to turn the player back without the scope and
-- never open the battle, which made 6F impassable on any route that skips
-- Rocket Hideout -- including the speedrun route the bot follows, whose
-- answer to the MAROWAK is a POKE_DOLL, not the scope.
--
-- The doll works because of wBattleResult: the battle script's
-- "and a / jr nz .did_not_defeat" reads 0 as "defeated". Losing writes $1
-- and running writes $2, but ItemUsePokeDoll ends the battle without
-- touching it -- so the doll escape reads as a win and sets
-- EVENT_BEAT_GHOST_MAROWAK. BagMenu marks that escape as
-- battle.pokeDollEscape; the 6F script keys on it.
--
-- Self-contained; run via `luajit tests/parity_marowak.lua`.
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
local S = require("tests.harness").suite("parity ghost marowak")
local check, eq = S.check, S.eq

-- Real TextBoxes want a Font atlas; the decision under test is which
-- branch runs, not how the text renders.
package.loaded["src.render.TextBox"] = {
  new = function(_, text, done) return { text = text, done = done } end,
}

-- A recording stand-in for BattleState: newWild captures the species and
-- level, makeGhost sets the flag the real one sets, and the test drives
-- onFinish by hand.
local madeBattles = {}
package.loaded["src.battle.BattleState"] = {
  newWild = function(_, species, level)
    local b = { species = species, level = level, ghost = false }
    b.makeGhost = function(self) self.ghost = true end
    madeBattles[#madeBattles + 1] = b
    return b
  end,
}

local M = dofile("data/scripts/story3.lua")
local tower = M.POKEMON_TOWER_6F
check(tower ~= nil and tower.onStep ~= nil, "POKEMON_TOWER_6F has a step trigger")

local function gameWith(inventory, flags)
  local pushed = {}
  return {
    save = { inventory = inventory or {}, flags = flags or {} },
    data = { text = {} },
    stack = { push = function(_, box) pushed[#pushed + 1] = box end },
  }, pushed
end

local function owWith()
  local moved, after = {}, {}
  return {
    player = { facing = "up" },
    scriptMove = function(_, _, dir, n) moved[#moved + 1] = { dir, n } end,
    afterBattle = function(_, result) after[#after + 1] = result end,
  }, moved, after
end

-- Walk the trigger: run onStep, then the Be-gone text's done() to push
-- the battle. Returns the battle object (or nil).
local function trigger(game, pushed, ow, x, y)
  local before = #madeBattles
  local fired = tower.onStep(game, ow, x, y)
  if not fired then return nil, fired end
  local box = pushed[#pushed]
  check(box ~= nil and box.done ~= nil, "the Be-gone text is pushed first")
  box.done()
  return madeBattles[#madeBattles], fired, #madeBattles > before
end

-- ---- 1. fires only on (10,16), only while the event is unset ------------
do
  local game, pushed = gameWith()
  local ow = owWith()
  check(not tower.onStep(game, ow, 10, 15), "no trigger off the coord")
  check(not tower.onStep(game, ow, 9, 16), "no trigger off the coord (x)")
  eq(0, #pushed, "nothing pushed off the coord")
end
do
  local game = gameWith({}, { EVENT_BEAT_GHOST_MAROWAK = true })
  local ow = owWith()
  check(not tower.onStep(game, ow, 10, 16),
        "a departed MAROWAK never re-triggers")
end

-- ---- 2. NO scope: the battle still opens, disguised as a ghost ----------
do
  local game, pushed = gameWith({})
  local ow = owWith()
  local battle, fired, created = trigger(game, pushed, ow, 10, 16)
  check(fired, "trigger fires without the SILPH_SCOPE")
  check(created and battle ~= nil,
        "the battle OPENS without the scope (vanilla; the old port turned back)")
  eq("MAROWAK", battle.species, "the opponent is the MAROWAK")
  eq(30, battle.level, "at level 30")
  check(battle.ghost, "and it is ghost-disguised without the scope")
end

-- ---- 3. scope: same battle, not disguised -------------------------------
do
  local game, pushed = gameWith({ SILPH_SCOPE = 1 })
  local ow = owWith()
  local battle = trigger(game, pushed, ow, 10, 16)
  check(battle ~= nil and not battle.ghost,
        "with the scope the battle is not a ghost")
end

-- ---- 4. a win sets the event and shows the departed text ----------------
do
  local game, pushed = gameWith({})
  local ow, moved, after = owWith()
  local battle = trigger(game, pushed, ow, 10, 16)
  battle.onFinish("win")
  check(game.save.flags.EVENT_BEAT_GHOST_MAROWAK, "win sets the event")
  eq(0, #moved, "no shove after a win")
  eq("win", after[#after], "afterBattle still runs")
end

-- ---- 5. the Poke Doll escape counts as a win (wBattleResult trick) ------
do
  local game, pushed = gameWith({})
  local ow, moved = owWith()
  local battle = trigger(game, pushed, ow, 10, 16)
  battle.pokeDollEscape = true
  battle.onFinish("run")
  check(game.save.flags.EVENT_BEAT_GHOST_MAROWAK,
        "the doll escape sets EVENT_BEAT_GHOST_MAROWAK")
  eq(0, #moved, "and does not shove the player")
end

-- ---- 6. an ordinary flee does NOT count, and steps you right ------------
do
  local game, pushed = gameWith({})
  local ow, moved = owWith()
  local battle = trigger(game, pushed, ow, 10, 16)
  battle.onFinish("run")
  check(not game.save.flags.EVENT_BEAT_GHOST_MAROWAK,
        "running away leaves the MAROWAK standing")
  eq(1, #moved, "and walks the player off the trigger")
  eq("right", moved[1] and moved[1][1], ".did_not_defeat steps RIGHT")
end

-- ---- 7. a loss neither sets the event nor shoves (blackout handles it) --
do
  local game, pushed = gameWith({})
  local ow, moved = owWith()
  local battle = trigger(game, pushed, ow, 10, 16)
  battle.onFinish("lose")
  check(not game.save.flags.EVENT_BEAT_GHOST_MAROWAK, "a loss does not clear it")
  eq(0, #moved, "no scripted step on a loss")
end

S.finish()
