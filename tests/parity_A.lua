-- Parity test,  Workstream A (gym-guide batch).
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end
local unpack = table.unpack or unpack
local S = require("tests.harness").suite("parity A")
local check, eq = S.check, S.eq

-- === assertions ===

local init = require("data.scripts.init")

local guides = {
  { "CERULEAN_GYM",  "TEXT_CERULEANGYM_GYM_GUIDE" },
  { "CINNABAR_GYM",  "TEXT_CINNABARGYM_GYM_GUIDE" },
  { "FUCHSIA_GYM",   "TEXT_FUCHSIAGYM_GYM_GUIDE" },
  { "GAME_CORNER",   "TEXT_GAMECORNER_GYM_GUIDE" },
  { "PEWTER_GYM",    "TEXT_PEWTERGYM_GYM_GUIDE" },
  { "SAFFRON_GYM",   "TEXT_SAFFRONGYM_GYM_GUIDE" },
  { "VERMILION_GYM", "TEXT_VERMILIONGYM_GYM_GUIDE" },
  { "VIRIDIAN_GYM",  "TEXT_VIRIDIANGYM_GYM_GUIDE" },
}

-- (1) all 8 gym-guide talk scripts are registered and non-nil
for _, g in ipairs(guides) do
  local mapId, textConst = g[1], g[2]
  local script = init.talkScript(mapId, textConst)
  check(script ~= nil, ("%s.%s registered (non-nil)"):format(mapId, textConst))
  check(type(script) == "table" or type(script) == "function",
    ("%s.%s is a table or function"):format(mapId, textConst))
end

-- helper: does a row-list script reference a given text label anywhere?
local function referencesLabel(rows, label)
  for _, r in ipairs(rows) do
    for _, v in ipairs(r) do
      if v == label then return true end
    end
  end
  return false
end

-- (2) badge-branch guides (row-list style): confirm both branches
-- reference the real extracted pokered labels, and drive both paths.

local function driveBadgeBranch(mapId, textConst, beatFlag, champLabel, beatLabel, desc)
  local script = init.talkScript(mapId, textConst)
  check(type(script) == "table", desc .. " is a row-list table")
  if type(script) ~= "table" then return end
  check(referencesLabel(script, champLabel), desc .. " references " .. champLabel)
  check(referencesLabel(script, beatLabel), desc .. " references " .. beatLabel)

  -- run it with a stub ctx (no badge) -> should land on champLabel
  local Commands = require("src.script.Commands")
  local shown = {}
  local origShowText = Commands.show_text
  Commands.show_text = function(ctx, textId) table.insert(shown, textId) end
  local ctx = { save = { flags = {} } }
  local function run(flags)
    ctx.save = { flags = flags }
    shown = {}
    local pc = 1
    while pc <= #script do
      local row = script[pc]
      local fn = Commands[row[1]]
      local jump = fn(ctx, select(2, unpack(row)))
      if type(jump) == "number" then pc = jump else pc = pc + 1 end
    end
  end
  run({})
  eq(shown[1], champLabel, desc .. " (no badge) shows champ-in-making text")
  run({ [beatFlag] = true })
  eq(shown[1], beatLabel, desc .. " (beaten) shows post-badge text")
  Commands.show_text = origShowText
end

driveBadgeBranch("CERULEAN_GYM", "TEXT_CERULEANGYM_GYM_GUIDE", "EVENT_BEAT_MISTY",
  "_CeruleanGymGymGuideChampInMakingText", "_CeruleanGymGymGuideBeatMistyText",
  "CERULEAN_GYM gym guide")

driveBadgeBranch("VIRIDIAN_GYM", "TEXT_VIRIDIANGYM_GYM_GUIDE", "EVENT_BEAT_GIOVANNI",
  "_ViridianGymGuidePreBattleText", "_ViridianGymGuidePostBattleText",
  "VIRIDIAN_GYM gym guide")

