-- Golden-screenshot capture helper (21-testing-and-ci "golden
-- screenshots").  Only meaningful inside a real LOVE run under a driver:
-- main.lua:98-109 flushes game.capturePath to a PNG after the frame is
-- drawn, so capture is "set the path, yield two frames".
--
-- The diffing lives in tools/compare_shots.py; this side only decides
-- where a shot goes, so a driver and CI agree on the filename without
-- either hard-coding a directory.

local Shots = {}

-- CI hands the run a scratch directory; a developer capturing locally gets
-- the same layout under the repo so --bless-shots can copy them across
Shots.DEFAULT_DIR = "tests/goldens/shots"

function Shots.dir()
  return os.getenv("SHOT_DIR") or Shots.DEFAULT_DIR
end

function Shots.path(name)
  local file = tostring(name):gsub("%.png$", "")
  return Shots.dir() .. "/" .. file .. ".png"
end

-- capture from inside a driver coroutine; `wait` is the driver kit's
-- frame-yield so the capture flushes before the driver moves on
function Shots.capture(game, name, wait)
  game.capturePath = Shots.path(name)
  if wait then wait(2) end
  return game.capturePath
end

-- The fixture-dataset shot list, named here rather than in the workflow so
-- adding a golden is a one-line change next to the driver that produces
-- it.  Nothing captures these yet: a POKEPORT_DRIVER chunk is loaded after
-- main.lua has already booted the game, and src/core/Data.lua has no
-- POKEPORT_DATA_DIR branch, so no LOVE process can be pointed at the
-- fixture dataset.  The list is the contract the driver will satisfy once
-- that override lands.
Shots.FIXTURE_SHOTS = {
  "fixture_title",
  "fixture_start_menu",
  "fixture_battle_intro",
  "fixture_mod_screen",
}

return Shots
