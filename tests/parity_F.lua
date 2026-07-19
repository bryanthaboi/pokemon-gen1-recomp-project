-- Parity test,  Workstream F.
-- Self-contained: run via `luajit tests/parity_F.lua`; also dofile'd by
-- tests/run_tests.lua's aggregator.
--
-- Covers: Oak no longer hands over 5 POKé BALLs the instant a starter is
-- picked (scripts/OaksLab.asm has no such grant); the balls are handed
-- over later, at TEXT_OAKSLAB_OAK1's .give_poke_balls beat, gated on
-- EVENT_BEAT_ROUTE22_RIVAL_1ST_BATTLE and the one-shot
-- EVENT_GOT_POKEBALLS_FROM_OAK flag (data/scripts/oaks_lab.lua).
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end

local S = require("tests.harness").suite("parity F")
local check, eq = S.check, S.eq

local Game = require("src.core.Game")
local Input = require("src.core.Input")
local StateStack = require("src.core.StateStack")
local SaveData = require("src.core.SaveData")
local ScriptRunner = require("src.script.ScriptRunner")
local Flags = require("src.script.Flags")
local mapScripts = require("data.scripts.init")

Game.data = Data
Game.input = Input; Input:init()
Game.stack = StateStack; StateStack:init()
Game.save = SaveData.newGame()
require("src.render.Font").load(Data)

-- pumps a script coroutine to completion, mashing A through any
-- show_text/ask boxes along the way (mirrors tests/run_tests.lua's
-- runScript helper for the parcel/pokedex chain)
local function runScript(script)
  local r = ScriptRunner.new(Game, nil)
  r:run(script, {})
  local guard = 0
  while r:isRunning() and guard < 2000 do
    guard = guard + 1
    Input.pressed = { a = true }
    StateStack:update(1 / 60)
    r:update()
  end
  Input.pressed = {}
  return not r:isRunning()
end

-- === 1) picking a starter no longer grants POKé BALLs ===
-- (like the parcel-chain runScript below, this runner has no live
-- overworld; the starterBall() script's give_pokemon/set_flag rows run
-- fine, but its later rival-counterpick NPC choreography needs
-- ctx.overworld and errors out headless -- the ScriptRunner logs and
-- kills the coroutine, so isRunning() still goes false, which is all we
-- need to check the pre-crash flag/inventory state below)
Flags.set(Game.save, "EVENT_FOLLOWED_OAK_INTO_LAB")
check(runScript(mapScripts.talkScript("OAKS_LAB", "TEXT_OAKSLAB_BULBASAUR_POKE_BALL")),
      "starter pick script completes")
check(Flags.get(Game.save, "EVENT_GOT_STARTER"), "starter flag set")
eq(Game.save.inventory.POKE_BALL, nil, "no POKe BALLs yet right after picking a starter")

-- === 2) the parcel/pokedex beat still doesn't grant POKé BALLs ===
check(runScript(mapScripts.talkScript("VIRIDIAN_MART", "TEXT_VIRIDIANMART_CLERK")),
      "mart clerk script completes")
eq(Game.save.inventory.OAKS_PARCEL, 1, "clerk hands over Oak's Parcel")

check(runScript(mapScripts.talkScript("OAKS_LAB", "TEXT_OAKSLAB_OAK1")),
      "Oak delivery script completes")
eq(Game.save.inventory.OAKS_PARCEL, nil, "parcel delivered")
check(Flags.get(Game.save, "EVENT_OAK_GOT_PARCEL"), "delivery flag set")
check(Flags.get(Game.save, "EVENT_GOT_POKEDEX"), "Pokedex flag set")
eq(Game.save.inventory.POKE_BALL, nil, "still no POKe BALLs at the pokedex beat")

-- talking to Oak again before beating the Route 22 rival should fall
-- into the RaiseYourYoungPokemon branch, not give balls
check(runScript(mapScripts.talkScript("OAKS_LAB", "TEXT_OAKSLAB_OAK1")),
      "Oak talk (pre-Route22-win) script completes")
eq(Game.save.inventory.POKE_BALL, nil, "still no POKe BALLs before the Route 22 rival is beaten")

-- === 3) beating the Route 22 rival unlocks the real grant ===
Flags.set(Game.save, "EVENT_BEAT_ROUTE22_RIVAL_1ST_BATTLE")
check(runScript(mapScripts.talkScript("OAKS_LAB", "TEXT_OAKSLAB_OAK1")),
      "Oak give-balls script completes")
eq(Game.save.inventory.POKE_BALL, 5, "Oak gives 5 POKe Balls after the Route 22 win")
check(Flags.get(Game.save, "EVENT_GOT_POKEBALLS_FROM_OAK"), "one-shot flag set")

-- === 4) talking to Oak again does not re-grant (one-shot gate) ===
check(runScript(mapScripts.talkScript("OAKS_LAB", "TEXT_OAKSLAB_OAK1")),
      "Oak talk (post-grant) script completes")
eq(Game.save.inventory.POKE_BALL, 5, "POKe Ball count unchanged on a second talk")

S.finish()
