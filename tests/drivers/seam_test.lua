return function(game)
  local U = dofile("tests/drivers/util.lua")
  game.save.flags.EVENT_GOT_STARTER = true
  local Pokemon = require("src.pokemon.Pokemon")
  table.insert(game.save.party, Pokemon.new(game.data, "CHARMANDER", 5))
  U.teleport(game, "ROUTE_1", 10, 4, "up")
  local ow = game.overworld
  local lastPy, lastMap
  for i = 1, 90 do
    table.insert(game.input.pressQueue, "up")
    game.input.state.up = true
    coroutine.yield()
    local p = ow.player
    -- log the on-screen player y and world-pos delta each frame
    local scrY = p.py - ow.camera.y
    -- detect a stall: same world py two frames running while holding up
    U.log(("f=%d %-14s py=%d scrY=%.0f moving=%s"):format(
      i, ow.map.id, p.py, scrY, tostring(p.moving)))
    if ow.map.id == "VIRIDIAN_CITY" and p.cellY < 33 then break end
  end
  game.input.state.up = false
end
