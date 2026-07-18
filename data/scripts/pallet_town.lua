-- Hand-ported from pret/pokered scripts/PalletTown.asm.
--
-- Only Oak needs a talk script: PalletTownOakText (scripts/
-- PalletTown.asm:163) is a text_asm branch on wOakWalkedToPlayer showing
-- either _PalletTownOakHeyWaitDontGoOutText or _PalletTownOakItsUnsafeText;
-- we branch on the starter flag, which tracks it.  The intro cutscene
-- itself (Oak stopping the player and walking them to the lab) is the
-- PALLET_TOWN onStep in data/scripts/story2.lua.
--
-- The girl, fisher and the four signs resolve automatically through the
-- extracted text pointers (no script needed).

return {
  talk = {
    TEXT_PALLETTOWN_OAK = {
      { "face_player" },                                    -- 1
      { "check_flag", "EVENT_GOT_STARTER" },                -- 2
      { "jump_if_true", 6 },                                -- 3
      { "show_text", "_PalletTownOakHeyWaitDontGoOutText" },-- 4
      { "jump", 7 },                                        -- 5
      { "show_text", "_PalletTownOakItsUnsafeText" },       -- 6
    },
  },
}
