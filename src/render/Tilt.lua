-- Overworld tilt mode: a cycleable, purely presentational perspective
-- tilt for the free-roam overworld.  The flat world canvas is treated as
-- a ground plane, rotated about the horizontal axis through the viewport
-- centre and viewed through a perspective camera, so rows above centre
-- recede/shrink and rows below come closer (the HD-2D "diorama" look).
-- Like survey zoom this lives entirely in the draw path -- zero effect
-- on collision, movement, triggers, scripts -- and is persisted via
-- save.options.tilt (OFF / 15 / 35 / 50).
--
-- Spec: docs/new-features.md (tilt mode)

local Zoom = require("src.render.Zoom")

local Tilt = {}

-- Discrete tilt angles in degrees (index 0 is off).  Cycle: off→15→35→50→off.
Tilt.ANGLES_DEG = { 0, 15, 35, 50 }
Tilt.ANGLE_LABELS = { "OFF", "15", "35", "50" }

-- Runtime state.  `level` is the discrete option (0=off .. 3=50°);
-- `angle` is the live tweened tilt in radians; `from`/`goal`/`t` drive
-- the ease between any two levels (including off).
Tilt.level = 0
Tilt.angle = 0
Tilt.from = 0
Tilt.goal = 0
Tilt.t = 1
-- Compatibility: TARGET_ANGLE is the current goal; enabled mirrors level > 0.
Tilt.TARGET_ANGLE = 0
Tilt.enabled = false

Tilt.TWEEN_TIME = 0.25
Tilt.FOCAL = 1.0
Tilt.VIEW_MARGIN = 0.35

local function ease(t)
  return t * t * (3 - 2 * t)
end

local function goalFor(level)
  return math.rad(Tilt.ANGLES_DEG[level + 1] or 0)
end

function Tilt.setLevel(level)
  level = math.floor(tonumber(level) or 0)
  if level < 0 then level = 0 end
  if level > 3 then level = 3 end
  local goal = goalFor(level)
  if goal ~= Tilt.goal or level ~= Tilt.level then
    Tilt.from = Tilt.angle
    Tilt.goal = goal
    Tilt.t = 0
  end
  Tilt.level = level
  Tilt.TARGET_ANGLE = goal
  Tilt.enabled = level > 0
end

-- Advance OFF → 15 → 35 → 50 → OFF.  Returns the new level.
function Tilt.cycle()
  Tilt.setLevel((Tilt.level + 1) % 4)
  return Tilt.level
end

-- Legacy name: one cycle step (same as cycle).
function Tilt.toggle()
  return Tilt.cycle()
end

function Tilt.reset()
  Tilt.level = 0
  Tilt.angle = 0
  Tilt.from = 0
  Tilt.goal = 0
  Tilt.t = 1
  Tilt.TARGET_ANGLE = 0
  Tilt.enabled = false
end

function Tilt.applyOptions(opts)
  local level = math.floor(tonumber(opts and opts.tilt) or 0)
  if level < 0 then level = 0 end
  if level > 3 then level = 3 end
  Tilt.level = level
  Tilt.goal = goalFor(level)
  Tilt.from = Tilt.goal
  Tilt.angle = Tilt.goal
  Tilt.t = 1
  Tilt.TARGET_ANGLE = Tilt.goal
  Tilt.enabled = level > 0
end

function Tilt.levelLabel(level)
  return Tilt.ANGLE_LABELS[(level or Tilt.level) + 1] or "OFF"
end

-- Ease angle from `from` toward `goal` over TWEEN_TIME.
function Tilt.update(dt)
  if Tilt.t < 1 then
    Tilt.t = math.min(1, Tilt.t + dt / Tilt.TWEEN_TIME)
    local e = ease(Tilt.t)
    Tilt.angle = Tilt.from + (Tilt.goal - Tilt.from) * e
  else
    Tilt.angle = Tilt.goal
  end
  Tilt.TARGET_ANGLE = Tilt.goal
  Tilt.enabled = Tilt.level > 0
end

-- true while tilt is on *or* still tweening -- i.e. whenever the renderer
-- must take the perspective path rather than the flat blit
function Tilt.active()
  return Tilt.level > 0 or Tilt.angle > 0
end

function Tilt.gateOK(top, overworld)
  return Zoom.gateOK(top, overworld)
end

function Tilt.groundPoint(cx, cy, vw, vh)
  local a = Tilt.angle
  if a <= 0 then return cx, cy, 1 end
  local u = cx - vw * 0.5
  local w = cy - vh * 0.5
  local d = Tilt.FOCAL * vh
  local scale = d / (d - w * math.sin(a))
  local sx = vw * 0.5 + u * scale
  local sy = vh * 0.5 + w * math.cos(a) * scale
  return sx, sy, scale
end

function Tilt.viewGrowth()
  local a = Tilt.angle
  if a <= 0 then return 1 end
  local topScale = 1 / (1 + 0.5 * math.sin(a) / Tilt.FOCAL)
  local base = 1 / (math.cos(a) * topScale)
  return base + Tilt.VIEW_MARGIN * (base - 1)
end

function Tilt.meshCorners(vw, vh)
  local corners = {
    { 0, 0, 0, 0 },
    { vw, 0, 1, 0 },
    { vw, vh, 1, 1 },
    { 0, vh, 0, 1 },
  }
  local out = {}
  for i, c in ipairs(corners) do
    local sx, sy, scale = Tilt.groundPoint(c[1], c[2], vw, vh)
    out[i] = { sx, sy, c[3], c[4], scale }
  end
  return out
end

return Tilt
