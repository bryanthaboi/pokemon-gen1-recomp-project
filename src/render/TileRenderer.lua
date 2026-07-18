-- Draws a map's tile layer: one texture atlas per tileset, 8x8 quads,
-- a single static SpriteBatch covering the map plus a border-block ring
-- (the ring plays the role of the GB border blocks around small maps).

local TileRenderer = {}
TileRenderer.__index = TileRenderer

local BORDER_BLOCKS = 3 -- ring width; > half a screen (2.5 blocks)

-- OVERWORLD maps fill beyond-edge space with the solid tree wall
-- (blockset $0F: four regular-tree metatiles, tiles $40/$41/$50/$51, 
-- the border block of ViridianCity/CeruleanCity/CeladonCity et al.),
-- not each map's own border_block, which can be grass ($0B, the
-- CutTreeBlockSwaps $0B->$0A cut-grass block) or water; other
-- tilesets keep their designated border (interiors stay black/void)
local TREE_WALL_BLOCK = 0x0F
local function borderBlockFor(map)
  if map.def.tileset == "OVERWORLD" then return TREE_WALL_BLOCK end
  return map.def.borderBlock
end
TileRenderer.borderBlockFor = borderBlockFor

local imageCache = {}

local function getImage(path)
  if not imageCache[path] then
    imageCache[path] = love.graphics.newImage(path)
  end
  return imageCache[path]
end

-- ------------------------------------------------------------------
-- Tile animation (home/vcopy.asm): tilesets with TILEANIM_WATER[_FLOWER]
-- rotate water tile $14 one pixel every 20 frames (4 steps right, 4
-- left) and cycle flower tile $03 through 3 frames.
-- ------------------------------------------------------------------

local WATER_TILE, FLOWER_TILE = 0x14, 0x03
-- cumulative pixel offset per animation step (the rrca/rlca sequence)
local WATER_OFFSETS = { 1, 2, 3, 2, 1, 0, 7, 0 }
-- flower frame per step (wMovingBGTilesCounter2 & 3: <2 -> 1, 2, 3)
local FLOWER_FRAMES = { 1, 2, 3, 1, 1, 2, 3, 1 }

local animFrame = 0
function TileRenderer.tick()
  animFrame = animFrame + 1
end

-- ------------------------------------------------------------------
-- Spinner arrow tiles (engine/overworld/spinners.asm LoadSpinnerArrowTiles):
-- a wholly separate, contextually-triggered VRAM patch layered on top of
-- the ambient water/flower cycle above -- while wMovementFlags.BIT_SPINNING
-- is set (Gym/Rocket Hideout spinner puzzles), each forced-movement step
-- farcalls LoadSpinnerArrowTiles, which flips 4 fixed destination tile IDs
-- per tileset between the shared 'blur' graphic (gfx/overworld/spinners.2bpp,
-- SpinnerArrowAnimTiles) and the tileset's own static graphic (restore).
-- Only 2 distinct frames exist -- no continuous multi-frame cycle.
-- ------------------------------------------------------------------

-- data/tilesets/spinner_tiles.asm: dest tile IDs patched per tileset
TileRenderer.SPINNER_ARROW_TILES = {
  GYM = { 0x3c, 0x3d, 0x4c, 0x4d },
  FACILITY = { 0x20, 0x21, 0x30, 0x31 },
}

-- dest tile id -> offset (in 8x8 tiles) into the SpinnerArrowAnimTiles strip,
-- taken verbatim from the `spinner SpinnerArrowAnimTiles, <offset>, <dest>`
-- rows of data/tilesets/spinner_tiles.asm
local SPINNER_STRIP_OFFSET = {
  GYM = { [0x3c] = 1, [0x3d] = 3, [0x4c] = 0, [0x4d] = 2 },
  FACILITY = { [0x20] = 0, [0x21] = 1, [0x30] = 2, [0x31] = 3 },
}

local spinning = false
function TileRenderer.setSpinning(active)
  spinning = active
end

