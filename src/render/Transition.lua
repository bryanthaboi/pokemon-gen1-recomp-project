-- Screen fade used for warps: fade out, run a callback (map switch), fade in.
-- Pushed on the state stack above the overworld.

local Transition = {}
Transition.__index = Transition

local FRAMES = 12

function Transition.new(game, onMidpoint, onDone)
  local self = setmetatable({}, Transition)
  self.game = game
  self.onMidpoint = onMidpoint
  self.onDone = onDone
  self.t = 0
  self.phase = "out"
  return self
end

function Transition:update(dt)
  self.t = self.t + 1
  if self.t >= FRAMES then
    self.t = 0
    if self.phase == "out" then
      self.phase = "in"
      if self.onMidpoint then self.onMidpoint() end
    else
      self.game.stack:pop()
      if self.onDone then self.onDone() end
    end
  end
end

function Transition:draw()
  local alpha = self.t / FRAMES
  if self.phase == "in" then alpha = 1 - alpha end
  love.graphics.setColor(0, 0, 0, alpha)
  love.graphics.rectangle("fill", 0, 0, 160, 144)
  love.graphics.setColor(1, 1, 1, 1)
end

-- GBPalWhiteOutWithDelay3 (home/palettes.asm): the field moves that close
-- the party menu (start_sub_menus.asm .goBackToMap paths) white out the
-- palettes, and they stay white through Delay3 + the screen-tile restore
-- until CloseTextDisplay's LoadGBPal -- a ~7-frame solid-white blink.
-- Instant white, hold, instant restore (a palette write, not a fade).
local WhiteFlash = {}
WhiteFlash.__index = WhiteFlash
WhiteFlash.isOpaque = true

function Transition.whiteFlash(game, frames, onDone)
  return setmetatable({ game = game, frames = frames or 7,
                        onDone = onDone, t = 0 }, WhiteFlash)
end

function WhiteFlash:update(dt)
  self.t = self.t + 1
  if self.t >= self.frames then
    self.game.stack:pop()
    if self.onDone then self.onDone() end
  end
end

function WhiteFlash:draw()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 144)
end

return Transition
