-- Flavor talk scripts for CopycatsHouse2F (registry id COPYCATS_HOUSE_2F).
-- Source: pokered/scripts/CopycatsHouse2F.asm, pokered/text/CopycatsHouse2F.asm
--
-- TEXT_COPYCATSHOUSE2F_COPYCAT is already ported (with the POKE DOLL /
-- TM31 MIMIC trade) in data/scripts/story4.lua, so it is intentionally
-- omitted here.

return {
  COPYCATS_HOUSE_2F = {
    talk = {
      -- CopycatsHouse2FPCText (scripts/CopycatsHouse2F.asm):
      --   only shows "My Secrets!" when the player is facing UP at the
      --   PC (i.e. actually looking at the screen); any other facing
      --   gets the generic "Huh? Can't see!" text.
      TEXT_COPYCATSHOUSE2F_PC = function(game, ow, npc, done)
        local TextBox = require("src.render.TextBox")
        local t = game.data.text
        local facing = ow and ow.player and ow.player.facing
        local label = (facing == "up")
          and "_CopycatsHouse2FPCMySecretsText"
          or "_CopycatsHouse2FPCCantSeeText"
        game.stack:push(TextBox.new(game, t[label], done))
      end,
    },
  },
}
