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

function FixedStep:update(dt)
  self.accum = math.min(self.accum + dt, MAX_ACCUM)
  while self.accum >= self.STEP do
    self.accum = self.accum - self.STEP
    self.callback(self.STEP)
  end
end

return FixedStep
