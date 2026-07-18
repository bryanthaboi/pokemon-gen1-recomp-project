-- Flavor dialogue for GameCorner (pokered/scripts/GameCorner.asm)
--
-- TEXT_GAMECORNER_CLERK1, TEXT_GAMECORNER_GYM_GUIDE and
-- TEXT_GAMECORNER_POSTER are already ported on data/scripts/story3.lua's
-- and story7.lua's M.GAME_CORNER tables. This file ports the three
-- remaining coin-giveaway NPCs, each a one-shot "give N coins" gated by
-- its own EVENT_GOT_*_COINS flag, the COIN CASE, and Has9990Coins room
-- to receive them (mirroring GameCornerClerk1Text's coin-case/coin-cap
-- checks in story3.lua).
local function coinGiver(opts)
  return function(game, ow, npc, done)
    local TextBox = require("src.render.TextBox")
    local Sound = require("src.core.Sound")
    local t = game.data.text
    local function push(label, fallback, onDone)
      game.stack:push(TextBox.new(game, t[label] or fallback, onDone or done))
    end
    if game.save.flags[opts.event] then
      push(opts.alreadyGotLabel, opts.alreadyGotFallback)
      return
    end
    push(opts.askLabel, opts.askFallback, function()
      if not game.save.inventory.COIN_CASE then
        push("_GameCornerOopsForgotCoinCaseText", "Oops! Forgot the\nCOIN CASE!")
        return
      end
      if (game.save.coins or 0) >= 9990 then
        push(opts.coinCaseFullLabel, opts.coinCaseFullFallback)
        return
      end
      game.save.coins = math.min(9999, (game.save.coins or 0) + opts.amount)
      game.save.flags[opts.event] = true
      Sound.play(game.data, "Get_Item1")
      push(opts.receivedLabel,
        ("{PLAYER} received\n%d coins!"):format(opts.amount))
    end)
  end
end

return {
  GAME_CORNER = {
    talk = {
      -- GameCornerFishingGuruText (pokered/scripts/GameCorner.asm):
      -- gives 10 coins once (EVENT_GOT_10_COINS).
      TEXT_GAMECORNER_FISHING_GURU = coinGiver({
        event = "EVENT_GOT_10_COINS",
        amount = 10,
        askLabel = "_GameCornerFishingGuruWantToPlayText",
        askFallback = "Kid, do you want\nto play?",
        receivedLabel = "_GameCornerFishingGuruReceived10CoinsText",
        coinCaseFullLabel = "_GameCornerFishingGuruDontNeedMyCoinsText",
        coinCaseFullFallback = "You don't need my\ncoins!",
        alreadyGotLabel = "_GameCornerFishingGuruWinsComeAndGoText",
        alreadyGotFallback = "Wins seem to come\nand go.",
      }),

      -- GameCornerClerk2Text (pokered/scripts/GameCorner.asm): gives 20
      -- coins once (EVENT_GOT_20_COINS_2).
      TEXT_GAMECORNER_CLERK2 = coinGiver({
        event = "EVENT_GOT_20_COINS_2",
        amount = 20,
        askLabel = "_GameCornerClerk2WantSomeCoinsText",
        askFallback = "What's up? Want\nsome coins?",
        receivedLabel = "_GameCornerClerk2Received20CoinsText",
        coinCaseFullLabel = "_GameCornerClerk2YouHaveLotsOfCoinsText",
        coinCaseFullFallback = "You have lots of\ncoins!",
        alreadyGotLabel = "_GameCornerClerk2INeedMoreCoinsText",
        alreadyGotFallback = "Darn! I need more\ncoins for the\vPOKéMON I want!",
      }),

      -- GameCornerGentlemanText (pokered/scripts/GameCorner.asm): gives 20
      -- coins once (EVENT_GOT_20_COINS). Note the original ASM uses
      -- Has9990Coins' `jr z` (only the exact-9990 case) here rather than
      -- Clerk1/Clerk2's `jr nc` (>=9990); ported as >=9990 to match their
      -- "coin case is basically full" intent and avoid a coin-count
      -- edge case where 9991-9999 would otherwise slip past the check.
      TEXT_GAMECORNER_GENTLEMAN = coinGiver({
        event = "EVENT_GOT_20_COINS",
        amount = 20,
        askLabel = "_GameCornerGentlemanThrowingMeOffText",
        askFallback = "Hey, what? You're\nthrowing me off!\vHere are some\vcoins, shoo!",
        receivedLabel = "_GameCornerGentlemanReceived20CoinsText",
        coinCaseFullLabel = "_GameCornerGentlemanYouGotYourOwnCoinsText",
        coinCaseFullFallback = "You've got your\nown coins!",
        alreadyGotLabel = "_GameCornerGentlemanCloselyWatchTheReelsText",
        alreadyGotFallback = "The trick is to\nwatch the reels\vclosely!",
      }),
    },
  },
}
