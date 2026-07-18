-- Overworld character sprites.  A 12-tile sheet (16x96 PNG) holds 6 16x16
-- frames: stand down/up/left, walk down/up/left (data/sprites/facings.asm).
-- Right-facing frames are horizontal flips of the left frames.
-- Sprites draw 4px above their cell, like the GB engine.

local SpriteRenderer = {}
SpriteRenderer.__index = SpriteRenderer

local imageCache = {}

local function getImage(path)
  if not imageCache[path] then
    imageCache[path] = love.graphics.newImage(path)
  end
  return imageCache[path]
end

local STAND = { down = 0, up = 1, left = 2, right = 2 }
local WALK = { down = 3, up = 4, left = 5, right = 5 }

function SpriteRenderer.new(spriteDef)
  local self = setmetatable({}, SpriteRenderer)
  self.def = spriteDef
  self.image = getImage(spriteDef.image)
  local iw, ih = self.image:getDimensions()
  self.frames = {}
  for f = 0, spriteDef.frames - 1 do
    self.frames[f] = love.graphics.newQuad(0, f * 16, 16, 16, iw, ih)
  end
  return self
end

-- facing: down/up/left/right; walkPhase: 0 stand, 1 walk; flip: alternate
-- steps mirror the walk frame for up/down (GB uses OAM flip for this).
function SpriteRenderer:draw(px, py, camX, camY, facing, walkPhase, stepFlip)
  local x = math.floor(px - camX)
  local y = math.floor(py - camY) - 4
  -- single-frame sprites (item balls, fossils...) have one fixed pose;
  -- still 3-frame sprites turn to face (the nurse at her machine,
  -- facePlayer on STAY NPCs) but never show walk frames
  if self.def.frames <= 1 then
    love.graphics.draw(self.image, self.frames[0], x, y)
    return
  end
  local frame = (self.def.walker and walkPhase == 1)
                and WALK[facing] or STAND[facing]
  local flip = false
  if facing == "right" then
    flip = true
  elseif (facing == "down" or facing == "up") and walkPhase == 1 and stepFlip then
    flip = true
  end
  local quad = self.frames[frame] or self.frames[0]
  if flip then
    love.graphics.draw(self.image, quad, x + 16, y, 0, -1, 1)
  else
    love.graphics.draw(self.image, quad, x, y)
  end
end

return SpriteRenderer