-- (3) the remaining simple badge-branch guides at least reference their
-- real pokered labels
local simple = {
  { "CINNABAR_GYM", "TEXT_CINNABARGYM_GYM_GUIDE",
    "_CinnabarGymGymGuideChampInMakingText", "_CinnabarGymGymGuideBeatBlaineText" },
  { "FUCHSIA_GYM", "TEXT_FUCHSIAGYM_GYM_GUIDE",
    "_FuchsiaGymGymGuideChampInMakingText", "_FuchsiaGymGymGuideBeatKogaText" },
  { "GAME_CORNER", "TEXT_GAMECORNER_GYM_GUIDE",
    "_GameCornerGymGuideChampInMakingText", "_GameCornerGymGuideTheyOfferRarePokemonText" },
  { "SAFFRON_GYM", "TEXT_SAFFRONGYM_GYM_GUIDE",
    "_SaffronGymGuideChampInMakingText", "_SaffronGymGuideBeatSabrinaText" },
  { "VERMILION_GYM", "TEXT_VERMILIONGYM_GYM_GUIDE",
    "_VermilionGymGymGuideChampInMakingText", "_VermilionGymGymGuideBeatLTSurgeText" },
}
for _, s in ipairs(simple) do
  local mapId, textConst, champLabel, beatLabel = s[1], s[2], s[3], s[4]
  local script = init.talkScript(mapId, textConst)
  check(type(script) == "table", mapId .. " gym guide is a row-list table")
  if type(script) == "table" then
    check(referencesLabel(script, champLabel), mapId .. " gym guide references " .. champLabel)
    check(referencesLabel(script, beatLabel), mapId .. " gym guide references " .. beatLabel)
  end
end

-- (4) Pewter's YES/NO branch: confirm all four real text labels appear
do
  local script = init.talkScript("PEWTER_GYM", "TEXT_PEWTERGYM_GYM_GUIDE")
  check(type(script) == "table", "PEWTER_GYM gym guide is a row-list table")
  if type(script) == "table" then
    for _, label in ipairs({
      "_PewterGymGuidePreAdviceText", "_PewterGymGuideBeginAdviceText",
      "_PewterGymGuideFreeServiceText", "_PewterGymGuideAdviceText",
      "_PewterGymGuidePostBattleText",
    }) do
      check(referencesLabel(script, label), "PEWTER_GYM gym guide references " .. label)
    end
    -- confirm it actually contains an "ask" row (the YES/NO branch)
    local hasAsk = false
    for _, r in ipairs(script) do
      if r[1] == "ask" then hasAsk = true end
    end
    check(hasAsk, "PEWTER_GYM gym guide asks a YES/NO question")
  end
end

-- (5) all 8 real extracted text labels exist in generated text data
for _, label in ipairs({
  "_CeruleanGymGymGuideChampInMakingText", "_CeruleanGymGymGuideBeatMistyText",
  "_CinnabarGymGymGuideChampInMakingText", "_CinnabarGymGymGuideBeatBlaineText",
  "_FuchsiaGymGymGuideChampInMakingText", "_FuchsiaGymGymGuideBeatKogaText",
  "_GameCornerGymGuideChampInMakingText", "_GameCornerGymGuideTheyOfferRarePokemonText",
  "_PewterGymGuidePreAdviceText", "_PewterGymGuideBeginAdviceText",
  "_PewterGymGuideFreeServiceText", "_PewterGymGuideAdviceText",
  "_PewterGymGuidePostBattleText",
  "_SaffronGymGuideChampInMakingText", "_SaffronGymGuideBeatSabrinaText",
  "_VermilionGymGymGuideChampInMakingText", "_VermilionGymGymGuideBeatLTSurgeText",
  "_ViridianGymGuidePreBattleText", "_ViridianGymGuidePostBattleText",
}) do
  check(Data.text and Data.text[label] ~= nil, "extracted text exists: " .. label)
end

