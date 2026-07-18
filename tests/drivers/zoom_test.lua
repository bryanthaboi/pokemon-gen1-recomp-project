-- Driver: overworld survey zoom -- screenshots at several levels, UI
-- over the zoomed world, and Rock Tunnel darkness zoomed out.
return function(game)
  local U = dofile("tests/drivers/util.lua")
  local DIR = os.getenv("SHOT_DIR") or "/tmp/shots"
  local Zoom = require("src.render.Zoom")

  U.teleport(game, "PALLET_TOWN", 10, 8, "down")
  U.wait(30)
  U.shot(game, DIR .. "/zoom_0_default.png")

  -- two clicks out
  game:zoomStep(-1); game:zoomStep(-1)
  U.wait(5)
  U.shot(game, DIR .. "/zoom_1_out2.png")

  -- full survey (clamps at s'=1): Route 1 ghosts should be wandering
  for _ = 1, 10 do game:zoomStep(-1) end
  U.wait(60)
  U.shot(game, DIR .. "/zoom_2_survey.png")

  -- UI on top of the zoomed world
  U.tap(game, "start")
  U.wait(10)
  U.shot(game, DIR .. "/zoom_3_menu_over_survey.png")
  U.tap(game, "b")
  U.wait(5)

  -- close-up (clamps at 2*S)
  for _ = 1, 30 do game:zoomStep(1) end
  U.wait(5)
  U.shot(game, DIR .. "/zoom_4_closeup.png")

  -- the Route 1 / Pallet seam: two palette zones visible at once
  Zoom.reset()
  U.teleport(game, "ROUTE_1", 5, 5, "down")
  for _ = 1, 6 do game:zoomStep(-1) end
  U.wait(30)
  U.shot(game, DIR .. "/zoom_6_seam_palettes.png")

  -- Rock Tunnel darkness while zoomed out
  Zoom.reset()
  U.teleport(game, "ROCK_TUNNEL_1F", 8, 15, "down")
  for _ = 1, 4 do game:zoomStep(-1) end
  U.wait(10)
  U.shot(game, DIR .. "/zoom_5_dark_survey.png")

  Zoom.reset()
end
