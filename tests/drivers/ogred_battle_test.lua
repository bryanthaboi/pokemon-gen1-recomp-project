-- Visual test: SQUIRTLE (player) vs BULBASAUR (enemy) in OG RED, to match
-- the Game Boy Color hardware capture.  Run with a display:
--
--   SHOT_DIR=/tmp/ogred POKEPORT_IDENTITY=pokeport-ogred-shot \
--     POKEPORT_DRIVER=tests/drivers/ogred_battle_test.lua love .
--
-- Captures ogred_0{1..5}_*.png into SHOT_DIR.  OG RED is a global palette:
-- red BG (terrain, mon pics, HUD, text) + green OBJ (overworld characters,
-- battle effects).  Battle mon pics are BG tiles, so they come out red/pink
-- on the near-white field -- see PaletteFX.GBC_BG / monPal.
return function(game)
  local U = dofile("tests/drivers/util.lua")
  local DIR = os.getenv("SHOT_DIR") or "."
  local PaletteFX = require("src.render.PaletteFX")

  -- Set the SAVED option, not just the live mode: Game:applyOptions re-reads
  -- save.options.colors, so a bare setMode would get reverted to the default.
  game.save.options = game.save.options or {}
  game.save.options.colors = "ogred"
  PaletteFX.setMode("ogred")

  local Pokemon = require("src.pokemon.Pokemon")
  game.save.party = { Pokemon.new(game.data, "SQUIRTLE", 5) }

  U.teleport(game, "ROUTE_1", 5, 5, "down")
  local ow = game.overworld

  local BattleState = require("src.battle.BattleState")
  local battle = BattleState.newWild(game, "BULBASAUR", 5)
  battle.onFinish = function() end
  ow:pushBattle(battle)

  U.wait(220)
  U.shot(game, DIR .. "/ogred_01_intro.png")

  for _ = 1, 24 do U.tap(game, "a"); U.wait(6) end
  U.shot(game, DIR .. "/ogred_02_menu.png")

  U.tap(game, "a"); U.wait(12)            -- FIGHT -> move list
  U.shot(game, DIR .. "/ogred_03_moves.png")

  U.tap(game, "down"); U.wait(6)          -- TACKLE -> TAIL WHIP
  U.tap(game, "a"); U.wait(30)
  U.shot(game, DIR .. "/ogred_04_tailwhip.png")
  U.wait(40)
  U.shot(game, DIR .. "/ogred_05_after.png")
  U.wait(4)
end
