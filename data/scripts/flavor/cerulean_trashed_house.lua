-- Cerulean Trashed House (pokered/scripts/CeruleanTrashedHouse.asm)
--
-- CeruleanTrashedHouseFishingGuruText (text_asm): checks whether the
-- player is carrying TM_DIG (GetQuantityOfItemInBag) and shows one of
-- two flavor lines depending on the result -- no flags/items are ever
-- changed, it's pure branching flavor text.

return {
  CERULEAN_TRASHED_HOUSE = {
    talk = {
      -- CeruleanTrashedHouseFishingGuruText:
      --   ld b, TM_DIG / predef GetQuantityOfItemInBag / and b
      --   jr z, .no_dig_tm -> .TheyStoleATMText   (player lacks TM_DIG)
      --   else               -> .WhatsLostIsLostText (player has TM_DIG)
      TEXT_CERULEANTRASHEDHOUSE_FISHING_GURU = {
        { "check_item", "TM_DIG" },
        { "jump_if_true", 4 },
        { "show_text", "_CeruleanTrashedHouseFishingGuruTheyStoleATMText" },
        { "jump", 5 },
        { "show_text", "_CeruleanTrashedHouseFishingGuruWhatsLostIsLostText" },
      },
    },
  },
}
