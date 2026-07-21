-- Gift NPCs and in-game trades.  Each cites its pokered source.

local M = {}

local function text(game) return game.data.text end

local function push(game, s, done)
  local TextBox = require("src.render.TextBox")
  game.stack:push(TextBox.new(game, s, done))
end

-- fill the extracted text placeholders ({RAM:...}, {PLAYER})
local function fill(s, subs)
  s = s:gsub("{PLAYER}", subs.player or "")
  s = s:gsub("{RAM:[^}]*}", function() return subs.ram or "" end)
  return s
end

-- One-time item gift, following the original text_asm flow:
-- pre text (optional) -> GiveItem (bag-full refusal keeps the flag
-- unset, talk again after making room) -> received text -> optional
-- explanation; repeat visits get the already text.
local function gift(opts)
  return function(game, ow, npc, done)
    local t = text(game)
    local itemName = game.data.items[opts.item].name
    local subs = { ram = itemName, player = game.save.player.name }
    local function say(label, fallback, cb)
      push(game, fill(t[label] or fallback, subs), cb)
    end
    if game.save.flags[opts.flag] then
      say(opts.already or opts.explain, "It's a useful\nitem, isn't it?", done)
      return
    end
    local function give()
      if not require("src.inventory.Bag").add(game.save, opts.item, 1) then
        say(opts.noRoom, "You have no room\nfor this item!", done)
        return
      end
      game.save.flags[opts.flag] = true
      local idef = game.data.items[opts.item]
      require("src.core.Sound").play(game.data,
        (idef and idef.keyItem) and "Get_Key_Item" or "Get_Item1")
      say(opts.received, "{PLAYER} received\n{RAM:}!", function()
        if opts.explain then
          say(opts.explain, "", done)
        else
          done()
        end
      end)
    end
    if opts.pre then say(opts.pre, "", give) else give() end
  end
end

-- Coin Case (scripts/CeladonDiner.asm, the busted gym guide)
M.CELADON_DINER = {
  talk = {
    TEXT_CELADONDINER_GYM_GUIDE = gift({
      flag = "EVENT_GOT_COIN_CASE", item = "COIN_CASE",
      pre = "_CeladonDinerGymGuideImFlatOutBustedText",
      received = "_CeladonDinerGymGuideReceivedCoinCaseText",
      noRoom = "_CeladonDinerGymGuideCoinCaseNoRoomText",
      already = "_CeladonDinerGymGuideWinItBackText",
    }),
  },
}

-- TM18 Counter (scripts/CeladonMart3F.asm, the TV-game-shop clerk)
M.CELADON_MART_3F = {
  talk = {
    TEXT_CELADONMART3F_CLERK = gift({
      flag = "EVENT_GOT_TM18", item = "TM_COUNTER",
      pre = "_CeladonMart3FClerkTM18PreReceiveText",
      received = "_CeladonMart3FClerkReceivedTM18Text",
      explain = "_CeladonMart3FClerkTM18ExplanationText",
      noRoom = "_CeladonMart3FClerkTM18NoRoomText",
    }),
  },
}

-- TM39 Swift (scripts/Route12Gate2F.asm)
M.ROUTE_12_GATE_2F = {
  talk = {
    TEXT_ROUTE12GATE2F_BRUNETTE_GIRL = gift({
      flag = "EVENT_GOT_TM39", item = "TM_SWIFT",
      pre = "_Route12Gate2FBrunetteGirlYouCanHaveThisText",
      received = "_Route12Gate2FBrunetteGirlReceivedTM39Text",
      explain = "_Route12Gate2FBrunetteGirlTM39ExplanationText",
      noRoom = "_Route12Gate2FBrunetteGirlTM39NoRoomText",
    }),
  },
}

-- TM41 Softboiled (scripts/CeladonCity.asm, Gramps3)
M.CELADON_CITY = {
  talk = {
    TEXT_CELADONCITY_GRAMPS3 = gift({
      flag = "EVENT_GOT_TM41", item = "TM_SOFTBOILED",
      pre = "_CeladonCityGramps3Text",
      received = "_CeladonCityGramps3ReceivedTM41Text",
      explain = "_CeladonCityGramps3TM41ExplanationText",
      noRoom = "_CeladonCityGramps3TM41NoRoomText",
    }),
  },
}