-- (6) gym leader talk handlers (data/scripts/gyms.lua): pre-badge talk
-- routes into engageTrainer (leader battle), post-badge talk shows the
-- leader's faithful advice text; Giovanni additionally disappears.
do
  local leaders = {
    { "PEWTER_GYM",    "TEXT_PEWTERGYM_BROCK" },
    { "CERULEAN_GYM",  "TEXT_CERULEANGYM_MISTY" },
    { "VERMILION_GYM", "TEXT_VERMILIONGYM_LT_SURGE" },
    { "CELADON_GYM",   "TEXT_CELADONGYM_ERIKA" },
    { "FUCHSIA_GYM",   "TEXT_FUCHSIAGYM_KOGA" },
    { "SAFFRON_GYM",   "TEXT_SAFFRONGYM_SABRINA" },
    { "CINNABAR_GYM",  "TEXT_CINNABARGYM_BLAINE" },
    { "VIRIDIAN_GYM",  "TEXT_VIRIDIANGYM_GIOVANNI" },
  }
  for _, l in ipairs(leaders) do
    check(type(init.talkScript(l[1], l[2])) == "function",
      l[1] .. "." .. l[2] .. " leader talk registered (function handler)")
  end

  -- the post-badge advice labels all exist in the extracted text
  for _, label in ipairs({
    "_PewterGymBrockPostBattleAdviceText",
    "_CeruleanGymMistyTM11ExplanationText",
    "_VermilionGymLTSurgePostBattleAdviceText",
    "_CeladonGymErikaPostBattleAdviceText",
    "_FuchsiaGymKogaPostBattleAdviceText",
    "_SaffronGymSabrinaPostBattleAdviceText",
    "_CinnabarGymBlainePostBattleAdviceText",
    "_ViridianGymGiovanniPostBattleAdviceText",
  }) do
    check(Data.text and Data.text[label] ~= nil, "extracted text exists: " .. label)
  end

  -- drive both branches with a capturing TextBox stub
  local realTB = package.loaded["src.render.TextBox"]
  package.loaded["src.render.TextBox"] = {
    new = function(game, text, done) return { text = text, onDone = done } end,
  }

  local function driveLeader(mapId, textConst, beatFlag)
    local pushed, engaged
    local game = {
      save = { flags = {} },
      data = Data,
      stack = { push = function(_, tb) pushed = tb end },
    }
    local ow = { map = { id = mapId }, npcs = {}, entities = {},
                 engageTrainer = function() engaged = true end }
    local script = init.talkScript(mapId, textConst)
    script(game, ow, { def = {} }, function() end)
    check(engaged and not pushed,
      mapId .. " leader talk (no badge) engages the leader battle")
    engaged, pushed = nil, nil
    game.save.flags[beatFlag] = true
    local state = {}
    script(game, ow, { def = {} }, function() state.doneCalled = true end)
    check(pushed and not engaged,
      mapId .. " leader talk (beaten) shows a text box instead")
    return game, pushed, state
  end

  local _, box = driveLeader("CERULEAN_GYM", "TEXT_CERULEANGYM_MISTY",
                             "EVENT_BEAT_MISTY")
  eq(box and box.text, Data.text._CeruleanGymMistyTM11ExplanationText,
     "Misty (beaten) shows the TM11 explanation text")

  _, box = driveLeader("CINNABAR_GYM", "TEXT_CINNABARGYM_BLAINE",
                       "EVENT_BEAT_BLAINE")
  eq(box and box.text, Data.text._CinnabarGymBlainePostBattleAdviceText,
     "Blaine (beaten) shows his post-battle advice text")

  local game, gbox, state = driveLeader("VIRIDIAN_GYM", "TEXT_VIRIDIANGYM_GIOVANNI",
                                        "EVENT_BEAT_GIOVANNI")
  eq(gbox and gbox.text, Data.text._ViridianGymGiovanniPostBattleAdviceText,
     "Giovanni (beaten) shows his farewell text")

  -- ViridianGym.asm .afterBeat: GBFadeOutToBlack, HideObject while the
  -- screen is black, GBFadeInFromBlack. Closing the box pushes the shared
  -- src/render/Transition fade (not a synchronous hide) -- drive it through
  -- its real out/in cycle the way game.stack would.
  local Transition = require("src.render.Transition")
  local popped = false
  game.stack.pop = function() popped = true end
  local pushedFade
  game.stack.push = function(_, tb) pushedFade = tb end
  if gbox then gbox.onDone() end
  check(getmetatable(pushedFade) == Transition,
        "Giovanni's farewell pushes the shared fade Transition, not a bare hide")
  check(not (game.save.objectToggles and game.save.objectToggles.VIRIDIAN_GYM
             and game.save.objectToggles.VIRIDIAN_GYM.VIRIDIANGYM_GIOVANNI == false),
        "Giovanni is not yet hidden the instant the box closes (still fading out)")

  -- drive through the fade-out; HideObject fires as the onMidpoint
  -- callback, exactly when the phase flips from "out" to "in" (the
  -- screen is fully black at that instant, matching GBFadeOutToBlack ->
  -- HideObject in ViridianGym.asm)
  local guard = 0
  while pushedFade.phase == "out" and guard < 10000 do
    pushedFade:update(1)
    guard = guard + 1
  end
  check(game.save.objectToggles and game.save.objectToggles.VIRIDIAN_GYM
        and game.save.objectToggles.VIRIDIAN_GYM.VIRIDIANGYM_GIOVANNI == false,
        "Giovanni hidden via objectToggles at the fade's midpoint (screen black)")
  check(not state.doneCalled, "done() withheld until the fade back in finishes")

  -- drive through the fade-in; onDone (and the stack pop) fire together
  -- once it completes, matching GBFadeInFromBlack -> TextScriptEnd
  guard = 0
  while not state.doneCalled and guard < 10000 do
    pushedFade:update(1)
    guard = guard + 1
  end
  check(state.doneCalled, "Giovanni's talk chains onDone once the fade back in finishes")
  check(popped, "the fade pops itself off the stack when done")

  package.loaded["src.render.TextBox"] = realTB
