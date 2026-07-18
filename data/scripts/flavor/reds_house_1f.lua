-- Red's House 1F (pokered/scripts/RedsHouse1F.asm).
--
-- TEXT_REDSHOUSE1F_TV (RedsHouse1FTVText): text_asm checks the player's
-- facing direction when interacting with the TV sign -- facing up shows
-- the Stand By Me movie flavor text, any other facing shows the "wrong
-- side" text (you're looking at the back of the TV).

local TextBox = require("src.render.TextBox")

return {
  REDS_HOUSE_1F = {
    talk = {
      TEXT_REDSHOUSE1F_TV = function(game, ow, npc, done)
        local t = game.data.text
        local text
        if ow.player.facing == "up" then
          text = t._RedsHouse1FTVStandByMeMovieText
        else
          text = t._RedsHouse1FTVWrongSideText
        end
        game.stack:push(TextBox.new(game, text, done))
      end,
    },
  },
}
