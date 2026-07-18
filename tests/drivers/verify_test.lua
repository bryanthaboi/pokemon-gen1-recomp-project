return function(game)
  local U = dofile("tests/drivers/util.lua")
  local DIR = os.getenv("SHOT_DIR") or "/tmp/shots"
  local Pokemon = require("src.pokemon.Pokemon")
  table.insert(game.save.party, Pokemon.new(game.data, "CHARMANDER", 10))
  -- battle transition + UI
  U.teleport(game, "ROUTE_1", 5, 5, "down")
  local ow = game.overworld
  local BattleState = require("src.battle.BattleState")
  local b = BattleState.newWild(game, "RATTATA", 6)
  b.onFinish = function() end
  ow:pushBattle(b)
  for _ = 1, 14 do U.tap(game, "a"); U.wait(6) end
  U.shot(game, DIR .. "/v_battle_menu.png")
  -- START menu gating (empty dex, has party)
  while game.stack:top() ~= b do U.wait(1) end
  -- exit battle
  b.result = "run"; b:finish()
  U.wait(20)
  U.tap(game, "start"); U.wait(6)
  U.shot(game, DIR .. "/v_startmenu.png")
end
