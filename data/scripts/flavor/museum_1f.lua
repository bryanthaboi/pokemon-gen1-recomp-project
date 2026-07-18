-- Museum 1F flavor dialogue (pokered scripts/Museum1F.asm).
-- TEXT_MUSEUM1F_SCIENTIST1 and TEXT_MUSEUM1F_OLD_AMBER are already
-- handled in data/scripts/story2.lua (M.MUSEUM_1F, the ticket-gate
-- onStep + amber-pickup talk handler) -- not re-ported here.

return {
  MUSEUM_1F = {
    talk = {
      -- Museum1FGamblerText: plain text_asm, single text_far line.
      TEXT_MUSEUM1F_GAMBLER = {
        { "face_player" },
        { "show_text", "_Museum1FGamblerText" },
      },

      -- Museum1FScientist2Text: CheckEvent EVENT_GOT_OLD_AMBER branch.
      -- Not yet gotten -> pitch text, GiveItem OLD_AMBER (bag-full
      -- refusal -> YouDontHaveSpaceText, no flag/received text), on
      -- success SetEvent + predef HideObject (TOGGLE_OLD_AMBER, so the
      -- OLD_AMBER sprite object on this map also disappears) +
      -- ReceivedOldAmberText.  Already gotten -> GetTheOldAmberCheckText.
      TEXT_MUSEUM1F_SCIENTIST2 = function(game, ow, npc, done)
        local TextBox = require("src.render.TextBox")
        local Commands = require("src.script.Commands")
        local t = game.data.text
        local function say(label, cb)
          game.stack:push(TextBox.new(game, t[label] or label, cb))
        end

        if game.save.flags.EVENT_GOT_OLD_AMBER then
          say("_Museum1FScientist2GetTheOldAmberCheckText", done)
          return
        end

        say("_Museum1FScientist2TakeThisToAPokemonLabText", function()
          if not require("src.inventory.Bag").add(game.save, "OLD_AMBER", 1) then
            say("_Museum1FScientist2YouDontHaveSpaceText", done)
            return
          end
          game.save.flags.EVENT_GOT_OLD_AMBER = true
          Commands.hide_object({ save = game.save, overworld = ow, game = game },
                                "MUSEUM_1F", "MUSEUM1F_OLD_AMBER")
          require("src.core.Sound").play(game.data, "Get_Item1")
          say("_Museum1FScientist2ReceivedOldAmberText", done)
        end)
      end,

      -- Museum1FScientist3Text: plain text_asm, single text_far line.
      TEXT_MUSEUM1F_SCIENTIST3 = {
        { "face_player" },
        { "show_text", "_Museum1FScientist3Text" },
      },
    },
  },
}