end

-- (7) gym / dojo leader victory deactivates unfought non-leader trainers
-- (PewterGym.asm "; deactivate gym trainers" / SetEventRange in the
-- other gyms; FightingDojo.asm SetEventRange through TRAINER_3).
do
  local victories = require("data.scripts.victories")
  local expected = {
    ["OPP_BROCK#1"] = { "EVENT_BEAT_PEWTER_GYM_TRAINER_0" },
    ["OPP_MISTY#1"] = { "EVENT_BEAT_CERULEAN_GYM_TRAINER_0",
                        "EVENT_BEAT_CERULEAN_GYM_TRAINER_1" },
    ["OPP_LT_SURGE#1"] = { "EVENT_BEAT_VERMILION_GYM_TRAINER_0",
                           "EVENT_BEAT_VERMILION_GYM_TRAINER_1",
                           "EVENT_BEAT_VERMILION_GYM_TRAINER_2" },
    ["OPP_ERIKA#1"] = 7,
    ["OPP_KOGA#1"] = 6,
    ["OPP_SABRINA#1"] = 7,
    ["OPP_BLAINE#1"] = 7,
    ["OPP_GIOVANNI#3"] = 8,
    ["OPP_BLACKBELT#1"] = 4,
  }
  for key, want in pairs(expected) do
    local d = victories[key] and victories[key].deactivate
    check(d ~= nil, key .. " lists trainers to deactivate")
    if type(want) == "number" then
      eq(#d, want, key .. " deactivates " .. want .. " trainers")
    else
      for i, flag in ipairs(want) do
        eq(d[i], flag, key .. " deactivate[" .. i .. "]")
      end
    end
  end

  -- Cinnabar trainers have no extracted def_trainers; seeded headers let
  -- EVENT_BEAT_CINNABAR_GYM_TRAINER_* satisfy trainerDefeated without
  -- stamping defeatedTrainers (which would also open the quiz gates).
  Data:seedCinnabarGymTrainerHeaders()
  check(Data.trainer_headers.CinnabarGym ~= nil,
        "CinnabarGym trainer headers seeded for deactivate flags")
  local nerd1 = Data:trainerHeader("CinnabarGym", 2)
  check(nerd1 and nerd1.event == "EVENT_BEAT_CINNABAR_GYM_TRAINER_0"
        and nerd1.range == 0,
        "Cinnabar SUPER_NERD1 header: event + no sight range")

  require("src.render.Font").load(Data)
  local Game = require("src.core.Game")
  local Input = require("src.core.Input")
  local StateStack = require("src.core.StateStack")
  local Renderer = require("src.render.Renderer")
  local SaveData = require("src.core.SaveData")
  local OW = require("src.world.OverworldController")
  local realTB = package.loaded["src.render.TextBox"]
  package.loaded["src.render.TextBox"] = {
    new = function(game, text, done) return { text = text, onDone = done } end,
  }
  Game.data = Data
  Game.input = Input; Input:init()
  Game.renderer = Renderer; Renderer:init()
  Game.stack = StateStack; StateStack:init()
  while Game.stack:top() do Game.stack:pop() end
  Game.save = SaveData.newGame()
  Game.save.flags = {}
  Game.save.inventory = {}
  Game.save.defeatedTrainers = {}
  Game.stack:push(OW, "PEWTER_GYM", 4, 13, "up")
  local ow = Game.stack:top()
  ow:checkVictoryRewards("OPP_BROCK", 1)
  check(Game.save.flags.EVENT_BEAT_BROCK, "Brock victory sets EVENT_BEAT_BROCK")
  check(Game.save.inventory.BOULDERBADGE == 1, "Brock victory awards BOULDERBADGE")
  check(Game.save.flags.EVENT_BEAT_PEWTER_GYM_TRAINER_0,
        "Brock victory deactivates the Pewter Gym Cooltrainer")
  local pewterNpc
  for _, npc in ipairs(ow.npcs) do
    if npc.def.index == 2 then pewterNpc = npc break end
  end
  check(pewterNpc and ow:trainerDefeated(pewterNpc),
        "unfought Pewter gym trainer is defeated after badge")
  -- PewterGym.asm .gymVictory HideObject TOGGLE_GYM_GUY /
  -- TOGGLE_ROUTE_22_RIVAL_1 (persists via objectToggles)
  check(Game.save.objectToggles
        and Game.save.objectToggles.PEWTER_CITY
        and Game.save.objectToggles.PEWTER_CITY.PEWTERCITY_YOUNGSTER == false,
        "Brock victory hides PEWTERCITY_YOUNGSTER")
  check(Game.save.objectToggles.ROUTE_22
        and Game.save.objectToggles.ROUTE_22.ROUTE22_RIVAL1 == false,
        "Brock victory hides ROUTE22_RIVAL1")

  while Game.stack:top() do Game.stack:pop() end
  Game.save = SaveData.newGame()
  Game.save.flags = {}
  Game.save.inventory = {}
  Game.save.defeatedTrainers = {}
  Game.stack:push(OW, "CINNABAR_GYM", 16, 15, "up")
  ow = Game.stack:top()
  ow:checkVictoryRewards("OPP_BLAINE", 1)
  check(Game.save.flags.EVENT_BEAT_CINNABAR_GYM_TRAINER_3,
        "Blaine victory deactivates Cinnabar quiz trainers")
  check(next(Game.save.defeatedTrainers) == nil,
        "Blaine deactivate does not stamp defeatedTrainers (gates stay put)")
  local cinnabarNpc
  for _, npc in ipairs(ow.npcs) do
    if npc.def.index == 5 then cinnabarNpc = npc break end
  end
  check(cinnabarNpc and ow:trainerDefeated(cinnabarNpc),
        "unfought Cinnabar trainer is defeated via seeded header event")

  while Game.stack:top() do Game.stack:pop() end
  package.loaded["src.render.TextBox"] = realTB
end

S.finish()
