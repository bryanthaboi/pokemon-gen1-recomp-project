-- Flavor dialogue for LavenderMart (pokered/scripts/LavenderMart.asm)
return {
  LAVENDER_MART = {
    talk = {
      -- LavenderMartCooltrainerMText (pokered/scripts/LavenderMart.asm):
      -- before EVENT_RESCUED_MR_FUJI: talks about REVIVE; after: talks about
      -- the NUGGET he found.
      TEXT_LAVENDERMART_COOLTRAINER_M = {
        { "face_player" },
        { "check_flag", "EVENT_RESCUED_MR_FUJI" },
        { "jump_if_true", 5 },
        { "show_text", "_LavenderMartCooltrainerMReviveText" },
        { "jump", 6 },
        { "show_text", "_LavenderMartCooltrainerMNuggetText" },
      },
    },
  },
}