-- TM35 Metronome (scripts/CinnabarLabMetronomeRoom.asm)
M.CINNABAR_LAB_METRONOME_ROOM = {
  talk = {
    TEXT_CINNABARLABMETRONOMEROOM_SCIENTIST1 = gift({
      flag = "EVENT_GOT_TM35", item = "TM_METRONOME",
      pre = "_CinnabarLabMetronomeRoomScientist1Text",
      received = "_CinnabarLabMetronomeRoomScientist1ReceivedTM35Text",
      explain = "_CinnabarLabMetronomeRoomScientist1TM35ExplanationText",
      noRoom = "_CinnabarLabMetronomeRoomScientist1TM35NoRoomText",
    }),
  },
}

-- TM42 Dream Eater (scripts/ViridianCity.asm, the fisher; no pre text)
M.VIRIDIAN_CITY = {
  talk = {
    TEXT_VIRIDIANCITY_FISHER = gift({
      flag = "EVENT_GOT_TM42", item = "TM_DREAM_EATER",
      received = "_ViridianCityFisherReceivedTM42Text",
      explain = "_ViridianCityFisherTM42ExplanationText",
      noRoom = "_ViridianCityFisherTM42NoRoomText",
    }),
  },
}

-- TM36 Selfdestruct (scripts/SilphCo2F.asm, the rescued worker)
M.SILPH_CO_2F = {
  talk = {
    TEXT_SILPHCO2F_SILPH_WORKER_F = gift({
      flag = "EVENT_GOT_TM36", item = "TM_SELFDESTRUCT",
      received = "_SilphCo2FSilphWorkerFReceivedTM36Text",
      explain = "_SilphCo2FSilphWorkerFTM36ExplanationText",
      noRoom = "_SilphCo2FSilphWorkerFTM36NoRoomText",
    }),
  },
}

