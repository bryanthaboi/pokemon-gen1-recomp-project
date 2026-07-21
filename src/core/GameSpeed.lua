-- Fast-forward multiplier for game logic.
--
-- Speeding up means running the 1/60 fixed step N times per real frame
-- (Game:update), so everything driven by the step -- movement, text,
-- battle timing, scripts -- advances N times faster while staying
-- deterministic. Audio deliberately does NOT scale: Music.update drives
-- fade counters and ChipAudio synthesis off its own real-time 60Hz
-- accumulator in Game:update, so music and sfx play at normal pitch and
-- tempo at every speed.
--
-- Vsync still caps how much work a real frame can do, so 10X is a target
-- rather than a promise on a slow machine -- the logic simply runs as many
-- steps as the frame budget allows.

local GameSpeed = {}

-- 20X exists for the bot runs (tests/drivers/route.lua): a full-route
-- attempt is long enough that the iteration loop, not the engine, is the
-- bottleneck. Vsync caps how much a real frame can do, so past 10X the
-- multiplier is increasingly a ceiling rather than a rate.
GameSpeed.LEVELS = { 1, 2, 4, 10, 20, 30, 50, 75, 100,200 }
GameSpeed.DEFAULT = 1

function GameSpeed.levelLabel(v)
  v = tonumber(v) or GameSpeed.DEFAULT
  if v == 1 then return "NORMAL" end
  return tostring(v) .. "X"
end

-- nearest valid level for an arbitrary value (a hand-edited options.lua or
-- a --speed argument), so a bad number degrades to something sane
function GameSpeed.clamp(v)
  v = tonumber(v)
  if not v then return GameSpeed.DEFAULT end
  local best, bestDiff = GameSpeed.DEFAULT, math.huge
  for _, level in ipairs(GameSpeed.LEVELS) do
    local diff = math.abs(level - v)
    if diff < bestDiff then best, bestDiff = level, diff end
  end
  return best
end

-- cycle to the next/previous level, wrapping (the options row idiom)
function GameSpeed.cycle(v, dir)
  local levels = GameSpeed.LEVELS
  local cur = 1
  for i, level in ipairs(levels) do
    if level == GameSpeed.clamp(v) then cur = i break end
  end
  local nextIdx = (cur - 1 + (dir or 1)) % #levels + 1
  return levels[nextIdx]
end

return GameSpeed
