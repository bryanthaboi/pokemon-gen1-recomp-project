-- Touch gesture recognizer → virtual keyboard keys for Input.lua.
--
-- Deferred-tap tradeoff: A fires only after DOUBLE_TAP_MS with no second
-- tap. That adds ~280ms latency to every A press so a double-tap can be
-- remapped to START instead of A-then-START. Gen 1 has no frame-perfect
-- input needs, so the latency is acceptable.
--
-- Select = two-finger tap (open Q1 in docs/mobile-plan.md): when a second distinct
-- touch ID lands while another short, low-movement touch is active, fire
-- SELECT (press + one-frame auto-release).

local Input = require("src.core.Input")

local TouchInput = {}

local function dpiScale()
  if love and love.window then
    if love.window.getDPIScale then
      return love.window.getDPIScale()
    end
    if love.window.toPixels then
      return love.window.toPixels(1)
    end
  end
  return 1
end

-- Tunables (device-DPI-scaled where noted). Adjust after on-device testing.
local SWIPE_THRESHOLD_PX = 14
local EDGE_PX = 24
local EDGE_SWIPE_PX = 24
local DOUBLE_TAP_MS = 280
local TAP_MAX_MS = 320
local TAP_MAX_MOVE_PX = 12

local function scaled(px)
  return px * dpiScale()
end

local DIRS = { up = true, down = true, left = true, right = true }

-- Virtual keys Input:keypressed looks up in KEYBOARD bindings (not button names).
local KEY = {
  up = "up",
  down = "down",
  left = "left",
  right = "right",
  a = "z",
  b = "x",
  start = "escape",
  select = "rshift",
}

local function nowMs()
  return love.timer.getTime() * 1000
end

local function dominantDir(dx, dy)
  if math.abs(dx) >= math.abs(dy) then
    return dx > 0 and "right" or "left"
  end
  return dy > 0 and "down" or "up"
end

function TouchInput:init()
  self.touches = {}
  self.pendingA = nil          -- { deadlineMs = number }
  -- Edge pulses (B / START / SELECT / deferred-A): press now, release on a
  -- later update so FixedStep can consume wasPressed first.
  -- `armed` = pressed during events since last update; promoted to
  -- `autoRelease` at the start of update (released on the *following* update).
  -- Deferred-A fired inside update goes straight into `autoRelease`.
  self.armed = {}
  self.autoRelease = {}
  self.selectFired = false     -- one SELECT per two-finger gesture cluster
end

