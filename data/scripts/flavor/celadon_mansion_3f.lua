-- Celadon Mansion 3F Game Designer (pokered/scripts/CeladonMansion3F.asm
-- CeladonMansion3FGameDesignerText): text_asm counts set bits in
-- wPokedexOwned and compares against NUM_POKEMON - 1 (discounts Mew).
-- If the player owns >= 150 species, shows the "completed" text
-- (originally followed by DisplayDiploma, which has no equivalent UI
-- in this port, so we just show the congratulatory text); otherwise
-- shows the normal encouragement text.
return {
  CELADON_MANSION_3F = {
    talk = {
      TEXT_CELADONMANSION3F_GAME_DESIGNER = function(game, ow, npc, done)
        local t = game.data.text
        local dex = game.save.pokedex
        local owned = 0
        if dex and dex.owned then
          for _ in pairs(dex.owned) do
            owned = owned + 1
          end
        end
        -- NUM_POKEMON - 1 = 150 (discounts Mew, per pokered)
        local label, fallback
        if owned >= 150 then
          label, fallback = "_CeladonMansion3FGameDesignerCompletedDexText",
            "Wow! Excellent!\nYou completed\nyour POKeDEX!\nCongratulations!"
        else
          label, fallback = "_CeladonMansion3FGameDesignerText",
            "Is that right?\nI'm the game\ndesigner!\nFilling up your\nPOKeDEX is tough,\nbut don't quit!\nWhen you finish,\ncome tell me!"
        end
        local TextBox = require("src.render.TextBox")
        game.stack:push(TextBox.new(game, t[label] or fallback, done))
      end,
    },
  },
}
