-- Parity test,  static-encounter pre-battle text (the ~12 disguised
-- static wild battles plus the two Snorlax).
--
-- asm sources: scripts/PowerPlant.asm, scripts/SeafoamIslandsB4F.asm,
-- scripts/VictoryRoad2F.asm, scripts/CeruleanCaveB1F.asm,
-- scripts/Route12.asm, scripts/Route16.asm and home/trainers.asm
-- (TalkToTrainer / EndTrainerBattle: after-battle text when the
-- EVENT_BEAT_* flag is set, flag + HideObject on any non-blackout end).
--
-- Self-contained: run via `luajit tests/parity_static.lua`; also
-- dofile'd by tests/run_tests.lua's aggregator.
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end

local S = require("tests.harness").suite("parity static")
local check, eq = S.check, S.eq

local Game = require("src.core.Game")
local Input = require("src.core.Input")
local StateStack = require("src.core.StateStack")
local SaveData = require("src.core.SaveData")
local ScriptRunner = require("src.script.ScriptRunner")
local Commands = require("src.script.Commands")
local Flags = require("src.script.Flags")
local mapScripts = require("data.scripts.init")

Game.data = Data
Game.input = Input; Input:init()
Game.stack = StateStack; StateStack:init()
Game.save = SaveData.newGame()
require("src.render.Font").load(Data)

-- === 1) every static encounter resolves to a hand-ported talk script
--        whose text labels all exist in the generated text ===
local ENCOUNTERS = {
  { "POWER_PLANT", "TEXT_POWERPLANT_VOLTORB1" },
  { "POWER_PLANT", "TEXT_POWERPLANT_VOLTORB2" },
  { "POWER_PLANT", "TEXT_POWERPLANT_VOLTORB3" },
  { "POWER_PLANT", "TEXT_POWERPLANT_ELECTRODE1" },
  { "POWER_PLANT", "TEXT_POWERPLANT_VOLTORB4" },
  { "POWER_PLANT", "TEXT_POWERPLANT_VOLTORB5" },
  { "POWER_PLANT", "TEXT_POWERPLANT_ELECTRODE2" },
  { "POWER_PLANT", "TEXT_POWERPLANT_VOLTORB6" },
  { "POWER_PLANT", "TEXT_POWERPLANT_ZAPDOS" },
  { "SEAFOAM_ISLANDS_B4F", "TEXT_SEAFOAMISLANDSB4F_ARTICUNO" },
  { "VICTORY_ROAD_2F", "TEXT_VICTORYROAD2F_MOLTRES" },
  { "CERULEAN_CAVE_B1F", "TEXT_CERULEANCAVEB1F_MEWTWO" },
  { "ROUTE_12", "TEXT_ROUTE12_SNORLAX" },
  { "ROUTE_16", "TEXT_ROUTE16_SNORLAX" },
}
for _, e in ipairs(ENCOUNTERS) do
  local script = mapScripts.talkScript(e[1], e[2])
  check(type(script) == "table", "registry resolves " .. e[1] .. "/" .. e[2])
  for _, row in ipairs(script or {}) do
    if row[1] == "show_text" and row[2]:sub(1, 1) == "_" then
      check(Data.text[row[2]] ~= nil, e[2] .. " text " .. row[2] .. " exists")
    end
  end
end

-- === harness: run a talk script headless, recording texts + battles ===
local shown, battles = {}, {}
local battleResult = "win"
local origShow, origStart = Commands.show_text, Commands.start_battle
Commands.show_text = function(ctx, textId, subs)
  table.insert(shown, textId)
  return origShow(ctx, textId, subs)
end
Commands.start_battle = function(ctx, kind, a, b)
  table.insert(battles, { kind = kind, species = a, level = b })
  ctx.lastBattleResult = battleResult
  ctx.lastCheck = battleResult == "win"
end

local function fakeOw(mapId, label)
  return { map = { id = mapId, def = { label = label } }, npcs = {}, entities = {} }
