-- Driver: Game Corner slot machine,  open a working machine, spin, stop
-- the three wheels one at a time (per-wheel slip animation), read the
-- result, then poke the three broken machines for their exact pokered
-- texts (OUT OF ORDER / OUT TO LUNCH / SOMEONE'S KEYS).
return function(game)
  local U = dofile("tests/drivers/util.lua")
  local DIR = os.getenv("SHOT_DIR") or "/tmp/shots"
  local SlotMachine = require("src.ui.SlotMachine")
  local TextBox = require("src.render.TextBox")

  local function topIs(cls)
    return getmetatable(game.stack:top()) == cls
  end
  local function pageText()
    local top = game.stack:top()
    if getmetatable(top) ~= TextBox then return "<no textbox>" end
    local out = {}
    for _, page in ipairs(top.pages or {}) do
      for _, line in ipairs(page) do out[#out + 1] = tostring(line) end
    end
    return table.concat(out, "\\n")
  end

  U.newGame(game)
  game.save.inventory = game.save.inventory or {}
  game.save.inventory.COIN_CASE = 1
  game.save.coins = 50

  -- seat 1: working machine at (18,15); stand left of it facing right
  U.teleport(game, "GAME_CORNER", 17, 15, "right")
  U.tap(game, "a")
  U.wait(10)
  U.log("machine open:", topIs(SlotMachine))
  U.shot(game, DIR .. "/slots_0_bet.png")

  local sm = game.stack:top()
  U.tap(game, "a") -- PromptUserToPlaySlots "Want to play?" -> YES (default cursor)
  U.wait(6)
  U.log("bet stage:", sm.stage == "bet", "default bet (x3):", sm.bet)
  U.tap(game, "a") -- confirm bet 3 (CoinMultiplierSlotMachineText default), start spinning
  U.wait(6)
  U.log("spinup:", sm.stage == "spinup", "coins:", game.save.coins)
  U.wait(44) -- 20 spin-up steps at 2 frames each
  U.log("spinning:", sm.stage == "spin")
  U.shot(game, DIR .. "/slots_1_spin.png")

  U.tap(game, "a") -- stop wheel 1
  U.wait(30)
  U.log("wheel1 stopped:", sm.stopping >= 1 and sm.slip[1] == 0,
        "offset odd:", sm.offset[1] % 2 == 1)
  U.shot(game, DIR .. "/slots_2_wheel1.png")

  U.tap(game, "a") -- stop wheel 2
  U.wait(30)
  U.log("wheel2 stopped:", sm.stopping >= 2 and sm.slip[2] == 0,
        "offset odd:", sm.offset[2] % 2 == 1)
  U.shot(game, DIR .. "/slots_3_wheel2.png")

  U.tap(game, "a") -- stop wheel 3
  U.wait(30)
  -- a win goes through the screen-flash stage before the "lined up!"
  -- message; a loss reaches the "Not this time!" message immediately.
  for _ = 1, 200 do
    if sm.stage == "message" then break end
    U.wait(1)
  end
  U.log("resolved:", sm.stage == "message",
        "offsets:", sm.offset[1], sm.offset[2], sm.offset[3])
  U.log("message:", tostring(sm.message), "coins:", game.save.coins)
  U.shot(game, DIR .. "/slots_4_result.png")

  U.tap(game, "a") -- dismiss result (starts the coin-drip payout on a win)
  U.wait(6)
  -- ride out the payout drip (if any) until "One more go?" or the
  -- out-of-coins auto-exit
  for _ = 1, 3000 do
    if sm.stage == "onemore" or (sm.stage == "message" and sm.exitTimer) then break end
    U.wait(1)
  end
  U.log("after payout:", sm.stage, "coins:", game.save.coins)

  if sm.stage == "onemore" then
    U.tap(game, "b") -- decline "One more go?" -> leave
    U.wait(6)
  else
    U.wait(70) -- OutOfCoinsSlotMachineText auto-exits after 60 frames
  end
  U.log("left machine:", game.stack:top() == game.overworld)

  -- broken machines: exact pokered strings
  local spots = {
    { 12, 12, "out_to_lunch", "slots_5_lunch" },
    { 5, 12, "out_of_order", "slots_6_order" },
    { 17, 10, "keys", "slots_7_keys" },
  }
  for _, s in ipairs(spots) do
    U.teleport(game, "GAME_CORNER", s[1], s[2], "right")
    U.tap(game, "a")
    U.wait(10)
    U.log(s[3] .. ":", pageText())
    U.shot(game, DIR .. "/" .. s[4] .. ".png")
    U.tap(game, "a")
    U.wait(6)
  end
end
