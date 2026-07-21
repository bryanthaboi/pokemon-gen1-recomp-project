-- Fixed-step update loop at the Game Boy's ~60Hz.  Game logic advances in
-- whole steps regardless of the display refresh rate, which keeps movement,
-- text speed and battle timing deterministic.

local FixedStep = {}

FixedStep.STEP = 1 / 60
local MAX_ACCUM = 0.25 -- avoid spiral of death after a stall

function FixedStep:init(callback)
  self.accum = 0
  self.callback = callback
end

-- The anti-spiral clamp doubles as a steps-per-frame ceiling (0.25s = 15
-- steps), which silently throttled the high fast-forward levels: at 100X
-- a 60fps frame wants ~100 steps. Game:update raises this to fit the
-- current speed target; a stall still cannot snowball past one frame's
-- intended budget.
FixedStep.maxAccum = MAX_ACCUM

function FixedStep:update(dt)
  self.accum = math.min(self.accum + dt, self.maxAccum or MAX_ACCUM)
  while self.accum >= self.STEP do
    self.accum = self.accum - self.STEP
    self.callback(self.STEP)
  end
end

return FixedStep
