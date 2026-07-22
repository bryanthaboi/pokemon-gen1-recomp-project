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

-- Once the HALL OF FAME has been reached (EVENT_BEAT_CHAMPION_RIVAL, set
-- alongside Commands.record_hall_of_fame) Oak offers the ProfOakData
-- battle (data/trainers/parties.asm) -- three teams picked by the
-- player's starter, mirroring the rival's type-advantage lineup, that go
-- unused in the original ROM.
return {
  talk = {
    TEXT_PALLETTOWN_OAK = {
      { "face_player" },                                             -- 1
      { "check_flag", "EVENT_BEAT_CHAMPION_RIVAL" },                 -- 2
      { "jump_if_false", 20 },                                       -- 3
      { "check_flag", "EVENT_BEAT_PROF_OAK" },                       -- 4
      { "jump_if_true", 20 },                                        -- 5
      { "show_text", "OAK: So you want\nto test your\nskills on me?\f"
        .. "Very well! Let\nme show you what\na real trainer\ncan do!" }, -- 6
      { "check_flag", "EVENT_CHOSE_BULBASAUR" },                     -- 7
      { "jump_if_false", 11 },                                       -- 8
      { "start_battle", "trainer", "OPP_PROF_OAK", 3 },              -- 9  CHARIZARD
      { "jump", 16 },                                                -- 10
      { "check_flag", "EVENT_CHOSE_SQUIRTLE" },                      -- 11
      { "jump_if_false", 15 },                                       -- 12
      { "start_battle", "trainer", "OPP_PROF_OAK", 2 },              -- 13 VENUSAUR
      { "jump", 16 },                                                -- 14
      { "start_battle", "trainer", "OPP_PROF_OAK", 1 },              -- 15 BLASTOISE
      { "jump_if_false", "end" },                                    -- 16
      { "set_flag", "EVENT_BEAT_PROF_OAK" },                         -- 17
      { "show_text", "OAK: Impressive!\nYou truly are a\nPOKéMON MASTER!" }, -- 18
      { "jump", "end" },                                             -- 19
      { "check_flag", "EVENT_GOT_STARTER" },                         -- 20
      { "jump_if_true", 24 },                                        -- 21
      { "show_text", "_PalletTownOakHeyWaitDontGoOutText" },         -- 22
      { "jump", "end" },                                             -- 23
      { "show_text", "_PalletTownOakItsUnsafeText" },                -- 24
    },
  },
}
