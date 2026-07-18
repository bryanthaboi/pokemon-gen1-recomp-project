-- pokered/scripts/Route16Gate2F.asm
-- Route 16 Gate, 2F (overpass) flavor dialogue: little boy, little girl, and
-- both binocular signs. All four are plain text_far bodies (the binoculars'
-- text_asm just jumps into GateUpstairsScript_PrintIfFacingUp, which is a
-- facing-direction gate handled by the overworld sign-interaction system,
-- not extra dialogue branching), so each ports as a single-row talk script.

return {
  ROUTE_16_GATE_2F = {
    talk = {
      -- Route16Gate2FLittleBoyText: text_far _Route16Gate2FLittleBoyText
      TEXT_ROUTE16GATE2F_LITTLE_BOY = {
        { "face_player" },
        { "show_text", "_Route16Gate2FLittleBoyText" },
      },

      -- Route16Gate2FLittleGirlText: text_far _Route16Gate2FLittleGirlText
      TEXT_ROUTE16GATE2F_LITTLE_GIRL = {
        { "face_player" },
        { "show_text", "_Route16Gate2FLittleGirlText" },
      },

      -- Route16Gate2FLeftBinocularsText: text_far _Route16Gate2FLeftBinocularsText
      TEXT_ROUTE16GATE2F_LEFT_BINOCULARS = {
        { "show_text", "_Route16Gate2FLeftBinocularsText" },
      },

      -- Route16Gate2FRightBinocularsText: text_far _Route16Gate2FRightBinocularsText
      TEXT_ROUTE16GATE2F_RIGHT_BINOCULARS = {
        { "show_text", "_Route16Gate2FRightBinocularsText" },
      },
    },
  },
}