-- true while the spinner arrow tiles should show the 'blur' graphic; false
-- means draw nothing extra (the static mapBatch/ringBatch tile shows
-- through, matching the asm's restore-to-original behavior). The 8-tick
-- half-period approximates one GB movement step (2px/frame); this is a
-- deliberate approximation of wSimulatedJoypadStatesIndex bit-0 parity, not
-- a cycle-accurate replication -- the port's tweened scriptMove has no
-- direct equivalent discrete step counter.
function TileRenderer.spinBlurActive()
  return spinning and (math.floor(animFrame / 8) % 2 == 0)
end

-- the 8 shifted variants of a tileset's water tile (built once per sheet)
local waterVariants = {}
local function getWaterVariants(tilesetImagePath, perRow)
  if waterVariants[tilesetImagePath] ~= nil then
    return waterVariants[tilesetImagePath]
  end
  if not (love.image and love.image.newImageData) then
    waterVariants[tilesetImagePath] = false
    return false
  end
  local id = love.image.newImageData(tilesetImagePath)
  local sx = (WATER_TILE % perRow) * 8
  local sy = math.floor(WATER_TILE / perRow) * 8
  local out = {}
  for o = 0, 7 do
    local v = love.image.newImageData(8, 8)
    for y = 0, 7 do
      for x = 0, 7 do
        local r, g, b, a = id:getPixel(sx + x, sy + y)
        v:setPixel((x + o) % 8, y, r, g, b, a)
      end
    end
    out[o + 1] = love.graphics.newImage(v)
  end
  waterVariants[tilesetImagePath] = out
  return out
end

local flowerFrames
local function getFlowerFrames()
  if flowerFrames ~= nil then return flowerFrames end
  flowerFrames = {}
  for i = 1, 3 do
    local ok, img = pcall(love.graphics.newImage,
                          ("assets/generated/tilesets/flower%d.png"):format(i))
    if not ok then flowerFrames = false return false end
    flowerFrames[i] = img
  end
  return flowerFrames
end

-- the tileset's own atlas ImageData with the 4 spinner-tile slots blitted
-- over with the shared blur strip (assets/generated/tilesets/spinners.png,
-- extracted from gfx/overworld/spinners.png); cached per tileset image path
local spinnerBlurImages = {}
local spinnerStripData
local function getSpinnerBlurImage(tilesetId, tilesetImagePath, perRow)
  if spinnerBlurImages[tilesetImagePath] ~= nil then
    return spinnerBlurImages[tilesetImagePath]
  end
  if not (love.image and love.image.newImageData) then
    spinnerBlurImages[tilesetImagePath] = false
    return false
  end
  local destTiles = TileRenderer.SPINNER_ARROW_TILES[tilesetId]
  local offsets = SPINNER_STRIP_OFFSET[tilesetId]
  if not (destTiles and offsets) then
    spinnerBlurImages[tilesetImagePath] = false
    return false
  end
  if spinnerStripData == nil then
    local ok, id = pcall(love.image.newImageData,
                         "assets/generated/tilesets/spinners.png")
    spinnerStripData = ok and id or false
  end
  if not spinnerStripData then
    spinnerBlurImages[tilesetImagePath] = false
    return false
  end
  local atlas = love.image.newImageData(tilesetImagePath)
  local clone = love.image.newImageData(atlas:getWidth(), atlas:getHeight())
  clone:paste(atlas, 0, 0, 0, 0, atlas:getWidth(), atlas:getHeight())
  for _, id in ipairs(destTiles) do
    local sx = offsets[id] * 8
    local dx = (id % perRow) * 8
    local dy = math.floor(id / perRow) * 8
    for y = 0, 7 do
      for x = 0, 7 do
        local r, g, b, a = spinnerStripData:getPixel(sx + x, y)
        clone:setPixel(dx + x, dy + y, r, g, b, a)
      end
    end
  end
  local img = love.graphics.newImage(clone)
  spinnerBlurImages[tilesetImagePath] = img
  return img
end

function TileRenderer.new(map)
  local self = setmetatable({}, TileRenderer)
  self.map = map
  self.image = getImage(map.tileset.image)

  local iw, ih = self.image:getDimensions()
  self.quads = {}
  local perRow = map.tileset.tilesPerRow
  for t = 0, (iw / 8) * (ih / 8) - 1 do
    self.quads[t] = love.graphics.newQuad((t % perRow) * 8,
                                          math.floor(t / perRow) * 8, 8, 8, iw, ih)
  end

  local def = map.def
  local wB, hB = def.width, def.height
  -- two batches: the border-block ring around the map, and the map body.
  -- Connected-map strips draw body-only on top of this map's ring.
  local total = (wB + 2 * BORDER_BLOCKS) * (hB + 2 * BORDER_BLOCKS) * 16
  self.ringBatch = love.graphics.newSpriteBatch(self.image, total, "static")
  self.mapBatch = love.graphics.newSpriteBatch(self.image, wB * hB * 16, "static")
  -- animated tiles overdraw the static batches each frame
  local anim = map.tileset.animation
  local animWater = anim == "TILEANIM_WATER" or anim == "TILEANIM_WATER_FLOWER"
  local variants = animWater and getWaterVariants(map.tileset.image, perRow)
  local flowers = anim == "TILEANIM_WATER_FLOWER" and getFlowerFrames()
  -- Gym/Rocket-Hideout spinner-arrow tiles (see SPINNER_ARROW_TILES above);
  -- only GYM/FACILITY tilesets carry these dest tile ids
  local spinnerIds = TileRenderer.SPINNER_ARROW_TILES[map.tileset.id]
  local spinnerSet
  if spinnerIds then
    spinnerSet = {}
    for _, id in ipairs(spinnerIds) do spinnerSet[id] = true end
  end
  local water, flower, spinner = {}, {}, {}

  for by = -BORDER_BLOCKS, hB + BORDER_BLOCKS - 1 do
    for bx = -BORDER_BLOCKS, wB + BORDER_BLOCKS - 1 do
      local inside = bx >= 0 and by >= 0 and bx < wB and by < hB
      local batch = inside and self.mapBatch or self.ringBatch
      local block = map.tileset.blocks[map:blockAt(bx, by) + 1]
      for ty = 0, 3 do
        for tx = 0, 3 do
          local tile = block[ty * 4 + tx + 1]
          local quad = self.quads[tile]
          if quad then
            batch:add(quad, bx * 32 + tx * 8, by * 32 + ty * 8)
          end
          if variants and tile == WATER_TILE then
            table.insert(water, { bx * 32 + tx * 8, by * 32 + ty * 8, inside })
          elseif flowers and tile == FLOWER_TILE then
            table.insert(flower, { bx * 32 + tx * 8, by * 32 + ty * 8, inside })
          elseif spinnerSet and spinnerSet[tile] then
            table.insert(spinner, { bx * 32 + tx * 8, by * 32 + ty * 8, inside, tile })
          end
        end
      end
    end
  end

  -- animated overdraw batches: the full set (ring + body) for the
  -- current map, and a body-only set for connected-map drawing --
  -- a neighbor's water ring must never overdraw this map's tiles.
  -- `quadFor`, when given, looks up a per-entry quad (used by the spinner
  -- batch, whose texture is a full tileset-atlas clone rather than a
  -- single-tile image like the water/flower variants).
  local function animBatches(entries, image, quadFor)
    if #entries == 0 then return nil, nil end
    local all = love.graphics.newSpriteBatch(image, #entries, "static")
    local body
    for _, c in ipairs(entries) do
      if quadFor then all:add(quadFor(c[4]), c[1], c[2]) else all:add(c[1], c[2]) end
      if c[3] then
        body = body or love.graphics.newSpriteBatch(image, #entries, "static")
        if quadFor then body:add(quadFor(c[4]), c[1], c[2]) else body:add(c[1], c[2]) end
      end
    end
    return all, body
  end
  if variants then
    self.waterBatch, self.waterBodyBatch = animBatches(water, variants[1])
    self.waterVariants = self.waterBatch and variants or nil
  end
  if flowers then
    self.flowerBatch, self.flowerBodyBatch = animBatches(flower, flowers[1])
    self.flowerFrames = self.flowerBatch and flowers or nil
  end
  if spinnerSet then
    local blurImage = getSpinnerBlurImage(map.tileset.id, map.tileset.image, perRow)
    if blurImage then
      local quads = self.quads
      self.spinnerBatch, self.spinnerBodyBatch =
        animBatches(spinner, blurImage, function(tile) return quads[tile] end)
      self.spinnerBlurImage = self.spinnerBatch and blurImage or nil
    end
  end

  -- a repeating 32x32 image of the border block, tiled behind
  -- everything the 3-block ring doesn't cover (the survey zoom sees
  -- far past the ring; interiors keep their black border this way)
  pcall(function()
    local border = map.tileset.blocks[borderBlockFor(map) + 1]
    if not border then return end
    local canvas = love.graphics.newCanvas(32, 32)
    love.graphics.push("all")
    love.graphics.setCanvas(canvas)
    love.graphics.clear(1, 1, 1, 1)
    for ty = 0, 3 do
      for tx = 0, 3 do
        local quad = self.quads[border[ty * 4 + tx + 1]]
        if quad then love.graphics.draw(self.image, quad, tx * 8, ty * 8) end
      end
    end
    love.graphics.setCanvas()
    love.graphics.pop()
    local img = love.graphics.newImage(canvas:newImageData())
    img:setWrap("repeat", "repeat")
    img:setFilter("nearest", "nearest")
    self.borderFill = img
  end)

  return self
end

-- tile the border block across the whole view (world-aligned so it
-- meshes seamlessly with the ring batch)
function TileRenderer:drawBorderFill(camX, camY, vw, vh)
  if not self.borderFill then return end
  local x, y = math.floor(camX), math.floor(camY)
  local quad = love.graphics.newQuad(x, y, vw, vh, 32, 32)
  love.graphics.draw(self.borderFill, quad, 0, 0)
end

-- GB OBJ-to-BG priority: sprites show through BG color 0 and hide under
-- colors 1-3.  Tall-grass overdraw needs the same rule, otherwise the
-- tile's white gaps paint opaque boxes over the sprite's feet.
local color0KeyShader -- false = unavailable
local function getColor0KeyShader()
  if color0KeyShader ~= nil then return color0KeyShader or nil end
  local ok, sh = pcall(love.graphics.newShader, [[
    vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
      vec4 p = Texel(tex, tc) * color;
      // same shade-0 cutoff PaletteFX uses (DMG white / lightest gray)
      if (p.r > 0.83 && p.g > 0.83 && p.b > 0.83) p.a = 0.0;
      return p;
    }
  ]])
  color0KeyShader = ok and sh or false
  return color0KeyShader or nil
end

-- draw a cell's bottom tile row without touching the shader (the caller
-- owns it).  drawCellBottom wraps this with the color-0 key; tilt mode's
-- upright pass wraps it with a color-0-keyed palette shader instead
-- (PaletteFX.keyedShader) so the feet patch is colorized like the ground.
function TileRenderer:drawCellBottomRaw(cx, cy, camX, camY)
  local ty = cy * 2 + 1
  for i = 0, 1 do
    local tx = cx * 2 + i
    local quad = self.quads[self.map:tileAt(tx, ty)]
    if quad then
      love.graphics.draw(self.image, quad, tx * 8 - camX, ty * 8 - camY)
    end
  end
