-- Driver: the Hall of Fame recording-machine "PC".  Teleports into the
-- HALL_OF_FAME room, faces the console jutting from the north wall, and
-- exercises the injected TEXT_HALLOFFAME_PC sign both ways: NO leaves the
-- player in the room, YES warps home to the new-game bedroom spawn
-- (REDS_HOUSE_2F, 3, 6).  Screenshots the prompt and the arrival.

return function(game)
  local U = dofile("tests/drivers/util.lua")
  local DIR = os.getenv("SHOT_DIR") or "/tmp/shots"
  local TextBox = require("src.render.TextBox")
  local ChoiceBox = require("src.ui.ChoiceBox")

  local pass = true
  local function check(cond, msg)
    if cond then U.log("PASS: " .. msg) else pass = false; U.log("FAIL: " .. msg) end
  end
  local function topIs(mt) return getmetatable(game.stack:top()) == mt end

  -- press A to advance the ask text until the YES/NO box is on top
  local function openChoice()
    for _ = 1, 120 do
      if topIs(ChoiceBox) then return true end
      if topIs(TextBox) then U.tap(game, "a") end
      U.wait(3)
    end
    return false
  end

  -- stand at (4,2) facing up: the console solid cell (4,1) is dead ahead
  U.teleport(game, "HALL_OF_FAME", 4, 2, "up")
  local ow = game.overworld
  local fx, fy = ow.player:facingCell()
  U.log(("at (%d,%d) facing %s -> facing cell (%d,%d)"):format(
        ow.player.cellX, ow.player.cellY, ow.player.facing, fx, fy))
  check(ow.map:signAtCell(fx, fy) ~= nil, "a sign sits on the console tile")

  -- ---- NO: prompt appears, player stays in the Hall of Fame ----
  U.tap(game, "a") -- interact -> ask
  U.wait(4)
  check(openChoice(), "NO run: YES/NO prompt opened")
  U.shot(game, DIR .. "/hof_pc_1_prompt.png")
  U.tap(game, "down") -- cursor YES -> NO
  U.wait(2)
  U.tap(game, "a") -- confirm NO
  U.wait(20)
  check(ow.map.id == "HALL_OF_FAME", "NO keeps the player in HALL_OF_FAME")

  -- ---- YES: warp back to the bedroom spawn ----
  U.teleport(game, "HALL_OF_FAME", 4, 2, "up")
  ow = game.overworld
  U.tap(game, "a")
  U.wait(4)
  check(openChoice(), "YES run: YES/NO prompt opened")
  U.tap(game, "a") -- YES (default cursor)
  local warped = false
  for _ = 1, 300 do
    if ow.map.id == "REDS_HOUSE_2F" and not ow.transitioning then warped = true; break end
    U.wait(2)
  end
  U.log(("after YES: map=%s pos=(%d,%d) facing=%s"):format(
        ow.map.id, ow.player.cellX, ow.player.cellY, ow.player.facing))
  U.wait(10)
  U.shot(game, DIR .. "/hof_pc_2_home.png")
  check(warped, "YES warps to REDS_HOUSE_2F")
  check(ow.player.cellX == 3 and ow.player.cellY == 6,
        "landed on the bedroom spawn (3,6)")

  U.log(pass and "RESULT: ALL PASS" or "RESULT: SEE FAILURES ABOVE")
end
