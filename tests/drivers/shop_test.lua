-- Driver: mart buy flow,  greeting, BUY list, purchase, unwind, then
-- confirm the player can still walk (softlock check).  Runs both the
-- generic mart (Pewter) and the script-run mart (Viridian post-parcel,
-- open_mart with a yielded runner,  the old softlock).
return function(game)
  local U = dofile("tests/drivers/util.lua")
  local DIR = os.getenv("SHOT_DIR") or "/tmp/shots"
  local Flags = require("src.script.Flags")
  local Menu = require("src.ui.Menu")
  local ListMenu = require("src.ui.ListMenu")
  local QuantityBox = require("src.ui.QuantityBox")
  local ChoiceBox = require("src.ui.ChoiceBox")
  game.save.money = 3000
  Flags.set(game.save, "EVENT_GOT_STARTER")
  Flags.set(game.save, "EVENT_GOT_OAKS_PARCEL")
  Flags.set(game.save, "EVENT_OAK_GOT_PARCEL")

  local function topIs(cls)
    return getmetatable(game.stack:top()) == cls
  end
  local function mash(btn, cond)
    for _ = 1, 120 do
      if cond() then return true end
      U.tap(game, btn)
      U.wait(4)
    end
    return false
  end

  local function buyRun(tag)
    local ow = game.overworld
    U.tap(game, "a") -- talk to the clerk
    U.wait(20)
    U.log(tag, "menu:", mash("a", function() return topIs(Menu) end))
    U.tap(game, "a") -- BUY
    U.wait(8)
    U.log(tag, "list:", topIs(ListMenu))
    U.shot(game, ("%s/%s_0_list.png"):format(DIR, tag))
    U.tap(game, "a") -- first item
    U.wait(8)
    U.log(tag, "qty:", topIs(QuantityBox))
    U.tap(game, "a") -- x01
    U.wait(8)
    U.log(tag, "confirm:", topIs(ChoiceBox))
    U.shot(game, ("%s/%s_1_confirm.png"):format(DIR, tag))
    U.tap(game, "a") -- YES
    U.wait(8)
    U.shot(game, ("%s/%s_2_bought.png"):format(DIR, tag))
    U.log(tag, "unwound:", mash("b", function() return game.stack:top() == ow end))
    U.log(tag, "runner idle:",
          not (ow.runner and ow.runner:isRunning()) and true or false)
    local x0, y0 = ow.player.cellX, ow.player.cellY
    U.hold(game, "right", 30)
    U.wait(20)
    U.log(tag, "player moved:", ow.player.cellX ~= x0 or ow.player.cellY ~= y0)
    U.shot(game, ("%s/%s_3_walk.png"):format(DIR, tag))
  end

  U.teleport(game, "PEWTER_MART", 2, 5, "left")
  buyRun("pewter")
  U.teleport(game, "VIRIDIAN_MART", 2, 5, "left")
  buyRun("viridian")
end
