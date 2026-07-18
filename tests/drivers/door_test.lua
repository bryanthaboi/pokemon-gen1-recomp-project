-- Driver: reproduce the door-warp flow.  Teleports to Pallet Town in
-- front of Red's house, walks in, tries to move inside, walks back out.

return function(game)
  local U = dofile("tests/drivers/util.lua")
  local DIR = os.getenv("SHOT_DIR") or "/tmp/shots"
  U.teleport(game, "PALLET_TOWN", 5, 6, "up")
  U.shot(game, DIR .. "/door_0_outside.png")

  -- step onto the door mat (5,5): the warp should fire
  U.hold(game, "up", 20)
  U.shot(game, DIR .. "/door_1_mid.png")
  for i = 2, 6 do
    U.wait(6)
    U.shot(game, DIR .. ("/door_%d_transition.png"):format(i))
  end
  U.wait(30)
  U.shot(game, DIR .. "/door_7_inside.png")
  local ow = game.overworld
  U.log("map:", ow.map.id, "pos:", ow.player.cellX, ow.player.cellY,
        "transitioning:", tostring(ow.transitioning))

  -- can we move? walk left 2 cells
  U.hold(game, "left", 40)
  U.log("after-left pos:", ow.player.cellX, ow.player.cellY)
  U.shot(game, DIR .. "/door_8_moved_inside.png")

  -- walk back out through the mat
  U.hold(game, "right", 40)
  U.hold(game, "down", 60)
  U.wait(40)
  U.shot(game, DIR .. "/door_9_back_outside.png")
  U.log("final map:", ow.map.id, "pos:", ow.player.cellX, ow.player.cellY,
        "transitioning:", tostring(ow.transitioning))
end