-- Free POTION sample (scripts/Route1.asm; the original burns the flag
-- even on a full bag -- we keep the port's kinder halt-and-retry)
M.ROUTE_1 = {
  talk = {
    TEXT_ROUTE1_YOUNGSTER1 = gift({
      flag = "EVENT_GOT_POTION_SAMPLE", item = "POTION",
      pre = "_Route1Youngster1MartSampleText",
      received = "_Route1Youngster1GotPotionText",
      noRoom = "_Route1Youngster1NoRoomText",
      already = "_Route1Youngster1AlsoGotPokeballsText",
    }),
  },
}

-- The three in-game trades the port was missing (data/events/trades.asm
-- indices are 1-based in data/generated/field.lua trades)
M.ROUTE_11_GATE_2F = {
  talk = {
    TEXT_ROUTE11GATE2F_YOUNGSTER = {
      { "face_player" },
      { "trade", 1, "EVENT_TRADED_NIDORINO_FOR_NIDORINA" }, -- TERRY
    },
  },
}

M.ROUTE_18_GATE_2F = {
  talk = {
    TEXT_ROUTE18GATE2F_YOUNGSTER = {
      { "face_player" },
      { "trade", 6, "EVENT_TRADED_SLOWBRO_FOR_LICKITUNG" }, -- MARC
    },
  },
}

M.UNDERGROUND_PATH_ROUTE_5 = {
  talk = {
    TEXT_UNDERGROUNDPATHROUTE5_LITTLE_GIRL = {
      { "face_player" },
      { "trade", 10, "EVENT_TRADED_NIDORAN_M_FOR_NIDORAN_F" }, -- SPOT
    },
  },
}

-- =====================================================================
-- Progression gates and rival ambushes
-- =====================================================================

local function inCoords(coords, x, y)
  for _, c in ipairs(coords) do
    if x == c[1] and y == c[2] then return true end
  end
  return false
end

-- coordinate block: show a line and push the player back one step
local function stepGate(opts)
  return function(game, ow, x, y)
    if not inCoords(opts.coords, x, y) then return false end
    if not opts.blocked(game) then return false end
    require("src.core.Sound").play(game.data, "Denied")
    push(game, text(game)[opts.text] or opts.fallback,
         function() ow:scriptMove(ow.player, opts.push, 1) end)
    return true
  end
end

-- Viridian Gym stays locked until the seven other badges are earned
-- (scripts/ViridianCity.asm ViridianCityCheckGymOpenScript: wObtained-
-- Badges == ~EARTHBADGE at (32,8) shoves the player off the door)
local SEVEN_BADGES = { "BOULDERBADGE", "CASCADEBADGE", "THUNDERBADGE",
                       "RAINBOWBADGE", "SOULBADGE", "MARSHBADGE",
                       "VOLCANOBADGE" }
local viridianGymLock = stepGate({
  coords = { { 32, 8 } },
  blocked = function(game)
    for _, b in ipairs(SEVEN_BADGES) do
      if not game.save.inventory[b] then return true end
    end
    return false
  end,
  text = "_ViridianCityGymLockedText",
  fallback = "The GYM's doors\nare locked...",
  push = "down",
})

-- story.lua's VIRIDIAN_CITY module owns the sleeping-old-man block;
-- chain it behind the gym lock (the registry keeps one onStep per map)
local viridianOldManStep = require("data.scripts.story").VIRIDIAN_CITY.onStep
M.VIRIDIAN_CITY.onStep = function(game, ow, x, y)
  if viridianGymLock(game, ow, x, y) then return true end
  return viridianOldManStep(game, ow, x, y)
end

-- Cinnabar Gym needs the SECRET KEY (scripts/CinnabarIsland.asm)
M.CINNABAR_ISLAND = {
  onStep = stepGate({
    coords = { { 18, 4 } },
    blocked = function(game) return not game.save.inventory.SECRET_KEY end,
    text = "_CinnabarIslandDoorIsLockedText",
    fallback = "The door is\nlocked...",
    push = "down",
  }),
  -- CinnabarIsland_Script line 6: ResetEvent EVENT_LAB_STILL_REVIVING_
  -- FOSSIL on every (re)load of this map -- OverworldState:setMap runs
  -- onEnter on every entry, not just the first, so this fires both
  -- when the player walks out of the fossil lab back onto the island
  -- and on any later re-entry (boat, Mansion exit, etc.), matching the
  -- oracle's every-load map script.  Paired with the deposit/pending/
  -- ready state machine in data/scripts/story2.lua's
  -- TEXT_CINNABARLABFOSSILROOM_SCIENTIST1.
  onEnter = function(game, ow)
    if game.save.flags.EVENT_LAB_STILL_REVIVING_FOSSIL then
      game.save.flags.EVENT_LAB_STILL_REVIVING_FOSSIL = nil
    end
  end,
}

-- Pewter's youngster stops you leaving east before Brock is beaten
-- (scripts/PewterCity.asm PewterCityCheckPlayerLeavingEastScript; the
-- original escorts you to the gym, we walk you back a step)
M.PEWTER_CITY = {
  onStep = function(game, ow, x, y)
    if game.save.flags.EVENT_BEAT_BROCK then return false end
    if not inCoords({ { 35, 17 }, { 36, 17 }, { 37, 18 }, { 37, 19 } }, x, y) then
      return false
    end
    local t = text(game)
    push(game, t._PewterCityYoungsterYoureATrainerFollowMeText
      or "Hey! You're a\ntrainer, right?", function()
      push(game, t._PewterCityYoungsterGoTakeOnBrockText
        or "Go take on BROCK\nat the GYM first!", function()
        ow:scriptMove(ow.player, "left", 1)
      end)
    end)
    return true
  end,
}

-- Rival ambush: show the hidden rival, walk him up to the player, run
-- the battle rows, march him back and hide him.  On a loss the walk is
-- skipped (the blackout rebuilds the map mid-script).
local function runAmbush(game, ow, rows, playerFacing)
  if ow.runner:isRunning() then return false end
  ow.player.facing = playerFacing
  -- the rival encounter sting (MUSIC_MEET_RIVAL); the battle music
  -- takes over and the map theme returns after the victory jingle
  require("src.core.Music").play(game.data, "Music_MeetRival")
  ow.runner:run(rows)
  return true
end

-- Route 22 rival, both visits (scripts/Route22.asm).  pokered arms
-- EVENT_ROUTE22_RIVAL_WANTS_BATTLE in Oak's lab (expired by Pewter
-- Gym) and again in Viridian Gym; we derive the same windows from the
-- surrounding story flags so old saves work too.
local function route22Scene(n, objIndex, objName, oppClass, baseParty, beatFlag, py)
  return {
    { "show_object", "ROUTE_22", objName },                    -- 1
    { "move_npc_to", objIndex, 28, py },                       -- 2
    { "face_object", objIndex, "right" },                      -- 3
    { "show_text", "_Route22RivalBeforeBattleText" .. n },     -- 4
    { "rival_battle", oppClass, baseParty },                   -- 5
    { "jump_if_false", 11 },                                   -- 6
    { "set_flag", beatFlag },                                  -- 7
    { "show_text", "_Route22Rival" .. n .. "DefeatedText" },   -- 8
    { "show_text", "_Route22RivalAfterBattleText" .. n },      -- 9
    { "move_npc_to", objIndex, 25, 5 },                        -- 10
    { "hide_object", "ROUTE_22", objName },                    -- 11
  }
