-- Route 11 Gate, 2F (pokered/scripts/Route11Gate2F.asm)
--
-- TEXT_ROUTE11GATE2F_YOUNGSTER (in-game trade) and TEXT_ROUTE11GATE2F_OAKS_AIDE
-- (Oak's Aide itemfinder handout) are not ported here; only the two window
-- signs are in scope for this pass.
--
-- Both binocular signs use GateUpstairsScript_PrintIfFacingUp: the sign only
-- shows text when the player is facing UP (looking out the window); reading
-- it from any other direction prints nothing.

return {
  ROUTE_11_GATE_2F = {
    talk = {
      -- Route11Gate2FLeftBinocularsText (scripts/Route11Gate2F.asm): only
      -- fires facing up; then branches on EVENT_BEAT_ROUTE12_SNORLAX to show
      -- either the "big POKéMON asleep on a road" or the "beautiful view"
      -- flavor text.
      TEXT_ROUTE11GATE2F_LEFT_BINOCULARS = function(game, ow, npc, done)
        if ow.player.facing ~= "up" then
          done()
          return
        end
        local TextBox = require("src.render.TextBox")
        local label = game.save.flags.EVENT_BEAT_ROUTE12_SNORLAX
            and "_Route11Gate2FLeftBinocularsNoSnorlaxText"
            or "_Route11Gate2FLeftBinocularsSnorlaxText"
        game.stack:push(TextBox.new(game, game.data.text[label], done))
      end,

      -- Route11Gate2FRightBinocularsText (scripts/Route11Gate2F.asm): only
      -- fires facing up; describes the Cerulean-to-Lavender route via Rock
      -- Tunnel.
      TEXT_ROUTE11GATE2F_RIGHT_BINOCULARS = function(game, ow, npc, done)
        if ow.player.facing ~= "up" then
          done()
          return
        end
        local TextBox = require("src.render.TextBox")
        game.stack:push(TextBox.new(game, game.data.text["_Route11Gate2FRightBinocularsText"], done))
      end,
    },
  },
}
