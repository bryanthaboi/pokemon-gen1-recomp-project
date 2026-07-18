-- Viridian City flavor dialogue (pokered/scripts/ViridianCity.asm).
-- Ports the text_asm bodies for GAMBLER1, YOUNGSTER2, GIRL and OLD_MAN.
--
-- Not ported here (already handled elsewhere / not talk-reachable):
--  * TEXT_VIRIDIANCITY_FISHER (TM42 gift) -- already ported as a
--    `gift()` entry in data/scripts/story5.lua's M.VIRIDIAN_CITY.talk.
--  * TEXT_VIRIDIANCITY_OLD_MAN_SLEEPY / TEXT_VIRIDIANCITY_GYM_LOCKED --
--    these are step-triggered blocking texts (ViridianCityCheckGotPokedexScript /
--    ViridianCityCheckGymOpenScript), not npc talk text_asm bodies; the
--    gates themselves are already implemented via story5.lua's onStep
--    chain (viridianOldManStep / viridianGymLock) for this map.
--  * The old man's catch-training minigame trigger (SCRIPT_VIRIDIANCITY_
--    OLD_MAN_START_CATCH_TRAINING / battle vs. WEEDLE) is a full
--    scripted-battle cutscene outside this task's Commands vocabulary
--    (no static_battle-style "battle a scripted old-man WEEDLE" command
--    exists); we port the real YES/NO branch text he speaks but the
--    "yes" branch here just shows the "I'll show you how" line rather
--    than actually starting the minigame, since that machinery isn't
--    ported to this map yet.

local M = {}

local function text(game) return game.data.text end

local function push(game, s, done)
  local TextBox = require("src.render.TextBox")
  game.stack:push(TextBox.new(game, s, done))
end

local function ask(game, s, cb)
  local ChoiceBox = require("src.ui.ChoiceBox")
  push(game, s, function() game.stack:push(ChoiceBox.new(game, cb)) end)
end

M.VIRIDIAN_CITY = {
  talk = {
    -- ViridianCityGambler1Text (scripts/ViridianCity.asm): normally
    -- comments that the gym is "always closed"; once the 7th badge is
    -- earned (badges == ~EARTHBADGE) but Giovanni hasn't been beaten
    -- yet, he instead says the gym leader returned.
    TEXT_VIRIDIANCITY_GAMBLER1 = function(game, ow, npc, done)
      local t = text(game)
      local sevenBadges = game.save.inventory and
        game.save.inventory.BOULDERBADGE and game.save.inventory.CASCADEBADGE
        and game.save.inventory.THUNDERBADGE and game.save.inventory.RAINBOWBADGE
        and game.save.inventory.SOULBADGE and game.save.inventory.MARSHBADGE
        and game.save.inventory.VOLCANOBADGE
      -- (pokered checks EVENT_BEAT_VIRIDIAN_GYM_GIOVANNI; the port's flag for
      -- that win is EVENT_BEAT_GIOVANNI, set by victories.lua OPP_GIOVANNI#3)
      if sevenBadges and not (game.save.flags and game.save.flags.EVENT_BEAT_GIOVANNI) then
        push(game, t._ViridianCityGambler1GymLeaderReturnedText
          or "VIRIDIAN GYM's\nLEADER returned!", done)
      else
        push(game, t._ViridianCityGambler1GymAlwaysClosedText
          or "This POKéMON GYM\nis always closed.\nI wonder who the\nLEADER is?", done)
      end
    end,

    -- ViridianCityYoungster2Text (scripts/ViridianCity.asm): asks if
    -- you want to know about the two kinds of caterpillar Pokemon;
    -- YES -> CATERPIE/WEEDLE description, NO -> "Oh, OK then!".
    -- ViridianCityYoungster2OkThenText and
    -- ViridianCityYoungster2CaterpieAndWeedleDescriptionText are
    -- defined without a leading underscore in pokered/text/ViridianCity.asm
    -- and aren't present in data/generated/text.lua, so we fall back to
    -- the literal strings from pokered.
    TEXT_VIRIDIANCITY_YOUNGSTER2 = function(game, ow, npc, done)
      local t = text(game)
      ask(game, t._ViridianCityYoungster2YouWantToKnowAboutText
        or "You want to know\nabout the 2 kinds\nof caterpillar\nPOKéMON?", function(yes)
        if yes then
          push(game, "CATERPIE has no\npoison, but\nWEEDLE does.\n\nWatch out for its\nPOISON STING!", done)
        else
          push(game, "Oh, OK then!", done)
        end
      end)
    end,

    -- ViridianCityGirlText (scripts/ViridianCity.asm): before the
    -- player has the Pokedex she scolds her grandpa for being mean
    -- (he hasn't had his coffee yet); after EVENT_GOT_POKEDEX she talks
    -- about the winding trail through Viridian Forest to Pewter.
    TEXT_VIRIDIANCITY_GIRL = function(game, ow, npc, done)
      local t = text(game)
      if game.save.flags and game.save.flags.EVENT_GOT_POKEDEX then
        push(game, t._ViridianCityGirlWhenIGoShopText
          or "When I go shop in\nPEWTER CITY, I\nhave to take the\nwinding trail in\nVIRIDIAN FOREST.", done)
      else
        push(game, t._ViridianCityGirlHasntHadHisCoffeeYetText
          or "Oh Grandpa! Don't\nbe so mean!\nHe hasn't had his\ncoffee yet.", done)
      end
    end,

    -- ViridianCityOldManText (scripts/ViridianCity.asm): once he's had
    -- his coffee, he asks (YES/NO) whether you want to learn how to
    -- catch Pokemon. YES leads into the catch-training minigame
    -- (SCRIPT_VIRIDIANCITY_OLD_MAN_START_CATCH_TRAINING, not ported --
    -- see file header); NO just brushes you off ("Time is money...").
    TEXT_VIRIDIANCITY_OLD_MAN = function(game, ow, npc, done)
      local t = text(game)
      ask(game, t._ViridianCityOldManHadMyCoffeeNowText
        or "Ahh, I've had my\ncoffee now and I\nfeel great!\nSure you can go\nthrough!\nAre you in a\nhurry?", function(yes)
        if yes then
          push(game, t._ViridianCityOldManKnowHowToCatchPokemonText
            or "I see you're using\na POKéDEX.\nWhen you catch a\nPOKéMON, POKéDEX\nis automatically\nupdated.\nWhat? Don't you\nknow how to catch\nPOKéMON?\nI'll show you\nhow to then.", done)
        else
          push(game, t._ViridianCityOldManTimeIsMoneyText
            or "Time is money...\nGo along then.", done)
        end
      end)
    end,
  },
}

return M
