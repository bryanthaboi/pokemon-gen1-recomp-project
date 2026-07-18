-- Driver: elevator ride (ShakeElevator, engine/overworld/elevator.asm).
-- Teleports onto the Celadon Mart elevator's exit tile (1,3) -- the real
-- arrival cell, where the floor menu opens on entry -- picks 2F, traces
-- the bgShakeY scroll offset through the 9-frame lead-in and first shake
-- cycles, screenshots both phases of the oscillation, then confirms the
-- post-ride walk-out onto the arrival floor (the car's exit warps are
-- rewritten and the player walks out, per scripts/CeladonMartElevator.asm,
-- instead of a jump-cut warp).
return function(game)
  local U = dofile("tests/drivers/util.lua")
  local DIR = os.getenv("SHOT_DIR") or "/tmp/shots"
  local ListMenu = require("src.ui.ListMenu")

  U.teleport(game, "CELADON_MART_ELEVATOR", 1, 3, "up")
  U.wait(5)
  local ow = game.overworld
  U.log("map:", ow.map.id,
        "menu open:", tostring(getmetatable(game.stack:top()) == ListMenu))
  U.shot(game, DIR .. "/elev_0_menu.png")

  U.tap(game, "down") -- cursor 1F -> 2F
  U.wait(2)
  U.tap(game, "a")    -- choose 2F: the ElevatorShake state pushes
  -- expect 9 zero frames (Celadon farjps into ShakeElevator, no extra
  -- Delay3), then -1,-1,+1,+1,... in 2-frame steps
  local trace = {}
  for _ = 1, 24 do
    trace[#trace + 1] = tostring(ow.bgShakeY or 0)
    U.wait(1)
  end
  U.log("bgShakeY after A:", table.concat(trace, ","))
  U.shot(game, DIR .. "/elev_1_shake_a.png")
  U.shot(game, DIR .. "/elev_2_shake_b.png") -- 3 frames later: other phase
  -- ride out: rest of the 200 shake frames, the PA chime, then the
  -- scripted walk-out; wait until the walk-out has warped onto the floor
  for _ = 1, 1200 do
    U.wait(1)
    if ow.map.id ~= "CELADON_MART_ELEVATOR" and not ow.transitioning
       and #ow.scriptMoves == 0 then
      break
    end
  end
  U.wait(10)
  U.log("final map:", ow.map.id, "pos:", ow.player.cellX, ow.player.cellY,
        "bgShakeY:", tostring(ow.bgShakeY or 0))
  U.shot(game, DIR .. "/elev_3_arrived.png")
end