local function pulse(self, key)
  Input:keypressed(key)
  self.armed[#self.armed + 1] = key
end

local function pulseInUpdate(self, key)
  Input:keypressed(key)
  self.autoRelease[#self.autoRelease + 1] = key
end

local function releaseDir(self, touch)
  if touch.dir and DIRS[touch.dir] then
    Input:keyreleased(KEY[touch.dir])
    touch.dir = nil
  end
end

local function pressDir(self, touch, dir)
  if touch.dir == dir then return end
  releaseDir(self, touch)
  touch.dir = dir
  Input:keypressed(KEY[dir])
end

local function totalMove(touch, x, y)
  local dx = x - touch.x0
  local dy = y - touch.y0
  return math.abs(dx), math.abs(dy), dx, dy
end

local function isTapLike(touch, x, y, tMs)
  local ax, ay = totalMove(touch, x, y)
  local elapsed = tMs - touch.t0
  return elapsed <= TAP_MAX_MS
     and ax <= scaled(TAP_MAX_MOVE_PX)
     and ay <= scaled(TAP_MAX_MOVE_PX)
     and not touch.classified
end

local function countActive(self)
  local n = 0
  for _ in pairs(self.touches) do n = n + 1 end
  return n
end

local function tryTwoFingerSelect(self, tMs)
  if self.selectFired then return false end
  local ids = {}
  for id, touch in pairs(self.touches) do
    if isTapLike(touch, touch.x, touch.y, tMs) then
      ids[#ids + 1] = id
    end
  end
  if #ids < 2 then return false end

  self.selectFired = true
  self.pendingA = nil
  for _, id in ipairs(ids) do
    local touch = self.touches[id]
    touch.classified = true
    touch.consumed = true
    releaseDir(self, touch)
  end
  pulse(self, KEY.select)
  return true
end

function TouchInput:update(dt)
  -- Releases armed on a prior update (FixedStep already saw wasPressed).
  for i = 1, #self.autoRelease do
    Input:keyreleased(self.autoRelease[i])
  end
  -- Promote event-phase pulses from since the last update; they release next time.
  self.autoRelease = self.armed
  self.armed = {}

  local tMs = nowMs()

  -- Deferred A: fire once the double-tap window closes with no second tap.
  -- Queued into autoRelease so the next update clears hold after this FixedStep.
  if self.pendingA and tMs >= self.pendingA.deadlineMs then
    self.pendingA = nil
    pulseInUpdate(self, KEY.a)
  end

  -- Keep two-finger SELECT detection live while both fingers stay down.
  if countActive(self) >= 2 then
    tryTwoFingerSelect(self, tMs)
  elseif countActive(self) == 0 then
    self.selectFired = false
  end
end

function TouchInput:touchpressed(id, x, y)
  local tMs = nowMs()

  -- Second tap inside the deferred-A window → START instead of A.
  if self.pendingA and tMs < self.pendingA.deadlineMs then
    self.pendingA = nil
    pulse(self, KEY.start)
    -- Still record this touch so a lingering finger doesn't become a stray swipe.
    self.touches[id] = {
      x0 = x, y0 = y, x = x, y = y, t0 = tMs,
      edge = x < scaled(EDGE_PX),
      classified = true,
      consumed = true,
      dir = nil,
    }
    return
  end

  self.touches[id] = {
    x0 = x, y0 = y, x = x, y = y, t0 = tMs,
    edge = x < scaled(EDGE_PX),
    classified = false,
    consumed = false,
    dir = nil,
  }

  if countActive(self) >= 2 then
    tryTwoFingerSelect(self, tMs)
  end
end

function TouchInput:touchmoved(id, x, y)
  local touch = self.touches[id]
  if not touch or touch.consumed then return end

  touch.x, touch.y = x, y
  local ax, ay, dx, dy = totalMove(touch, x, y)
  local swipeTh = scaled(SWIPE_THRESHOLD_PX)

  -- Edge-origin swipes become B on release; never promote to d-pad.
  if touch.edge then
    if ax >= scaled(EDGE_SWIPE_PX) or ay >= scaled(EDGE_SWIPE_PX) then
      touch.classified = true
    end
    return
  end

  if not touch.classified then
    if ax < swipeTh and ay < swipeTh then return end
    touch.classified = true
    pressDir(self, touch, dominantDir(dx, dy))
    return
  end

  -- Mid-hold direction change: release old, press new (dominant axis).
  if touch.dir then
    local fromLastX = x - touch.x0
    local fromLastY = y - touch.y0
    -- Re-evaluate from origin so small jitter doesn't flip; require threshold
    -- distance from origin along the new dominant axis.
    if math.abs(fromLastX) >= swipeTh or math.abs(fromLastY) >= swipeTh then
      local newDir = dominantDir(fromLastX, fromLastY)
      if newDir ~= touch.dir then
        pressDir(self, touch, newDir)
      end
    end
  end
end

function TouchInput:touchreleased(id, x, y)
  local touch = self.touches[id]
  if not touch then return end

  local tMs = nowMs()
  touch.x, touch.y = x, y
  local ax, ay = totalMove(touch, x, y)

  if touch.dir then
    releaseDir(self, touch)
    self.touches[id] = nil
    if countActive(self) == 0 then self.selectFired = false end
    return
  end

  if touch.consumed then
    self.touches[id] = nil
    if countActive(self) == 0 then self.selectFired = false end
    return
  end

  -- Left-edge B: origin in EDGE_PX strip and movement past EDGE_SWIPE_PX
  -- (or already marked classified while moving). Prefer over d-pad / tap.
  if touch.edge then
    local edgeTh = scaled(EDGE_SWIPE_PX)
    if touch.classified or ax >= edgeTh or ay >= edgeTh then
      pulse(self, KEY.b)
      self.touches[id] = nil
      if countActive(self) == 0 then self.selectFired = false end
      return
    end
  end

  -- Plain tap → defer A (or it was already classified as swipe without dir, ignore).
  if isTapLike(touch, x, y, tMs) then
    self.pendingA = { deadlineMs = tMs + DOUBLE_TAP_MS }
  end

  self.touches[id] = nil
  if countActive(self) == 0 then self.selectFired = false end
end

return TouchInput
