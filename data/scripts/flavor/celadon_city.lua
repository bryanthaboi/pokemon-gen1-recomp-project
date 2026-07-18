-- CeladonCity flavor talk scripts (pokered/scripts/CeladonCity.asm)
return {
  CELADON_CITY = {
    talk = {
      -- CeladonCityPoliwrathText (scripts/CeladonCity.asm): text_far
      -- _CeladonCityPoliwrathText, then plays the POLIWRATH cry and ends.
      -- The cry playback has no port-side equivalent command, so we just
      -- show the flavor line.
      TEXT_CELADONCITY_POLIWRATH = {
        {"face_player"},
        {"show_text", "_CeladonCityPoliwrathText"},
      },
    },
  },
}
