-- Parity test,  Workstream D.
-- Self-contained: run via `luajit tests/parity_D.lua`; also dofile'd by
-- tests/run_tests.lua's aggregator.
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end
local fails, total = 0, 0
local function check(c, m) total = total + 1; if c then print("ok   " .. m) else fails = fails + 1; print("FAIL " .. m) end end
local function eq(g, w, m) check(g == w, ("%s (got %s, want %s)"):format(m, tostring(g), tostring(w))) end

-- === assertions per your spec test plan ===
-- Gap: SAFARI_STEP_MAPS (OverworldController.lua ~2106-2109) only decremented
-- wSafariSteps on the 4 core zone quadrants; pokered gates step-decrementing
-- purely on EVENT_IN_SAFARI_ZONE (home/overworld.asm:307-310), which stays
-- set through all 9 interior maps (4 quadrants + 4 rest houses + the secret
-- house) and is only cleared back on SAFARI_ZONE_GATE. So all 9 interior
-- maps must decrement; the gate itself must not.

require("src.render.Font").load(Data)
local OW = require("src.world.OverworldController")
local StateStack = require("src.core.StateStack")
local SaveData = require("src.core.SaveData")

-- safariStep()/safariGameOver()/startWarpTo() close over a module-local
-- `Game` upvalue that is normally set once by OverworldState:enter() during
-- real boot (src/core/Game.lua's Game:load()). The headless test harness
-- never boots a full overworld, so we rewire that shared upvalue directly
-- via the debug library to point at a minimal fake Game -- the same trick
-- for all three closures since they're compiled from the same chunk and
-- must share one Game reference for safariGameOver's side effects (which
-- clears Game.save.safari) to be visible back on our fake save.
local function bindGame(fn, game)
  local i = 1
  while true do
    local name = debug.getupvalue(fn, i)
    if not name then break end
    if name == "Game" then debug.setupvalue(fn, i, game); return true end
    i = i + 1
  end
  return false
end

StateStack:init()
local fakeGame = { data = Data, stack = StateStack, save = SaveData.newGame() }
check(bindGame(OW.safariStep, fakeGame), "safariStep binds the Game upvalue")
check(bindGame(OW.safariGameOver, fakeGame), "safariGameOver binds the Game upvalue")
check(bindGame(OW.startWarpTo, fakeGame), "startWarpTo binds the Game upvalue")

local function safariStepOn(mapId)
  local fake = setmetatable({ map = { id = mapId } }, { __index = OW })
  return fake:safariStep()
end

-- All 9 interior Safari Zone maps decrement the step counter.
local COUNTED_MAPS = {
  "SAFARI_ZONE_CENTER", "SAFARI_ZONE_EAST", "SAFARI_ZONE_NORTH", "SAFARI_ZONE_WEST",
  "SAFARI_ZONE_CENTER_REST_HOUSE", "SAFARI_ZONE_EAST_REST_HOUSE",
  "SAFARI_ZONE_NORTH_REST_HOUSE", "SAFARI_ZONE_WEST_REST_HOUSE",
  "SAFARI_ZONE_SECRET_HOUSE",
}
for _, mapId in ipairs(COUNTED_MAPS) do
  fakeGame.save.safari = { balls = 30, steps = 10 }
  local fired = safariStepOn(mapId)
  check(not fired, mapId .. " safariStep does not end the game at 10 steps")
  eq(fakeGame.save.safari.steps, 9, mapId .. " decrements the safari step counter")
end

-- The gate (and any non-Safari map) must NOT decrement.
local UNCOUNTED_MAPS = { "SAFARI_ZONE_GATE", "PALLET_TOWN", "FUCHSIA_CITY" }
for _, mapId in ipairs(UNCOUNTED_MAPS) do
  fakeGame.save.safari = { balls = 30, steps = 10 }
  local fired = safariStepOn(mapId)
  check(not fired, mapId .. " safariStep returns false")
  eq(fakeGame.save.safari.steps, 10, mapId .. " leaves the safari step counter untouched")
end

-- Boundary: hitting 0 steps on a rest/secret house ends the game
-- (SafariZoneCheckSteps's dec bc + zero-check, safari_game.asm:9-27).
fakeGame.save.safari = { balls = 30, steps = 1 }
local fired = safariStepOn("SAFARI_ZONE_SECRET_HOUSE")
check(fired, "safariStep reports the game-over trigger at 0 steps")
check(fakeGame.save.safari == nil,
      "safari session clears (safariGameOver fired) when steps hit 0 in the secret house")

print(("parity D: %d/%d passed"):format(total - fails, total))
if fails > 0 then error(fails .. " parity-D assertion(s) failed") end
