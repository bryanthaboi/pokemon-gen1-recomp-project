-- Shared helpers for POKEPORT_DRIVER scripts (frame-stepped coroutines
-- run by main.lua under xvfb for scripted screenshots).

local U = {}

local frame = 0

function U.wait(n)
  for _ = 1, n do
    frame = frame + 1
    coroutine.yield()
  end
end

-- tap a button for one frame, then release it (the driver has no
-- keyreleased, so an unreleased button would stay held forever and
-- shadow later directional input)
function U.tap(game, btn)
  table.insert(game.input.pressQueue, btn)
  U.wait(1)
  game.input.state[btn] = false
end

-- hold a direction for n frames
function U.hold(game, btn, n)
  for _ = 1, n do
    table.insert(game.input.pressQueue, btn)
    game.input.state[btn] = true
    coroutine.yield()
  end
  game.input.state[btn] = false
end

function U.shot(game, path)
  game.capturePath = path
  U.wait(2) -- let the capture flush
end

-- skip the intro movie + title into a fresh overworld game
function U.newGame(game)
  U.wait(5)
  U.tap(game, "start") -- skip intro movie
  U.wait(10)
  U.tap(game, "a") -- title -> menu
  U.wait(5)
  -- menu: CONTINUE may or may not exist; NEW GAME is first without a save
  U.tap(game, "a")
  U.wait(10)
  -- Oak speech: mash through text + naming (presets pick first = RED).
  -- The closing shrink-away beat (~103 frames) is not skippable, like
  -- the DelayFrames chain it ports, so leave headroom.
  for _ = 1, 400 do
    U.tap(game, "a")
    U.wait(2)
    if game.overworld and game.stack:top() == game.overworld then break end
  end
  U.wait(10)
end

-- jump straight into the overworld at a position, bypassing the intro
function U.teleport(game, mapId, x, y, facing)
  while game.stack:top() do game.stack:pop() end
  local OverworldState = require("src.world.OverworldController")
  game.stack:push(OverworldState, mapId, x, y, facing or "down")
  U.wait(5)
end

function U.log(...)
  print("[driver]", ...)
end

function U.frame() return frame end

return U
