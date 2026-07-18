-- CeladonMansion1F flavor talk scripts (pokered/scripts/CeladonMansion1F.asm)
return {
  CELADON_MANSION_1F = {
    talk = {
      -- CeladonMansion1FClefairyText (scripts/CeladonMansion1F.asm): text_far
      -- _CeladonMansion1FClefairyText, then plays the CLEFAIRY cry and ends.
      -- The cry playback has no port-side equivalent command, so we just
      -- show the flavor line.
      TEXT_CELADONMANSION1F_CLEFAIRY = {
        {"face_player"},
        {"show_text", "_CeladonMansion1FClefairyText"},
      },

      -- CeladonMansion1FMeowthText (scripts/CeladonMansion1F.asm): text_far
      -- _CeladonMansion1FMeowthText, then plays the MEOWTH cry and ends.
      -- The cry playback has no port-side equivalent command, so we just
      -- show the flavor line.
      TEXT_CELADONMANSION1F_MEOWTH = {
        {"face_player"},
        {"show_text", "_CeladonMansion1FMeowthText"},
      },

      -- CeladonMansion1FNidoranFText (scripts/CeladonMansion1F.asm): text_far
      -- _CeladonMansion1FNidoranFText, then plays the NIDORAN_F cry and ends.
      -- The cry playback has no port-side equivalent command, so we just
      -- show the flavor line.
      TEXT_CELADONMANSION1F_NIDORANF = {
        {"face_player"},
        {"show_text", "_CeladonMansion1FNidoranFText"},
      },
    },
  },
}
