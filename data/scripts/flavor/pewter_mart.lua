-- Flavor talk scripts for PEWTER_MART (pokered/scripts/PewterMart.asm)

return {
  PEWTER_MART = {
    talk = {
      -- PewterMartYoungsterText: text_asm -> single text_far _PewterMartYoungsterText
      TEXT_PEWTERMART_YOUNGSTER = {
        { "face_player" },
        { "show_text", "_PewterMartYoungsterText" },
      },

      -- PewterMartSuperNerdText: text_asm -> single text_far _PewterMartSuperNerdText
      TEXT_PEWTERMART_SUPER_NERD = {
        { "face_player" },
        { "show_text", "_PewterMartSuperNerdText" },
      },
    },
  },
}
