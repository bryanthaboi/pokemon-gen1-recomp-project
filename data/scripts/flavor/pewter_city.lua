-- Pewter City flavor dialogue (pokered/scripts/PewterCity.asm).
-- PewterCity_TextPointers text_asm bodies for the SUPER_NERD1 museum
-- guide and SUPER_NERD2 garden nerd.
--
-- The YOUNGSTER's gym escort (talk + east-exit onStep) lives in
-- story5.lua so the lockstep RLE walk is not overwritten by this
-- flavor merge.  SUPER_NERD1's museum escort is not ported; only the
-- YES/NO-branched flavor text is here.

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

  },
}

return M