end

-- redraw a cell's bottom tile row (tall grass hides the lower half of
-- sprites standing in it, like the GB sprite-priority trick)
function TileRenderer:drawCellBottom(cx, cy, camX, camY)
  local shader = getColor0KeyShader()
  if shader then love.graphics.setShader(shader) end
  self:drawCellBottomRaw(cx, cy, camX, camY)
  if shader then love.graphics.setShader() end
end

-- water/flower overdraw at the current animation step; bodyOnly skips
-- the ring positions (connected maps draw body-only)
function TileRenderer:drawAnimated(camX, camY, bodyOnly)
  local waterBatch = bodyOnly and self.waterBodyBatch or self.waterBatch
  local flowerBatch = bodyOnly and self.flowerBodyBatch or self.flowerBatch
  local spinnerBatch = bodyOnly and self.spinnerBodyBatch or self.spinnerBatch
  if not (waterBatch or flowerBatch or spinnerBatch) then return end
  local i = (math.floor(animFrame / 20) % 8) + 1
  local x, y = -math.floor(camX), -math.floor(camY)
  if waterBatch then
    waterBatch:setTexture(self.waterVariants[WATER_OFFSETS[i] + 1])
    love.graphics.draw(waterBatch, x, y)
  end
  if flowerBatch then
    flowerBatch:setTexture(self.flowerFrames[FLOWER_FRAMES[i]])
    love.graphics.draw(flowerBatch, x, y)
  end
  -- spinner arrow tiles (engine/overworld/spinners.asm): only 2 frames
  -- (blur / restore-to-static), gated on spinBlurActive() rather than the
  -- free-running water/flower cycle above -- when false, draw nothing so
  -- the already-static mapBatch/ringBatch tile shows through unchanged
  if spinnerBatch and TileRenderer.spinBlurActive() then
    love.graphics.draw(spinnerBatch, x, y)
  end
