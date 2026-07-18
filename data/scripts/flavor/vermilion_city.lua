-- Hand-ported text_asm dialogue for VermilionCity NPCs.
-- pokered/scripts/VermilionCity.asm

return {
  VERMILION_CITY = {
    talk = {
      -- VermilionCityGambler1Text: before the S.S. Anne departs he asks
      -- if you saw it moored in the harbor; after it leaves he remarks
      -- that it's gone and will return in about a year.
      -- (pokered/scripts/VermilionCity.asm)
      TEXT_VERMILIONCITY_GAMBLER1 = {
        { "check_flag", "EVENT_SS_ANNE_LEFT" },                          -- 1
        { "jump_if_true", 5 },                                           -- 2
        { "show_text", "_VermilionCityGambler1DidYouSeeText" },          -- 3
        { "jump", 6 },                                                   -- 4
        { "show_text", "_VermilionCityGambler1SSAnneDepartedText" },     -- 5
      },

      -- VermilionCityMachopText: cries out, then follows up with a
      -- second line about stomping the land flat.
      -- (pokered/scripts/VermilionCity.asm)
      TEXT_VERMILIONCITY_MACHOP = {
        { "show_text", "_VermilionCityMachopText" },                     -- 1
        { "show_text", "_VermilionCityMachopStompingTheLandFlatText" },  -- 2
      },
    },
  },
}
