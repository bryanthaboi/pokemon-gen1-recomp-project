-- Route 2 Trade House (pokered/scripts/Route2TradeHouse.asm)
--
-- TEXT_ROUTE2TRADEHOUSE_GAMEBOY_KID: text_asm sets wWhichTrade to
-- TRADE_FOR_MARCEL and calls the DoInGameTradeDialogue predef
-- (engine/events/in_game_trades.asm), i.e. the standard offer-then-trade
-- flow. TradeMons entry #2 (data/events/trades.asm) is
-- ABRA -> MR_MIME, nicknamed "MARCEL"; matches field.trades[2] in
-- data/generated/field.lua. The Scientist in this house is plain
-- flavor text (data/scripts/story.lua) -- the Game Boy Kid here owns
-- the trade, exactly as in Route2TradeHouse.asm.
-- EVENT_TRADED_ABRA_FOR_MR_MIME is the port's name for this trade's
-- wCompletedInGameTradeFlags bit (Commands.trade checks it before the
-- offer and sets it on completion).

return {
  ROUTE_2_TRADE_HOUSE = {
    talk = {
      TEXT_ROUTE2TRADEHOUSE_GAMEBOY_KID = {
        { "face_player" },
        { "trade", 2, "EVENT_TRADED_ABRA_FOR_MR_MIME" }, -- MARCEL
      },
    },
  },
}
