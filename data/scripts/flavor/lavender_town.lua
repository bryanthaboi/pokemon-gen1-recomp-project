-- Hand-ported text_asm dialogue for LavenderTown.
-- Source: pokered/scripts/LavenderTown.asm, pokered/text/LavenderTown.asm

return {
  LAVENDER_TOWN = {
    talk = {
      -- LavenderTownLittleGirlText (pokered/scripts/LavenderTown.asm):
      --   asks "Do you believe in GHOSTs?" via YesNoChoice; on YES shows
      --   "Really? So there are believers...", on NO shows
      --   "Hahaha, I guess not. That white hand on your shoulder, it's not real."
      TEXT_LAVENDERTOWN_LITTLE_GIRL = {
        { "face_player" },                                                   -- [1]
        { "ask", "_LavenderTownLittleGirlDoYouBelieveInGhostsText" },        -- [2]
        { "jump_if_true", 6 },                                               -- [3] YES -> believers text (row 6)
        { "show_text", "_LavenderTownLittleGirlHaHaGuessNotText" },          -- [4] NO path
        { "jump", 99 },                                                      -- [5] end (skip believers text below)
        { "show_text", "_LavenderTownLittleGirlSoThereAreBelieversText" },   -- [6] YES path
      },
    },
  },
}
