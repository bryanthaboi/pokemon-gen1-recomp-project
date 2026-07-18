-- Driver: force a wild battle and screenshot the transition + UI.
return function(game)
  local U = dofile("tests/drivers/util.lua")
  local DIR = os.getenv("SHOT_DIR") or "/tmp/shots"
  -- a party to fight with
  local Pokemon = require("src.pokemon.Pokemon")
  table.insert(game.save.party, Pokemon.new(game.data, "CHARMANDER", 12))
  U.teleport(game, "ROUTE_1", 5, 5, "down")
  local ow = game.overworld

  -- push a battle straight through the transition
  local BattleState = require("src.battle.BattleState")
  local battle = BattleState.newWild(game, "PIDGEY", 8)
  battle.onFinish = function() end
  ow:pushBattle(battle)

  U.shot(game, DIR .. "/battle_0_flash.png")
  U.wait(10)
  U.shot(game, DIR .. "/battle_1_wipe.png")
  U.wait(20)
  U.shot(game, DIR .. "/battle_2_intro.png")
  -- mash to the menu
  for _ = 1, 12 do U.tap(game, "a"); U.wait(6) end
  U.shot(game, DIR .. "/battle_3_menu.png")
  -- FIGHT -> move list
  U.tap(game, "a")
  U.wait(10)
  U.shot(game, DIR .. "/battle_4_moves.png")
  -- pick first move, watch the animation
  U.tap(game, "a")
  U.wait(20)
  U.shot(game, DIR .. "/battle_5_anim.png")
  U.wait(30)
  U.shot(game, DIR .. "/battle_6_after.png")
end
