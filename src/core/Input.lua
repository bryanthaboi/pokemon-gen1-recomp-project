-- Input abstraction: maps keyboard to Game Boy buttons.
-- `down` = held this frame; `pressed` = edge, consumed per fixed step.

local Input = {}

local BINDINGS = {
  up = "up", w = "up",
  down = "down", s = "down",
  left = "left", a = "left",
  right = "right", d = "right",
  z = "a", ["return"] = "a", space = "a",
  x = "b", backspace = "b",
  ["kpenter"] = "start", escape = "start",
  rshift = "select",
}

-- keys that map to "start" but also to "a" would conflict; keep Enter = a,
-- Escape = start for desktop friendliness.

-- LÖVE's standard gamepad mapping (SDL game controller DB), consistent
-- across Xbox/PlayStation/generic controllers on desktop and mobile.
local GAMEPAD_BINDINGS = {
  dpup = "up", dpdown = "down", dpleft = "left", dpright = "right",
  a = "a", b = "b",
  start = "start", back = "select",
}

-- left-stick deadzones: press past STICK_ON, release once back under
-- STICK_OFF. The gap (hysteresis) stops the direction from flickering
-- while the stick sits near the threshold.
local STICK_ON = 0.5
local STICK_OFF = 0.3

function Input:init()
  self:reset()
end

-- Purely event-driven state (press sets true, release sets false) has no
-- fallback if a release event never arrives -- focus loss, a minimized
-- window, or a disconnected gamepad can all swallow the key-up/button-up
-- that would have cleared a held direction. Called from Game on those
-- transitions so a stuck flag can't outlive them.
function Input:reset()
  self.state = {}
  self.pressQueue = {}
  self.pressed = {}
  self.stickAxis = { x = 0, y = 0 }
  self.stickDir = nil
end

function Input:keypressed(key)
  local btn = BINDINGS[key]
  if btn then
    table.insert(self.pressQueue, btn)
  end
end

function Input:keyreleased(key)
  local btn = BINDINGS[key]
  if btn then
    self.state[btn] = false
  end
end

-- Called once per fixed step: promote queued presses to this step's edges.
function Input:step()
  self.pressed = {}
  for _, btn in ipairs(self.pressQueue) do
    self.pressed[btn] = true
    self.state[btn] = true
  end
  self.pressQueue = {}
end

function Input:gamepadpressed(joystick, button)
  local btn = GAMEPAD_BINDINGS[button]
  if btn then
    table.insert(self.pressQueue, btn)
  end
end

function Input:gamepadreleased(joystick, button)
  local btn = GAMEPAD_BINDINGS[button]
  if btn then
    self.state[btn] = false
  end
end

-- left stick treated as a continuous held direction, same 4-way rule as
-- the touch swipe d-pad: whichever axis has the larger magnitude wins.
function Input:gamepadaxis(joystick, axis, value)
  if axis == "leftx" then
    self.stickAxis.x = value
  elseif axis == "lefty" then
    self.stickAxis.y = value
  else
    return
  end

  local x, y = self.stickAxis.x, self.stickAxis.y
  local ax, ay = math.abs(x), math.abs(y)
  local newDir = self.stickDir
  if ax > STICK_ON or ay > STICK_ON then
    if ax >= ay then
      newDir = x > 0 and "right" or "left"
    else
      newDir = y > 0 and "down" or "up"
    end
  elseif ax < STICK_OFF and ay < STICK_OFF then
    newDir = nil
  end

  if newDir ~= self.stickDir then
    if self.stickDir then
      self.state[self.stickDir] = false
    end
    if newDir then
      table.insert(self.pressQueue, newDir)
    end
    self.stickDir = newDir
  end
end

function Input:isDown(btn)
  return self.state[btn] or false
end

function Input:wasPressed(btn)
  return self.pressed[btn] or false
end

return Input
