-- Overworld survey zoom: integer pixels-per-world-pixel scales stepped
-- by the mouse wheel.  Stored as an offset from the window fit scale S
-- so a resize keeps the relative zoom.  Session-only; never saved.
-- Spec: docs/new-features.md (survey zoom)

local Zoom = {}

Zoom.offset = 0

-- effective integer scale s' in [1, 2*S]
function Zoom.scale(S)
  return math.max(1, math.min(2 * S, S + Zoom.offset))
end

function Zoom.step(delta, S)
  Zoom.offset = Zoom.offset + delta
  if S + Zoom.offset < 1 then Zoom.offset = 1 - S end
  if S + Zoom.offset > 2 * S then Zoom.offset = S end
end

function Zoom.reset()
  Zoom.offset = 0
end

-- world pixels covered by a w x h letterbox viewport at fit scale S
-- (legacy GB-framed size; prefer fillViewSize for the live world pass)
function Zoom.viewSize(S, w, h)
  local s = Zoom.scale(S)
  return math.ceil(w * S / s), math.ceil(h * S / s)
end

-- world pixels needed to fill a ww x wh window at the current zoom scale
-- (fills letterbox "black voids" with more map,  phones, tall windows)
function Zoom.fillViewSize(s, ww, wh)
  return math.ceil(ww / s), math.ceil(wh / s)
end

-- zoom input is honored only while free-roaming the overworld
function Zoom.gateOK(top, overworld)
  if top == nil or top ~= overworld then return false end
  if top.transitioning then return false end
  if top.runner and top.runner.isRunning and top.runner:isRunning() then
    return false
  end
  return true
end

return Zoom