end

M.ROUTE_22 = {
  onStep = function(game, ow, x, y)
    if not inCoords({ { 29, 4 }, { 29, 5 } }, x, y) then return false end
    local f = game.save.flags
    if f.EVENT_GOT_POKEDEX and not f.EVENT_BEAT_BROCK
       and not f.EVENT_BEAT_ROUTE22_RIVAL_1ST_BATTLE then
      return runAmbush(game, ow,
        route22Scene(1, 1, "ROUTE22_RIVAL1", "OPP_RIVAL1", 4,
                     "EVENT_BEAT_ROUTE22_RIVAL_1ST_BATTLE", y), "left")
    end
    if f.EVENT_BEAT_GIOVANNI and not f.EVENT_BEAT_ROUTE22_RIVAL_2ND_BATTLE then
      return runAmbush(game, ow,
        route22Scene(2, 2, "ROUTE22_RIVAL2", "OPP_RIVAL2", 10,
                     "EVENT_BEAT_ROUTE22_RIVAL_2ND_BATTLE", y), "left")
    end
    return false
  end,
}

-- Cerulean City: the Nugget Bridge rival ambush (CeruleanCityCoords2),
-- the TM28 rocket thief with his forced-fight cells (Coords1), and the
-- cave guard who steps aside once you are Champion.
local function ceruleanRivalScene(px, py)
  return {
    { "show_object", "CERULEAN_CITY", "CERULEANCITY_RIVAL" },  -- 1
    { "move_npc_to", 1, px, py - 1 },                          -- 2
    { "face_object", 1, "down" },                              -- 3
    { "show_text", "_CeruleanCityRivalPreBattleText" },        -- 4
    { "rival_battle", "OPP_RIVAL1", 7 },                       -- 5
    { "jump_if_false", 10 },                                   -- 6
    { "set_flag", "EVENT_BEAT_CERULEAN_RIVAL" },               -- 7
    { "show_text", "_CeruleanCityRivalDefeatedText" },         -- 8
    { "move_npc_to", 1, 20, 2 },                               -- 9
    { "hide_object", "CERULEAN_CITY", "CERULEANCITY_RIVAL" },  -- 10
  }
end

