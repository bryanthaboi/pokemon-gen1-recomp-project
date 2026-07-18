-- CeruleanTradeHouse (pokered/scripts/CeruleanTradeHouse.asm)
--
-- The Gambler NPC (CeruleanTradeHouseGamblerText) is a text_asm that sets
-- wWhichTrade = TRADE_FOR_LOLA and calls the DoInGameTradeDialogue predef
-- (engine/events/in_game_trades.asm). TRADE_FOR_LOLA is entry 7 in
-- data/events/trades.asm (give POLIWHIRL, get JYNX, nickname LOLA), which
-- matches data/generated/field.lua trades[7]. The Granny's text is plain
-- flavor lore (data/scripts/story.lua) -- the Gambler here owns the
-- trade, exactly as in CeruleanTradeHouse.asm.
-- EVENT_TRADED_POLIWHIRL_FOR_JYNX is the port's name for this trade's
-- wCompletedInGameTradeFlags bit (Commands.trade checks it before the
-- offer and sets it on completion).
return {
  CERULEAN_TRADE_HOUSE = {
    talk = {
      TEXT_CERULEANTRADEHOUSE_GAMBLER = {
        { "face_player" },
        { "trade", 7, "EVENT_TRADED_POLIWHIRL_FOR_JYNX" }, -- LOLA (POLIWHIRL -> JYNX)
      },
    },
  },
}
