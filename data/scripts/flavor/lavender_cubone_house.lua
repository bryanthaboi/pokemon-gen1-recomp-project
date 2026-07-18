-- Lavender Cubone House flavor talk scripts.
-- Source: pokered/scripts/LavenderCuboneHouse.asm

return {
  LAVENDER_CUBONE_HOUSE = {
    talk = {
      -- LavenderCuboneHouseCuboneText: text_far _LavenderCuboneHouseCuboneText,
      -- then text_asm plays the CUBONE cry. Cry playback has no Commands
      -- equivalent in this port, so just show the line.
      TEXT_LAVENDERCUBONEHOUSE_CUBONE = {
        { "face_player" },
        { "show_text", "_LavenderCuboneHouseCuboneText" },
      },

      -- LavenderCuboneHouseBrunetteGirlText: text_asm branches on
      -- EVENT_RESCUED_MR_FUJI -- before the event, she laments Cubone's
      -- mother; after, she's relieved the Ghost of Pokemon Tower is gone.
      TEXT_LAVENDERCUBONEHOUSE_BRUNETTE_GIRL = {
        { "face_player" },                                                    -- 1
        { "check_flag", "EVENT_RESCUED_MR_FUJI" },                            -- 2
        { "jump_if_true", 6 },                                                -- 3
        { "show_text", "_LavenderCuboneHouseBrunetteGirlPoorCubonesMotherText" }, -- 4
        { "jump", 7 },                                                        -- 5
        { "show_text", "_LavenderCuboneHouseBrunetteGirlGhostIsGoneText" },   -- 6 (target of jump_if_true)
      },
    },
  },
}
