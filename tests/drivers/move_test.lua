return function(game)
  local U = dofile("tests/drivers/util.lua")
  U.teleport(game, "OAKS_LAB", 7, 4, "up")
  local ow = game.overworld
  U.log("start:", ow.player.cellX, ow.player.cellY)
  U.hold(game, "down", 20)
  U.log("after down:", ow.player.cellX, ow.player.cellY)
  U.hold(game, "left", 30)
  U.log("after left:", ow.player.cellX, ow.player.cellY)
end
