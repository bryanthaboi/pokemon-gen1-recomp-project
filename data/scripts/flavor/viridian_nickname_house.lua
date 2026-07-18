-- Viridian Nickname House (pokered/scripts/ViridianNicknameHouse.asm).

return {
  VIRIDIAN_NICKNAME_HOUSE = {
    talk = {
      -- ViridianNicknameHouseSpearowText: text_asm that shows the text
      -- then plays a SPEAROW cry (PlayCry/WaitForSoundToFinish). The
      -- cry playback isn't in the talk-script command vocabulary, so
      -- only the flavor line is ported here.
      TEXT_VIRIDIANNICKNAMEHOUSE_SPEAROW = {
        { "show_text", "_ViridianNicknameHouseSpearowText" },
      },
    },
  },
}
