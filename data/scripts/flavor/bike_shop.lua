-- BikeShop (BIKE_SHOP) flavor dialogue
-- Source: pokered/scripts/BikeShop.asm, pokered/text/BikeShop.asm
--
-- TEXT_BIKESHOP_CLERK is skipped: it drives the actual voucher-for-bicycle
-- exchange (YesNoChoice purchase menu, GiveItem, RemoveItemByID, SetEvent
-- EVENT_GOT_BICYCLE). That is a significant standalone feature outside the
-- scope of these two flavor NPCs and is left unported here.

return {
  BIKE_SHOP = {
    talk = {
      -- BikeShopMiddleAgedWomanText (pokered/scripts/BikeShop.asm):
      -- always shows the same flavor line, no branching.
      TEXT_BIKESHOP_MIDDLE_AGED_WOMAN = {
        { "face_player" },
        { "show_text", "_BikeShopMiddleAgedWomanText" },
      },

      -- BikeShopYoungsterText (pokered/scripts/BikeShop.asm):
      -- CheckEvent EVENT_GOT_BICYCLE ; jr nz, .gotBike
      -- before the player owns a bike -> TheseBikesAreExpensiveText
      -- after the player owns a bike  -> CoolBikeText
      TEXT_BIKESHOP_YOUNGSTER = {
        { "face_player" },                                            -- 1
        { "check_flag", "EVENT_GOT_BICYCLE" },                        -- 2
        { "jump_if_true", 5 },                                        -- 3
        { "show_text", "_BikeShopYoungsterTheseBikesAreExpensiveText" }, -- 4
        { "jump", 6 },                                                -- 5
        { "show_text", "_BikeShopYoungsterCoolBikeText" },            -- 6
      },
    },
  },
}
