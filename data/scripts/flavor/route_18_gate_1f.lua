-- Route18Gate1F (pokered/scripts/Route18Gate1F.asm, Route18Gate1FGuardText)
--
-- TEXT_ROUTE18GATE1F_GUARD: talking to the gate guard directly (as
-- opposed to walking into his blocking coords, which triggers
-- TEXT_ROUTE18GATE1F_GUARD_EXCUSE_ME plus scripted movement -- not
-- ported here since that's a separate constant/flow, not a talk).
-- text_asm calls Route16Gate1FIsBicycleInBagScript (IsItemInBag
-- BICYCLE) and shows the "Cycling Road is all uphill from here" text
-- if the player has a BICYCLE, or "You need a BICYCLE for CYCLING
-- ROAD!" otherwise.
return {
  ROUTE_18_GATE_1F = {
    talk = {
      TEXT_ROUTE18GATE1F_GUARD = {
        { "face_player" },
        { "check_item", "BICYCLE" },
        { "jump_if_true", 5 },
        { "show_text", "_Route18Gate1FGuardYouNeedABicycleText" },
        { "jump", 6 },
        { "show_text", "_Route18Gate1FGuardCyclingRoadUphillText" },
      },
    },
  },
}
