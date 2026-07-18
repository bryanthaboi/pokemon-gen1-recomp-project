-- Driver: throw Poké Balls and capture the catch suspense sequence
-- (toss -> poof -> mon hides -> ball shakes -> breakout or capture).
return function(game)
  local U = dofile("tests/drivers/util.lua")
  local DIR = os.getenv("SHOT_DIR") or "/tmp/shots"
  local Pokemon = require("src.pokemon.Pokemon")
  table.insert(game.save.party, Pokemon.new(game.data, "CHARMANDER", 12))
  U.teleport(game, "ROUTE_1", 5, 5, "down")
  local ow = game.overworld

  local BattleState = require("src.battle.BattleState")

  -- one throw, screenshotting every 20 frames through the chain
  local function throwAndShoot(tag, rng)
    local battle = BattleState.newWild(game, "PIDGEY", 8)
    battle.onFinish = function() end
    battle.rng = rng
    ow:pushBattle(battle)
    for _ = 1, 14 do U.tap(game, "a"); U.wait(6) end
    -- what openItems does before BagMenu calls throwBall
    battle.phase = "messages"
    battle.afterQueue = "menu"
    battle:throwBall("POKE_BALL")
    for _ = 1, 4 do U.tap(game, "a"); U.wait(4) end
    for i = 0, 13 do
      U.shot(game, ("%s/catch_%s_%02d.png"):format(DIR, tag, i))
      U.wait(18)
    end
    -- unwind the battle for the next run
    for _ = 1, 20 do U.tap(game, "a"); U.wait(6) end
    while game.stack:top() ~= ow do game.stack:pop() end
    U.wait(5)
  end

  -- rng high: breakout with wobbles, mon reappears
  throwAndShoot("break", function(a, b) return b end)
  -- rng low: clean capture, ball stays shut
  throwAndShoot("caught", function(a, b) return a end)
end
