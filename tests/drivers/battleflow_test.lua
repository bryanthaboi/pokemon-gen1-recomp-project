-- Driver: the two reworked battle flows.
--  A) Old man catch tutorial (DisplayBattleMenu's old-man script):
--     scripted cursor FIGHT(80f) -> ITEM(50f), forced item menu with
--     one POKé BALL x50 -- itself scripted (list_menu.asm:65-80):
--     '▶' hover 80f, auto-A leaves the hollow '▷', always-caught throw.
--  B) Mimic's MID-move copy menu (MimicEffect): the chooser opens only
--     after the hit test, at (0,7) like MoveSelectionMenu .mimicmenu.
return function(game)
  local U = dofile("tests/drivers/util.lua")
  local DIR = os.getenv("SHOT_DIR") or "/tmp/shots"
  local Pokemon = require("src.pokemon.Pokemon")
  local mon = Pokemon.new(game.data, "CHARMANDER", 12)
  mon.moves[1] = { id = "MIMIC", pp = 10 }
  table.insert(game.save.party, 1, mon)
  U.teleport(game, "ROUTE_1", 5, 5, "down")
  local ow = game.overworld
  local BattleState = require("src.battle.BattleState")

  local function waitFor(cond, max)
    for _ = 1, max or 600 do
      if cond() then return true end
      U.wait(1)
    end
    return false
  end
  local function mashUntil(cond, max)
    for _ = 1, max or 80 do
      if cond() then return true end
      U.tap(game, "a")
      U.wait(4)
    end
    return false
  end

  -- ------------------------------------------------ A) old man demo
  local demo = BattleState.newWild(game, "WEEDLE", 5)
  demo:makeOldManDemo()
  demo.onFinish = function() end
  ow:pushBattle(demo)
  -- through "Wild WEEDLE appeared!" to the scripted battle menu
  mashUntil(function() return demo.phase == "menu" and (demo.demoTimer or 0) > 5 end)
  U.shot(game, DIR .. "/oldman_0_cursor_fight.png") -- hand on FIGHT
  waitFor(function() return (demo.demoTimer or 131) > 95 end)
  U.shot(game, DIR .. "/oldman_1_cursor_item.png")  -- hand on ITEM
  waitFor(function() return game.stack:top() ~= demo end)
  U.wait(3)
  U.shot(game, DIR .. "/oldman_2_bag.png")          -- POKé BALL x50 list
  local bag = game.stack:top()
  U.tap(game, "b")                                   -- ignored: no backing out
  waitFor(function() return bag.hollowIndex ~= nil end)
  U.shot(game, DIR .. "/oldman_3_hollow_cursor.png") -- auto-A: hollow '▷'
  waitFor(function() return game.stack:top() == demo end) -- list down, throw
  U.wait(5)
  U.shot(game, DIR .. "/oldman_4_throw.png")        -- "OLD MAN used POKé BALL!"
  U.tap(game, "a")
  U.wait(25)
  for i = 5, 7 do
    U.wait(55)
    U.shot(game, ("%s/oldman_%d_catch.png"):format(DIR, i))
  end
  for _ = 1, 20 do U.tap(game, "a"); U.wait(6) end
  while game.stack:top() ~= ow do game.stack:pop() end
  U.wait(5)

  -- ------------------------------------------------ B) Mimic mid-move
  local battle = BattleState.newWild(game, "PIDGEY", 8)
  battle.onFinish = function() end
  battle.rng = function(a, b) return a end -- Mimic hits
  ow:pushBattle(battle)
  mashUntil(function() return battle.phase == "menu" end)
  U.shot(game, DIR .. "/mimic_0_menu.png")
  U.tap(game, "a"); U.wait(8)                        -- FIGHT
  U.shot(game, DIR .. "/mimic_1_moves.png")
  U.tap(game, "a"); U.wait(4)                        -- MIMIC
  mashUntil(function() return battle.phase == "mimicSelect" end)
  U.shot(game, DIR .. "/mimic_2_chooser.png")        -- copy menu at (0,7)
  U.tap(game, "down"); U.wait(4)
  U.shot(game, DIR .. "/mimic_3_chooser_down.png")
  U.tap(game, "a"); U.wait(30)
  U.shot(game, DIR .. "/mimic_4_learned.png")        -- anim + learned text
  mashUntil(function() return battle.phase == "moveSelect" end, 40)
  U.wait(2)
  U.shot(game, DIR .. "/mimic_5_moves_after.png")    -- slot now holds the copy
  while game.stack:top() ~= ow do game.stack:pop() end
  U.wait(5)
  love.event.quit()
end