end

local function runScript(mapId, label, textConst, npcName)
  shown, battles = {}, {}
  local script = mapScripts.talkScript(mapId, textConst)
  local ow = fakeOw(mapId, label)
  local r = ScriptRunner.new(Game, ow)
  r:run(script, { npc = { def = { name = npcName } }, overworld = ow })
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

local function toggleOf(mapId, objName)
  local t = Game.save.objectToggles
  return t and t[mapId] and t[mapId][objName]
end

-- run a snorlaxWake script (the flute-triggered wake+battle sequence,
-- NOT a talk script -- see data/scripts/story.lua) headless
local function runWakeScript(mapId, label, npcName)
  shown, battles = {}, {}
  local script = mapScripts.get(mapId).snorlaxWake.script
  local ow = fakeOw(mapId, label)
  local r = ScriptRunner.new(Game, ow)
  r:run(script, { npc = { def = { name = npcName } }, overworld = ow })
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

-- === 2) Zapdos: "Gyaoo!" then the battle; fleeing still counts as
--        beaten (EndTrainerBattle sets EVENT_BEAT_ZAPDOS and hides the
--        object on any non-blackout end) ===
Game.save = SaveData.newGame()
battleResult = "run"
check(runScript("POWER_PLANT", "PowerPlant", "TEXT_POWERPLANT_ZAPDOS",
                "POWERPLANT_ZAPDOS"), "Zapdos script completes")
