-- Route 12 Gate 2F binocular signs (pokered/scripts/Route12Gate2F.asm
-- Route12Gate2FLeftBinocularsText / Route12Gate2FRightBinocularsText ->
-- GateUpstairsScript_PrintIfFacingUp): the binoculars only show their
-- text when the player is facing up (looking through them from below);
-- from any other facing the sign is silently a no-op, same as the
-- original (it just clears wDoNotWaitForButtonPressAfterDisplayingText
-- and returns without printing).
--
-- TEXT_ROUTE12GATE2F_BRUNETTE_GIRL (TM39 SWIFT gift) is intentionally
-- skipped here -- omitted, not ported by this file.

local function push(game, s, done)
  local TextBox = require("src.render.TextBox")
  game.stack:push(TextBox.new(game, s, done))
end

local function binoculars(label)
  return function(game, ow, npc, done)
    done = done or function() end
    if ow.player.facing ~= "up" then
      done()
      return
    end
    local t = game.data.text[label]
    push(game, t, done)
  end
end

return {
  ROUTE_12_GATE_2F = {
    talk = {
      TEXT_ROUTE12GATE2F_LEFT_BINOCULARS = binoculars("_Route12Gate2FLeftBinocularsText"),
      TEXT_ROUTE12GATE2F_RIGHT_BINOCULARS = binoculars("_Route12Gate2FRightBinocularsText"),
    },
  },
}