end

function TileRenderer:draw(camX, camY)
  love.graphics.draw(self.ringBatch, -math.floor(camX), -math.floor(camY))
  love.graphics.draw(self.mapBatch, -math.floor(camX), -math.floor(camY))
  self:drawAnimated(camX, camY)
end

-- body only, for connected-map strips
function TileRenderer:drawMapOnly(camX, camY)
  love.graphics.draw(self.mapBatch, -math.floor(camX), -math.floor(camY))
  self:drawAnimated(camX, camY, true)
end

-- rebuild after a block change (Cut trees)
function TileRenderer:rebuild()
  local fresh = TileRenderer.new(self.map)
  self.ringBatch = fresh.ringBatch
  self.mapBatch = fresh.mapBatch
  self.waterBatch = fresh.waterBatch
  self.waterBodyBatch = fresh.waterBodyBatch
  self.waterVariants = fresh.waterVariants
  self.flowerBatch = fresh.flowerBatch
  self.flowerBodyBatch = fresh.flowerBodyBatch
  self.flowerFrames = fresh.flowerFrames
  self.spinnerBatch = fresh.spinnerBatch
  self.spinnerBodyBatch = fresh.spinnerBodyBatch
  self.spinnerBlurImage = fresh.spinnerBlurImage
  self.borderFill = fresh.borderFill
end

return TileRenderer
