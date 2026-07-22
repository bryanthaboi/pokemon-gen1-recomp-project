-- Overworld character sprites.  A 12-tile sheet (16x96 PNG) holds 6 16x16
-- frames: stand down/up/left, walk down/up/left (data/sprites/facings.asm).
-- Right-facing frames are horizontal flips of the left frames.
-- Sprites draw 4px above their cell, like the GB engine.

local Assets = require("src.render.Assets")
local PaletteFX = require("src.render.PaletteFX")

local SpriteRenderer = {}
SpriteRenderer.__index = SpriteRenderer

local imageCache = {}

local function getImage(path)
  if not imageCache[path] then
    imageCache[path] = Assets.image(path)
  end
  return imageCache[path]
end

-- RED++ overworld sprite OBJ-palette recolor (color/sprites.asm
-- ColorOverworldSprite), baked into an ImageData like BattleState's mon-pic
-- palette bake (src/battle/BattleState.lua getImage): CPU-remap the 4 DMG
-- shades to the resolved OBP colors, cached per (image path, group).
--
-- Sprite sheets carry no real alpha (every pixel, including the
-- background, is opaque -- confirmed by sampling the extracted PNGs): the
-- "transparent" look in every other draw path is a coincidence of the
-- whole-canvas shade-remap shader, where shade 0 (white) happens to map to
-- a similarly light color in whatever terrain zone the sprite stands over.
-- That coincidence breaks once terrain is colored per-tile instead of one
-- flat color per map (different tiles can have very different color-0s),
-- so shade 0 is keyed to alpha 0 here explicitly -- matching real GBC OBJ
-- hardware, where sprite palette index 0 is unconditionally transparent
-- (same rule TileRenderer's getColor0KeyShader documents for tall grass).
local obpCache = {}

local function getObpImage(path, colors, group)
  local key = path .. "#obp" .. group
  if not obpCache[key] then
    local img
    if love.image and love.image.newImageData then
      local id = Assets.imageData(path)
      id:mapPixel(function(_, _, r, g, b, a)
        if a == 0 then return r, g, b, a end
        if r > 0.83 then return r, g, b, 0 end -- OBJ color 0: always transparent
        local col = r > 0.5 and colors[2] or r > 0.17 and colors[3] or colors[4]
        return col[1] / 255, col[2] / 255, col[3] / 255, a
      end)
      img = love.graphics.newImage(id)
    else
      img = getImage(path) -- headless stub: no pixel access
    end
    obpCache[key] = img
  end
  return obpCache[key]
end

-- hot reload drops the sheets; live instances hold their own image, so
-- the world rebuilds them (MapLoader.invalidateAll) rather than this
function SpriteRenderer.invalidate()
  imageCache = {}
  obpCache = {}
end

Assets.register(SpriteRenderer.invalidate)

local STAND = { down = 0, up = 1, left = 2, right = 2 }
local WALK = { down = 3, up = 4, left = 5, right = 5 }

-- seed: any stable per-instance value (e.g. an NPC's `id`) used to resolve
-- RED++'s per-instance "random" OBP sentinel (PaletteFX.spriteObp)
function SpriteRenderer.new(spriteDef, seed)
  local self = setmetatable({}, SpriteRenderer)
  self.def = spriteDef
  self.seed = seed
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
local function blitFrame(image, quad, x, y, flip, redraw)
  if flip then
    love.graphics.draw(image, quad, x + 16, y, 0, -1, 1)
    if redraw then PaletteFX.markSpriteRedraw(image, quad, x + 16, y, -1) end
  else
    love.graphics.draw(image, quad, x, y)
    if redraw then PaletteFX.markSpriteRedraw(image, quad, x, y, 1) end
  end
end

function SpriteRenderer:draw(px, py, camX, camY, facing, walkPhase, stepFlip)
  local x = math.floor(px - camX)
  local y = math.floor(py - camY) - 4
  local image = self.image
  local redraw = false
  -- full-color art claims its 16x16 cell out of the shade-remap pass
  if self.def.trueColor then
    PaletteFX.markTrueColor(x, y, 16, 16)
  elseif PaletteFX.usesGbcPack() then
    -- RED++: the world canvas is already true-color (TileRenderer bakes
    -- terrain, this bakes the sprite) and the world pass runs unshaded
    -- (OverworldState.sgbWorldZones), so this draws like any normal sprite
    -- -- opaque character pixels over a real-alpha-transparent background,
    -- no trueColor rect needed (there is no shader left to exempt it from).
    local colors, group = PaletteFX.spriteObp(self.def, self.seed)
    if colors then
      image = getObpImage(self.def.image, colors, group)
    end
  elseif PaletteFX.usesSpriteObp() and PaletteFX.spriteRedrawPassActive() then
    -- plain GBC: the terrain zone shader still runs over the world canvas,
    -- so the baked sprite is also queued for a post-zone redraw
    -- (PaletteFX.markSpriteRedraw) that restores its own OBP colors on top
    local colors, group = PaletteFX.spriteObp(self.def, self.seed)
    if colors then
      image = getObpImage(self.def.image, colors, group)
      redraw = true
    end
  end
  -- single-frame sprites (item balls, fossils...) have one fixed pose;
  -- still 3-frame sprites turn to face (the nurse at her machine,
  -- facePlayer on STAY NPCs) but never show walk frames
  if self.def.frames <= 1 then
    blitFrame(image, self.frames[0], x, y, false, redraw)
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
  blitFrame(image, quad, x, y, flip, redraw)
end

return SpriteRenderer
