-- Flavor talk scripts for Copycat's House 1F (pokered/scripts/CopycatsHouse1F.asm)
return {
  COPYCATS_HOUSE_1F = {
    talk = {
      -- CopycatsHouse1FChanseyText: text_far _CopycatsHouse1FChanseyText, then
      -- text_asm plays the CHANSEY cry (ld a, CHANSEY / call PlayCry) before
      -- ending. The port has no cry-playback command exposed to scripts, so
      -- only the flavor text is ported.
      TEXT_COPYCATSHOUSE1F_CHANSEY = {
        { "show_text", "_CopycatsHouse1FChanseyText" },
      },
    },
  },
}
