-- pokered/scripts/Route15Gate2F.asm: Route15Gate2FBinocularsText
-- text_asm just calls GateUpstairsScript_PrintIfFacingUp, which prints
-- the binoculars flavor text (no flags/branches involved).
return {
  ROUTE_15_GATE_2F = {
    talk = {
      -- Route15Gate2FBinocularsText -> .Text -> _Route15Gate2FBinocularsText
      TEXT_ROUTE15GATE2F_BINOCULARS = {
        { "show_text", "_Route15Gate2FBinocularsText" },
      },
    },
  },
}