-- scripts/CeruleanCity.asm CeruleanCityRocketText: fight the thief,
-- then he returns TM28 (DIG) and hurries off
local rocketRows = {
  { "face_player" },                                           -- 1
  { "check_flag", "EVENT_GOT_TM28" },                          -- 2
  { "jump_if_true", 15 },                                      -- 3
  { "check_flag", "EVENT_BEAT_CERULEAN_ROCKET_THIEF" },        -- 4
  { "jump_if_true", 9 },                                       -- 5
  { "show_text", "_CeruleanCityRocketText" },                  -- 6
  { "start_battle", "trainer", "OPP_ROCKET", 5 },              -- 7
  { "jump_if_false", 18 },                                     -- 8
  { "show_text", "_CeruleanCityRocketIllReturnTheTMText" },    -- 9
  { "set_flag", "EVENT_BEAT_CERULEAN_ROCKET_THIEF" },          -- 10
  { "give_item", "TM_DIG", 1, false },                         -- 11 (row 13 prints)
  { "set_flag", "EVENT_GOT_TM28" },                            -- 12
  { "show_text", "_CeruleanCityRocketReceivedTM28Text" },      -- 13
  { "show_text", "_CeruleanCityRocketIBetterGetMovingText" },  -- 14
  { "hide_object", "CERULEAN_CITY", "CERULEANCITY_ROCKET" },   -- 15
  -- CeruleanHideRocket (scripts/CeruleanCity_2.asm) does all three behind
  -- one fade: the ROCKET goes, GUARD1 (28,12) appears and GUARD2 (27,12)
  -- disappears.  GUARD2 stands on the only walkable neighbour of the
  -- trashed house's south door, which is one of the two ways through the
  -- fence dividing Cerulean, so this swap is what reconnects the city.
  -- Bill's ticket performs the same swap (data/scripts/story.lua), and
  -- both are idempotent, so whichever the player reaches first opens it.
  { "show_object", "CERULEAN_CITY", "CERULEANCITY_GUARD1" },   -- 16
  { "hide_object", "CERULEAN_CITY", "CERULEANCITY_GUARD2" },   -- 17
}

M.CERULEAN_CITY = {
  talk = {
    TEXT_CERULEANCITY_ROCKET = rocketRows,
  },
  onEnter = function(game, ow)
    if game.save.flags.EVENT_BEAT_CHAMPION_RIVAL then
      local Commands = require("src.script.Commands")
      Commands.hide_object({ game = game, save = game.save, overworld = ow },
                           "CERULEAN_CITY", "CERULEANCITY_SUPER_NERD3")
    end
  end,
  onStep = function(game, ow, x, y)
    local f = game.save.flags
    if not f.EVENT_BEAT_CERULEAN_ROCKET_THIEF
       and inCoords({ { 30, 7 }, { 30, 9 } }, x, y) then
      if ow.runner:isRunning() then return false end
      local rocket = ow:npcByIndex(2)
      if rocket then
        ow.player.facing = y < 8 and "down" or "up"
        ow.runner:run(rocketRows, { npc = rocket })
        return true
      end
      return false
    end
    if not f.EVENT_BEAT_CERULEAN_RIVAL
       and inCoords({ { 20, 6 }, { 21, 6 } }, x, y) then
      return runAmbush(game, ow, ceruleanRivalScene(x, y), "up")
    end
    return false
  end,
}

-- The Pewter museum's fossil exhibits (engine/events/hidden_events/
-- museum_fossils.asm: DisplayMonFrontSpriteInBox + the plaque text)
M.MUSEUM_1F = {
  onInteract = function(game, ow, fx, fy)
    if ow.player.facing ~= "up" then return false end
    local PicBox = require("src.ui.PicBox")
    local t = text(game)
    if fx == 2 and fy == 3 then
      game.stack:push(PicBox.new(game,
        "assets/generated/battle/front/fossilaerodactyl.png",
        t._AerodactylFossilText or "AERODACTYL Fossil"))
      return true
    end
    if fx == 2 and fy == 6 then
      game.stack:push(PicBox.new(game,
        "assets/generated/battle/front/fossilkabutops.png",
        t._KabutopsFossilText or "KABUTOPS Fossil"))
      return true
    end
    return false
  end,
}

-- The Pewter Center's singing JIGGLYPUFF (scripts/PewterPokecenter.asm
-- plays MUSIC_JIGGLYPUFF_SONG, then the map theme resumes)
M.PEWTER_POKECENTER = {
  talk = {
    TEXT_PEWTERPOKECENTER_JIGGLYPUFF = function(game, ow, npc, done)
      require("src.core.Music").playOnce(game.data, "Music_JigglypuffSong")
      push(game, text(game)._PewterPokecenterJigglypuffText
        or "JIGGLYPUFF: Puu\npupuu!", done)
    end,
  },
}

