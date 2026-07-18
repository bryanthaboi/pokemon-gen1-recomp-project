-- Camera centered on the player.  At the default 160x144 view this is
-- the original framing (player sprite at screen tile (8,8) -> pixel
-- (64, 60) after the -4px sprite offset); wider/taller world-pass views
-- (window-filling survey on phones, wheel zoom-out) keep the player at
-- the same relative center.

local Camera = {}
Camera.__index = Camera

function Camera.new()
  return setmetatable({ x = 0, y = 0 }, Camera)
end

function Camera:follow(px, py, viewW, viewH)
  viewW, viewH = viewW or 160, viewH or 144
  self.x = px - (viewW / 2 - 16)
  self.y = py - (viewH / 2 - 8)
end

return Camera
