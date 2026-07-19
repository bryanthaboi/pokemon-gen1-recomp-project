-- Screen fade used for warps: fade out, run a callback (map switch), fade in.
-- Pushed on the state stack above the overworld.

local Transition = {}
Transition.__index = Transition

local FRAMES = 12
local FLASH_FRAMES = 7

-- The two fades as transitions records, so a mod retimes a warp fade the
-- same way it retimes a battle wipe.  BattleTransition.registerInto pulls
-- these in with its eight wipes -- one registrant owns the registry.
Transition.STYLES = {
  warp_fade = { kind = "fade", frames = FRAMES },
  white_flash = { kind = "fade", frames = FLASH_FRAMES },
}

function Transition.registerInto(registry, _, owner)
  for id, record in pairs(Transition.STYLES) do
    registry:register(id, record, owner)
  end
end

-- the merged record, falling back to the built-in when no data is around
-- (headless callers, and any state built before Data:load)
local function styleOf(game, id)
  local data = game and game.data
  local record = data and data.transitions and data.transitions[id]
  return record or Transition.STYLES[id]
end

function Transition.new(game, onMidpoint, onDone)
  local self = setmetatable({}, Transition)
  self.game = game
  self.onMidpoint = onMidpoint
  self.onDone = onDone
  self.t = 0
  self.phase = "out"
  self.frames = styleOf(game, "warp_fade").frames or FRAMES
  return self
end

function Transition:update(dt)
  self.t = self.t + 1
  if self.t >= self.frames then
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
  local alpha = self.t / self.frames
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
  return setmetatable({ game = game,
                        frames = frames or styleOf(game, "white_flash").frames
                                 or FLASH_FRAMES,
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
