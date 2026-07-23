-- Input abstraction: maps keyboard to Game Boy buttons.
-- `down` = held this frame; `pressed` = edge, consumed per fixed step.

local Input = {}

local DEFAULT_BINDINGS = {
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
-- across Xbox/PlayStation/generic controllers on desktop and mobile. Some
-- third-party pads report their own SDL mapping for a given physical
-- button (e.g. Select/Back/View on off-brand XInput pads), which is what
-- src/ui/BindingsMenu.lua's rebinding is for -- see applyBindings below.
local DEFAULT_GAMEPAD_BINDINGS = {
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
  self:applyBindings(nil)
  self:reset()
end

-- Layers a player's rebind choices (save.options.bindings, written by
-- src/ui/BindingsMenu.lua) on top of the defaults above. A rebind adds an
-- extra way to trigger that action instead of replacing the default key,
-- so e.g. Z/Enter/Space all still press A even after binding a 4th key to
-- it. Call whenever options load or change (see Game:applyOptions and
-- BindingsMenu:storeBinding) -- without this the menu records a choice
-- that never actually reaches gameplay.
function Input:applyBindings(overlay)
  local keys, pads = {}, {}
  for key, action in pairs(DEFAULT_BINDINGS) do keys[key] = action end
  for button, action in pairs(DEFAULT_GAMEPAD_BINDINGS) do pads[button] = action end
  for actionId, binding in pairs(overlay or {}) do
    if type(binding) == "table" then
      if binding.key then keys[binding.key] = actionId end
      if binding.pad then pads[binding.pad] = actionId end
    elseif type(binding) == "string" then
      keys[binding] = actionId
    end
  end
  self.keyBindings = keys
  self.padBindings = pads
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
  self.sources = {}
  self.stickAxis = { x = 0, y = 0 }
  self.stickDir = nil
end

-- Multiple physical sources (W + Up, d-pad + stick, etc.) can claim the
-- same GB button. Track them individually so releasing one doesn't clear
-- a hold another source still owns, and so a press+release that both land
-- before the next FixedStep can't be revived when step() drains the queue.
local function press(self, btn, source)
  local sources = self.sources[btn]
  if not sources then
    sources = {}
    self.sources[btn] = sources
  end
  if not sources[source] then
    sources[source] = true
    table.insert(self.pressQueue, btn)
  end
  self.state[btn] = true
end

local function release(self, btn, source)
  local sources = self.sources[btn]
  if sources then
    sources[source] = nil
    if next(sources) == nil then
      -- Leave an empty table (not nil) so step() can tell a real
      -- source was released before the queue drained, versus a
      -- synthetic pressQueue inject that never had sources at all.
      self.state[btn] = false
    end
  else
    self.state[btn] = false
  end
end

function Input:keypressed(key)
  local btn = self.keyBindings[key]
  if btn then
    press(self, btn, "key:" .. key)
  end
end

function Input:keyreleased(key)
  local btn = self.keyBindings[key]
  if btn then
    release(self, btn, "key:" .. key)
  end
end

-- Called once per fixed step: promote queued presses to this step's edges.
-- Hold state is owned by live sources (updated in press/release), not
-- re-asserted here -- otherwise a same-frame press→release leaves the
-- button stuck on after the queue drains.
-- Synthetic injects (tests/drivers writing pressQueue directly, with no
-- source entry) still set state so scripted holds keep working.
function Input:step()
  self.pressed = {}
  for _, btn in ipairs(self.pressQueue) do
    self.pressed[btn] = true
    local sources = self.sources[btn]
    if sources == nil then
      -- synthetic pressQueue inject (tests/drivers): no live source map
      self.state[btn] = true
    elseif next(sources) ~= nil then
      self.state[btn] = true
    end
    -- sources == {}: real press fully released before this step — keep up
  end
  for btn, sources in pairs(self.sources) do
    if next(sources) == nil then
      self.sources[btn] = nil
    end
  end
  self.pressQueue = {}
end

function Input:gamepadpressed(joystick, button)
  local btn = self.padBindings[button]
  if btn then
    press(self, btn, "pad:" .. button)
  end
end

function Input:gamepadreleased(joystick, button)
  local btn = self.padBindings[button]
  if btn then
    release(self, btn, "pad:" .. button)
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
      release(self, self.stickDir, "stick")
    end
    if newDir then
      press(self, newDir, "stick")
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
