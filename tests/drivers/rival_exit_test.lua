-- Driver: regression coverage for the Oak's lab chain reported broken:
--   * move menu / TYPE-PP box layout (screenshots)
--   * enemy faint slide ends with the pic gone (screenshots)
--   * the rival challenge fires two steps from the table (y==6),
--     no talking required
--   * leaving the lab after the fight takes the LAST_MAP exit mat
--     back to Pallet (previously asserted: no remembered outdoor map)

return function(game)
  local U = dofile("tests/drivers/util.lua")
  local DIR = os.getenv("SHOT_DIR") or "/tmp/shots"

  -- ------------------------------------------------------------ part A
  -- wild battle: move menu layout + faint slide
  local Pokemon = require("src.pokemon.Pokemon")
  table.insert(game.save.party, Pokemon.new(game.data, "CHARMANDER", 20))
  U.teleport(game, "ROUTE_1", 5, 5, "down")
  local ow = game.overworld
  local BattleState = require("src.battle.BattleState")
  local battle = BattleState.newWild(game, "PIDGEY", 3)
  battle.onFinish = function() end
  ow:pushBattle(battle)

  for _ = 1, 300 do
    if battle.phase == "menu" then break end
    U.tap(game, "a"); U.wait(3)
  end
  U.wait(5)
  U.tap(game, "a") -- FIGHT
  for _ = 1, 100 do
    if battle.phase == "moveSelect" then break end
    U.wait(1)
  end
  U.wait(2)
  U.shot(game, DIR .. "/v_moves.png")

  -- attack until the Pidgey faints; capture mid-slide and after
  local midShot, endShot = false, false
  for _ = 1, 1200 do
    if battle.enemy and battle.enemy.fainted then
      local fx = battle.fx and battle.fx.faint
      if fx and fx.frames > 0 and fx.frames <= 20 and not midShot then
        U.shot(game, DIR .. "/v_faint_mid.png"); midShot = true
      end
      if (not fx or fx.frames <= 0) and not endShot then
        U.wait(2)
        U.shot(game, DIR .. "/v_faint_after.png"); endShot = true
        break
      end
      U.wait(1)
    else
      U.tap(game, "a"); U.wait(3)
    end
  end
  U.log("faint shots:", tostring(midShot), tostring(endShot))

  -- ------------------------------------------------------------ part B
  -- full Pallet intro -> starter -> two steps down -> ambush -> exit
  U.teleport(game, "PALLET_TOWN", 10, 1, "up")
  ow = game.overworld

  local function mashUntil(cond, label, cap)
    for _ = 1, cap or 400 do
      if cond() then return true end
      if game.stack:top() ~= ow then U.tap(game, "a") end
      U.wait(4)
    end
    U.log("TIMEOUT waiting for " .. label)
    return false
  end
  local function idle()
    return game.stack:top() == ow and not ow.runner:isRunning()
           and #ow.scriptMoves == 0 and not ow.transitioning
  end

  U.hold(game, "up", 20)
  U.wait(30)
  mashUntil(function() return ow.map.id == "OAKS_LAB" end, "lab entry", 600)
  mashUntil(idle, "walk-in done", 300)
  U.log("lastOutdoor after walk-in:",
        ow.lastOutdoor and ow.lastOutdoor.id or "nil",
        ow.lastOutdoor and ow.lastOutdoor.x or -1,
        ow.lastOutdoor and ow.lastOutdoor.y or -1)

  -- middle ball at (7,3), interact from (7,4)
  U.hold(game, "up", 18)
  U.hold(game, "right", 52)
  U.tap(game, "up")
  U.wait(10)
  U.tap(game, "a")
  U.wait(40)
  U.tap(game, "a") -- YES
  mashUntil(function() return #game.save.party > 1 end, "starter", 200)
  U.hold(game, "down", 20)
  mashUntil(idle, "rival pick done", 400)
  U.log("picked; at:", ow.player.cellX, ow.player.cellY)

  -- column 4 is the open corridor; two steps down reaches y=6 where
  -- the rival must challenge unprompted
  U.hold(game, "left", 52)
  U.hold(game, "down", 40)
  U.wait(20)
  local ambushed = false
  for _ = 1, 300 do
    local top = game.stack:top()
    if top ~= ow and top and top.kind then ambushed = true break end
    U.tap(game, "a"); U.wait(4)
  end
  U.log("ambushed:", tostring(ambushed), "at y:", ow.player.cellY)
  U.shot(game, DIR .. "/v_ambush.png")
  mashUntil(idle, "rival battle over", 2000)
  U.log("battled flag:", tostring(game.save.flags.EVENT_BATTLED_RIVAL_IN_OAKS_LAB))

  -- out the door: exit mats at (4,11)/(5,11) are LAST_MAP edge warps
  U.hold(game, "down", 140)
  U.wait(30)
  U.hold(game, "down", 30) -- edge exit off the mat
  U.wait(60)
  mashUntil(idle, "exit settled", 200)
  U.log("after exit:", ow.map.id, ow.player.cellX, ow.player.cellY)
  U.shot(game, DIR .. "/v_exit.png")
end
