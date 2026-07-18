-- Route 16 Fly House flavor dialogue
-- Source: pokered/scripts/Route16FlyHouse.asm, pokered/text/Route16FlyHouse.asm

return {
  ROUTE_16_FLY_HOUSE = {
    talk = {
      -- Route16FlyHouseFearowText: text_asm just prints the one line and
      -- plays the FEAROW cry (no cry-playback command exists in this
      -- port's Commands vocabulary, so only the text is ported).
      TEXT_ROUTE16FLYHOUSE_FEAROW = {
        { "show_text", "_Route16FlyHouseFearowText" },
      },
    },
  },
}