-- Cycling Road gate guards (scripts/Route16Gate1F.asm /
-- Route18Gate1F.asm): without a BICYCLE in the bag the guard stops you
-- on the west-side cells and walks you back
local function bikeGateGuard(coords, stopText, explainText)
  return function(game, ow, x, y)
    if game.save.inventory.BICYCLE then return false end
    if not inCoords(coords, x, y) then return false end
    local t = text(game)
    push(game, t[stopText] or "Hey! Wait up!", function()
      push(game, t[explainText] or "You need a\nBICYCLE for\nCYCLING ROAD!", function()
        ow:scriptMove(ow.player, "up", 1)
      end)
    end)
    return true
  end
end

M.ROUTE_16_GATE_1F = {
  onStep = bikeGateGuard(
    { { 4, 7 }, { 4, 8 }, { 4, 9 }, { 4, 10 } },
    "_Route16Gate1FGuardWaitUpText",
    "_Route16Gate1FGuardNoPedestriansAllowedText"),
}

M.ROUTE_18_GATE_1F = {
  onStep = bikeGateGuard(
    { { 4, 3 }, { 4, 4 }, { 4, 5 }, { 4, 6 } },
    "_Route18Gate1FGuardExcuseMeText",
    "_Route18Gate1FGuardYouNeedABicycleText"),
}

-- Silph Co. 7F rival ambush (scripts/SilphCo7F.asm
-- SilphCo7FDefaultScript: coords (3,2)/(3,3), the rival at (3,7) walks
-- up, MUSIC_MEET_RIVAL, OPP_RIVAL2 parties 7-9 by starter, then he
-- wishes you luck, walks off right and disappears; one-time via
-- EVENT_BEAT_SILPH_CO_RIVAL)
M.SILPH_CO_7F = {
  onStep = function(game, ow, x, y)
    if game.save.flags.EVENT_BEAT_SILPH_CO_RIVAL then return false end
    if not inCoords({ { 3, 2 }, { 3, 3 } }, x, y) then return false end
    return runAmbush(game, ow, {
      { "show_object", "SILPH_CO_7F", "SILPHCO7F_RIVAL" },     -- 1
      { "show_text", "_SilphCo7FRivalText" },                  -- 2
      { "move_npc_to", 9, 3, y + 1 },                          -- 3
      { "face_object", 9, "up" },                              -- 4
      { "show_text", "_SilphCo7FRivalWaitedHereText" },        -- 5
      { "rival_battle", "OPP_RIVAL2", 7 },                     -- 6
      { "jump_if_false", 12 },                                 -- 7
      { "set_flag", "EVENT_BEAT_SILPH_CO_RIVAL" },             -- 8
      { "show_text", "_SilphCo7FRivalDefeatedText" },          -- 9
      { "show_text", "_SilphCo7FRivalGoodLuckToYouText" },     -- 10
      { "move_npc_to", 9, 5, y + 1 },                          -- 11
      { "hide_object", "SILPH_CO_7F", "SILPHCO7F_RIVAL" },     -- 12
    }, "down")
  end,
}

-- S.S. Anne 2F rival ambush (scripts/SSAnne2F.asm; coords 36/37,8)
M.SS_ANNE_2F = {
  onStep = function(game, ow, x, y)
    if game.save.flags.EVENT_BEAT_SS_ANNE_RIVAL then return false end
    if not inCoords({ { 36, 8 }, { 37, 8 } }, x, y) then return false end
    local onLeft = x == 36
    return runAmbush(game, ow, {
      { "show_object", "SS_ANNE_2F", "SSANNE2F_RIVAL" },       -- 1
      { "move_npc_to", 2, 36, onLeft and 7 or 8 },             -- 2
      { "face_object", 2, onLeft and "down" or "right" },      -- 3
      { "show_text", "_SSAnne2FRivalText" },                   -- 4
      { "rival_battle", "OPP_RIVAL2", 1 },                     -- 5
      { "jump_if_false", 10 },                                 -- 6
      { "set_flag", "EVENT_BEAT_SS_ANNE_RIVAL" },              -- 7
      { "show_text", "_SSAnne2FRivalDefeatedText" },           -- 8
      { "move_npc_to", 2, 36, 4 },                             -- 9
      { "hide_object", "SS_ANNE_2F", "SSANNE2F_RIVAL" },       -- 10
    }, onLeft and "up" or "left")
  end,
}

return M