eq(#shown, 1, "Zapdos shows one text")
eq(shown[1], "_PowerPlantZapdosBattleText", "Zapdos pre-battle text is Gyaoo!")
eq(#battles, 1, "Zapdos starts one battle")
eq(battles[1].species, "ZAPDOS", "Zapdos battle species")
eq(battles[1].level, 50, "Zapdos battle level")
check(Flags.get(Game.save, "EVENT_BEAT_ZAPDOS"), "fled Zapdos still sets EVENT_BEAT_ZAPDOS")
eq(toggleOf("POWER_PLANT", "POWERPLANT_ZAPDOS"), false, "fled Zapdos object hidden")

-- === 3) capture-state branch: with EVENT_BEAT_ZAPDOS already set,
--        TalkToTrainer prints the after-battle text and stops ===
check(runScript("POWER_PLANT", "PowerPlant", "TEXT_POWERPLANT_ZAPDOS",
                "POWERPLANT_ZAPDOS"), "beaten-Zapdos script completes")
eq(#shown, 1, "beaten Zapdos still shows the text")
eq(#battles, 0, "beaten Zapdos starts no battle")

-- === 4) Mewtwo: "Mew!" then MEWTWO lv70; catching sets EVENT_BEAT_MEWTWO ===
Game.save = SaveData.newGame()
battleResult = "caught"
check(runScript("CERULEAN_CAVE_B1F", "CeruleanCaveB1F", "TEXT_CERULEANCAVEB1F_MEWTWO",
                "CERULEANCAVEB1F_MEWTWO"), "Mewtwo script completes")
eq(shown[1], "_MewtwoBattleText", "Mewtwo pre-battle text is Mew!")
eq(battles[1] and battles[1].species, "MEWTWO", "Mewtwo battle species")
eq(battles[1] and battles[1].level, 70, "Mewtwo battle level")
check(Flags.get(Game.save, "EVENT_BEAT_MEWTWO"), "caught Mewtwo sets EVENT_BEAT_MEWTWO")

-- capture-state branch: talking again shows the text only
check(runScript("CERULEAN_CAVE_B1F", "CeruleanCaveB1F", "TEXT_CERULEANCAVEB1F_MEWTWO",
                "CERULEANCAVEB1F_MEWTWO"), "beaten-Mewtwo script completes")
eq(#shown, 1, "beaten Mewtwo still shows Mew!")
eq(#battles, 0, "beaten Mewtwo starts no battle")

-- blackout: no flag, object stays
Game.save = SaveData.newGame()
battleResult = "lose"
runScript("CERULEAN_CAVE_B1F", "CeruleanCaveB1F", "TEXT_CERULEANCAVEB1F_MEWTWO",
          "CERULEANCAVEB1F_MEWTWO")
check(not Flags.get(Game.save, "EVENT_BEAT_MEWTWO"), "blackout leaves EVENT_BEAT_MEWTWO unset")
eq(toggleOf("CERULEAN_CAVE_B1F", "CERULEANCAVEB1F_MEWTWO"), nil,
   "blackout leaves Mewtwo visible")

-- === 5) Power Plant item-ball Voltorb: "Bzzzt!" then VOLTORB lv40 ===
Game.save = SaveData.newGame()
battleResult = "win"
check(runScript("POWER_PLANT", "PowerPlant", "TEXT_POWERPLANT_VOLTORB1",
                "POWERPLANT_VOLTORB1"), "Voltorb script completes")
eq(shown[1], "_PowerPlantVoltorbBattleText", "Voltorb pre-battle text is Bzzzt!")
eq(battles[1] and battles[1].species, "VOLTORB", "Voltorb battle species")
eq(battles[1] and battles[1].level, 40, "Voltorb battle level")
check(Flags.get(Game.save, "EVENT_BEAT_POWER_PLANT_VOLTORB_0"),
      "Voltorb 1 sets EVENT_BEAT_POWER_PLANT_VOLTORB_0")
-- Electrode header offset (text_asm 4 -> Voltorb3TrainerHeader)
runScript("POWER_PLANT", "PowerPlant", "TEXT_POWERPLANT_ELECTRODE1",
          "POWERPLANT_ELECTRODE1")
eq(battles[1] and battles[1].species, "ELECTRODE", "Electrode battle species")
eq(battles[1] and battles[1].level, 43, "Electrode battle level")
check(Flags.get(Game.save, "EVENT_BEAT_POWER_PLANT_VOLTORB_3"),
      "Electrode 1 sets EVENT_BEAT_POWER_PLANT_VOLTORB_3")

-- === 6) Snorlax (Route 12): talking always shows the sleeping line --
--        even with the flute in the bag, talking never wakes it (that's
--        the item-use menu's job; see ItemEffects.lua/BagMenu.lua) ===
Game.save = SaveData.newGame()
runScript("ROUTE_12", "Route12", "TEXT_ROUTE12_SNORLAX", "ROUTE12_SNORLAX")
eq(#shown, 1, "flute-less Snorlax shows one text")
eq(shown[1], "_Route12SnorlaxText", "flute-less Snorlax shows the sleeping line")
eq(#battles, 0, "flute-less Snorlax starts no battle")

require("src.inventory.Bag").add(Game.save, "POKE_FLUTE", 1)
runScript("ROUTE_12", "Route12", "TEXT_ROUTE12_SNORLAX", "ROUTE12_SNORLAX")
eq(#shown, 1, "Snorlax with the flute in the bag still just shows one text")
eq(shown[1], "_Route12SnorlaxText",
   "talking with the flute in the bag does NOT wake Snorlax (must USE it)")
eq(#battles, 0, "Snorlax with the flute in the bag starts no battle from talking")

-- === 7) using the flute (data/scripts/story.lua's snorlaxWake, run by
--        ItemEffects.lua/BagMenu.lua's flute_wake path): woke-up text,
--        battle, then the calmed-down line when NOT caught
--        (Route12SnorlaxPostBattleScript's wBattleResult ~= $2) ===
Game.save = SaveData.newGame()
battleResult = "win"
check(runWakeScript("ROUTE_12", "Route12", "ROUTE12_SNORLAX"),
      "Snorlax wake script completes")
eq(#shown, 2, "beaten Snorlax shows two texts")
eq(shown[1], "_Route12SnorlaxWokeUpText", "Snorlax woke-up text first")
eq(shown[2], "_Route12SnorlaxCalmedDownText", "calmed-down text when not caught")
eq(battles[1] and battles[1].species, "SNORLAX", "Snorlax battle species")
eq(battles[1] and battles[1].level, 30, "Snorlax battle level")
check(Flags.get(Game.save, "EVENT_BEAT_ROUTE12_SNORLAX"), "EVENT_BEAT_ROUTE12_SNORLAX set")
eq(toggleOf("ROUTE_12", "ROUTE12_SNORLAX"), false, "Snorlax object hidden")

-- caught: no calmed-down line (cp $2 / jr z, .caught_snorlax)
Game.save = SaveData.newGame()
battleResult = "caught"
runWakeScript("ROUTE_16", "Route16", "ROUTE16_SNORLAX")
eq(#shown, 1, "caught Snorlax shows only the woke-up text")
eq(shown[1], "_Route16SnorlaxWokeUpText", "Route 16 woke-up text")
check(Flags.get(Game.save, "EVENT_BEAT_ROUTE16_SNORLAX"), "EVENT_BEAT_ROUTE16_SNORLAX set")

-- blackout: HideObject ran BEFORE the battle, so Snorlax is gone anyway,
-- but the beat flag stays unset (Route16ResetScripts path)
Game.save = SaveData.newGame()
battleResult = "lose"
runWakeScript("ROUTE_16", "Route16", "ROUTE16_SNORLAX")
eq(#shown, 1, "blackout Snorlax shows only the woke-up text")
check(not Flags.get(Game.save, "EVENT_BEAT_ROUTE16_SNORLAX"),
      "blackout leaves EVENT_BEAT_ROUTE16_SNORLAX unset")
eq(toggleOf("ROUTE_16", "ROUTE16_SNORLAX"), false,
   "Snorlax hidden even after a blackout (pre-battle HideObject)")

-- === 8) ItemEffects.lua's POKE_FLUTE field-use branch: only wakes
--        Snorlax (flute_wake) when the player is on its route, hasn't
--        beaten it, and stands right next to it; otherwise it's a no-op
--        flute_field (ItemUsePokeFlute / Route12SnorlaxFluteCoords) ===
local ItemEffects = require("src.inventory.ItemEffects")

local function fakeOwWithSnorlax(mapId, px, py, nx, ny)
  return {
    map = { id = mapId },
    player = { cellX = px, cellY = py },
    npcs = { { def = { name = mapId == "ROUTE_12" and "ROUTE12_SNORLAX"
                        or "ROUTE16_SNORLAX" }, cellX = nx, cellY = ny } },
  }
end

Game.save = SaveData.newGame()
require("src.inventory.Bag").add(Game.save, "POKE_FLUTE", 1)
local owAdjacent = fakeOwWithSnorlax("ROUTE_12", 9, 62, 10, 62) -- west neighbor
local result, _, extra = ItemEffects.use(Data, Game.save, "POKE_FLUTE", nil, nil, nil, owAdjacent)
eq(result, "flute_wake", "using the flute next to Snorlax wakes it")
eq(extra and extra.mapId, "ROUTE_12", "flute_wake reports the route")

local owFar = fakeOwWithSnorlax("ROUTE_12", 5, 5, 10, 62) -- far away
result = ItemEffects.use(Data, Game.save, "POKE_FLUTE", nil, nil, nil, owFar)
eq(result, "flute_field", "using the flute away from Snorlax has no effect")

Flags.set(Game.save, "EVENT_BEAT_ROUTE12_SNORLAX")
result = ItemEffects.use(Data, Game.save, "POKE_FLUTE", nil, nil, nil, owAdjacent)
eq(result, "flute_field", "an already-beaten Snorlax doesn't wake again")

-- restore the real commands for later suites
Commands.show_text = origShow
Commands.start_battle = origStart
Game.save = SaveData.newGame()

S.finish()
