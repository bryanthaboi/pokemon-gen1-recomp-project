-- Route16Gate1F (pokered/scripts/Route16Gate1F.asm, Route16Gate1FGuardText)
--
-- TEXT_ROUTE16GATE1F_GUARD: talking to the gate guard directly (as
-- opposed to walking into his blocking coords, which is already
-- handled by story5.lua's ROUTE_16_GATE_1F onStep bikeGateGuard).
-- text_asm calls Route16Gate1FIsBicycleInBagScript (IsItemInBag
-- BICYCLE) and shows the Cycling Road explanation if the player has a
-- BICYCLE, or the "no pedestrians allowed" text otherwise.
return {
  ROUTE_16_GATE_1F = {
    talk = {
      TEXT_ROUTE16GATE1F_GUARD = {
        { "face_player" },
        { "check_item", "BICYCLE" },
        { "jump_if_true", 5 },
        { "show_text", "_Route16Gate1FGuardNoPedestriansAllowedText" },
        { "jump", 6 },
        { "show_text", "_Route16Gate1FGuardCyclingRoadExplanationText" },
      },
    },
  },
}
