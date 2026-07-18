-- pokered/scripts/WardensHouse.asm: WardensHouseDisplayText branches on
-- hTextID (TEXT_WARDENSHOUSE_DISPLAY_LEFT vs _RIGHT) to pick which of the
-- two display case texts to print. TEXT_WARDENSHOUSE_WARDEN is already
-- ported in data/scripts/story.lua (M.WARDENS_HOUSE); not re-ported here.
return {
  WARDENS_HOUSE = {
    talk = {
      -- left case: photos and fossils
      TEXT_WARDENSHOUSE_DISPLAY_LEFT = {
        { "face_player" },                                            -- 1
        { "show_text", "_WardensHouseDisplayPhotosAndFossilsText" },   -- 2
      },
      -- right case: old pokemon merchandise
      TEXT_WARDENSHOUSE_DISPLAY_RIGHT = {
        { "face_player" },                                          -- 1
        { "show_text", "_WardensHouseDisplayMerchandiseText" },      -- 2
      },
    },
  },
}
