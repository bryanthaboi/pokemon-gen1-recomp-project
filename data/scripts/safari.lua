-- The Safari Zone game entrance (scripts/SafariZoneGate.asm).
--
-- Stepping on (3,2)/(4,2) next to the worker fires the join prompt
-- (.PlayerNextToSafariZoneWorker1CoordsArray).  Paying ¥500 hands over
-- 30 SAFARI BALLs and starts the 502-step game
-- (SafariZoneGateWouldYouLikeToJoinScript: wSafariSteps = 502,
-- wNumSafariBalls = SAFARI_BALLS_RECEIVED).  Declining walks you back
-- so you can't slip past.  Returning to the gate ends the game and the
-- worker takes the leftover balls back.
--
-- Step/ball bookkeeping lives in src/world/OverworldController.lua
-- (safariStep/safariGameOver, from
-- engine/events/hidden_events/safari_game.asm); the in-battle
-- BALL/BAIT/ROCK/RUN game is src/battle/BattleState.lua makeSafari.

local M = {}

local FEE = 500
local BALLS = 30
local STEPS = 502

local function startGame(game, t, done)
  game.save.money = game.save.money - FEE
  game.save.safari = { balls = BALLS, steps = STEPS }
  local TextBox = require("src.render.TextBox")
  local paid = (t._SafariZoneGateSafariZoneWorker1ThatllBe500PleaseText
                or "That'll be ¥500\nplease!\f{PLAYER} received\n30 SAFARI BALLs!")
               :gsub("{PLAYER}", game.save.player.name)
  local pa = t._SafariZoneGateSafariZoneWorker1CallYouOnThePAText
             or "\fWe'll call you on\nthe PA when you\nrun out of time\nor SAFARI BALLs!"
  local luck = t._SafariZoneGateSafariZoneWorker1GoodLuckText or "Good Luck!"
  game.stack:push(TextBox.new(game, paid .. pa .. "\f" .. luck, done))
end

local function joinPrompt(game, ow, done)
  done = done or function() end
  local TextBox = require("src.render.TextBox")
  local ChoiceBox = require("src.ui.ChoiceBox")
  local t = game.data.text
  local back = function(text)
    game.stack:push(TextBox.new(game, text, function()
      ow:scriptMove(ow.player, "down", 1, done)
    end))
  end
  game.stack:push(TextBox.new(game,
    t._SafariZoneGateSafariZoneWorker1WouldYouLikeToJoinText
    or "For just ¥500 you\ncan join the hunt!\fWould you like to\njoin the hunt?",
    function()
      game.stack:push(ChoiceBox.new(game, function(yes)
        if not yes then
          back(t._SafariZoneGateSafariZoneWorker1PleaseComeAgainText
               or "OK! Please come\nagain!")
        elseif game.save.money < FEE then
          back(t._SafariZoneGateSafariZoneWorker1NotEnoughMoneyText
               or "Oops! Not enough\nmoney!")
        else
          startGame(game, t, done)
        end
      end))
    end))
end

M.SAFARI_ZONE_GATE = {
  talk = {
    TEXT_SAFARIZONEGATE_SAFARI_ZONE_WORKER1 = function(game, ow, npc, done)
      local TextBox = require("src.render.TextBox")
      local t = game.data.text
      if game.save.safari then
        game.stack:push(TextBox.new(game,
          t._SafariZoneGateSafariZoneWorker1GoodLuckText or "Good Luck!", done))
        return
      end
      game.stack:push(TextBox.new(game,
        t._SafariZoneGateSafariZoneWorker1Text or "Welcome to the\nSAFARI ZONE!",
        function() joinPrompt(game, ow, done) end))
    end,
  },

  -- the join trigger cells in front of the worker
  onStep = function(game, ow, x, y)
    if y ~= 2 or (x ~= 3 and x ~= 4) then return false end
    if game.save.safari then return false end -- paid, walking in
    joinPrompt(game, ow, nil)
    return true
  end,

  -- arriving back from the zone (the north warps): the worker asks
  -- "Leaving early?" -- yes ends the game and takes the leftover balls,
  -- no walks you back into the zone
  onEnter = function(game, ow)
    if not game.save.safari or ow.player.cellY > 1 then return end
    local TextBox = require("src.render.TextBox")
    local ChoiceBox = require("src.ui.ChoiceBox")
    local t = game.data.text
    game.stack:push(TextBox.new(game,
      t._SafariZoneGateSafariZoneWorker1LeavingEarlyText or "Leaving early?",
      function()
        game.stack:push(ChoiceBox.new(game, function(yes)
          if not yes then
            -- back into the zone through the entrance warp
            local w = game.data.maps.SAFARI_ZONE_CENTER.warps[1]
            ow:startWarpTo("SAFARI_ZONE_CENTER", w.x, w.y, "up")
            return
          end
          game.save.safari = nil
          game.stack:push(TextBox.new(game,
            (t._SafariZoneGateSafariZoneWorker1ReturnSafariBallsText
             or "Please return any\nSAFARI BALLs you\nhave left.")
            .. "\f" .. (t._SafariZoneGateSafariZoneWorker1GoodHaulComeAgainText
                        or "Did you get a\ngood haul?\fCome again!")))
        end))
      end))
  end,
}

return M
