-- Pewter City flavor dialogue (pokered/scripts/PewterCity.asm).
-- PewterCity_TextPointers text_asm bodies for the SUPER_NERD1 museum
-- guide, SUPER_NERD2 garden nerd, and the leaving-east YOUNGSTER.
--
-- The escort choreography (SUPER_NERD1 walking the player to the
-- museum, YOUNGSTER walking the player to the gym) is scripted NPC
-- movement + a wPewterCityCurScript state machine that steers the
-- player off-map; that part is already covered on this map by
-- story5.lua's onStep gate (walks the player back a step at the
-- east exit before EVENT_BEAT_BROCK). Here we only port the real
-- YES/NO-branched flavor text these NPCs speak when talked to.

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

M.PEWTER_CITY = {
  talk = {
    -- PewterCitySuperNerd1Text (scripts/PewterCity.asm): asks if you
    -- checked out the museum; YES -> fossils comment, NO -> "you have
    -- to go" (which in pokered also kicks off the escort script).
    TEXT_PEWTERCITY_SUPER_NERD1 = function(game, ow, npc, done)
      local t = text(game)
      ask(game, t._PewterCitySuperNerd1DidYouCheckOutMuseumText
        or "Did you check out\nthe MUSEUM?", function(yes)
        if yes then
          push(game, t._PewterCitySuperNerd1WerentThoseFossilsAmazingText
            or "Weren't those\nfossils from MT.\nMOON amazing?", done)
        else
          push(game, t._PewterCitySuperNerd1YouHaveToGoText
            or "Really?\nYou absolutely\nhave to go!", done)
        end
      end)
    end,

    -- PewterCitySuperNerd2Text (scripts/PewterCity.asm): asks if you
    -- know what he's doing; YES -> "that's right", NO -> reveals he's
    -- spraying Repel to keep Pokemon out of his garden.
    TEXT_PEWTERCITY_SUPER_NERD2 = function(game, ow, npc, done)
      local t = text(game)
      ask(game, t._PewterCitySuperNerd2DoYouKnowWhatImDoingText
        or "Psssst!\nDo you know what\nI'm doing?", function(yes)
        if yes then
          push(game, t._PewterCitySuperNerd2ThatsRightText
            or "That's right!\nIt's hard work!", done)
        else
          push(game, t._PewterCitySuperNerd2ImSprayingRepelText
            or "I'm spraying REPEL\nto keep POKéMON\nout of my garden!", done)
        end
      end)
    end,

    -- PewterCityYoungsterText (scripts/PewterCity.asm): the "follow
    -- me" line the youngster says when the player is stopped from
    -- leaving Pewter east before beating Brock; the actual gate/step
    -- block is handled by story5.lua's onStep for this map.
    TEXT_PEWTERCITY_YOUNGSTER = function(game, ow, npc, done)
      local t = text(game)
      push(game, t._PewterCityYoungsterYoureATrainerFollowMeText
        or "You're a trainer\nright? BROCK's\nlooking for new\nchallengers!\nFollow me!", done)
    end,
  },
}

return M
