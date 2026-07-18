-- Route 18 Gate, 2F (pokered/scripts/Route18Gate2F.asm)
--
-- The two binocular signs only show their flavor text when the player
-- is facing up when they interact with them (GateUpstairsScript_
-- PrintIfFacingUp checks wSpritePlayerStateData1FacingDirection ==
-- SPRITE_FACING_UP; if not, it silently ends the text script without
-- printing anything). TEXT_ROUTE18GATE2F_YOUNGSTER (the in-game trade)
-- is skipped here: it's the generic DoInGameTradeDialogue path already
-- covered by the shared `trade` command/example, not map-specific logic.

local M = {}

local function printIfFacingUp(label)
  return function(game, ow, npc, done)
    if ow.player.facing ~= "up" then
      done()
      return
    end
    local TextBox = require("src.render.TextBox")
    local t = game.data.text
    game.stack:push(TextBox.new(game, t[label] or "", done))
  end
end

M.ROUTE_18_GATE_2F = {
  talk = {
    -- Route18Gate2FLeftBinocularsText: text_far _Route18Gate2FLeftBinocularsText
    TEXT_ROUTE18GATE2F_LEFT_BINOCULARS = printIfFacingUp("_Route18Gate2FLeftBinocularsText"),
    -- Route18Gate2FRightBinocularsText: text_far _Route18Gate2FRightBinocularsText
    TEXT_ROUTE18GATE2F_RIGHT_BINOCULARS = printIfFacingUp("_Route18Gate2FRightBinocularsText"),
  },
}

return M
