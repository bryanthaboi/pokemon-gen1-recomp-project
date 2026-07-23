-- Draws a map's tile layer: one texture atlas per tileset, 8x8 quads,
-- a single static SpriteBatch covering the map plus a border-block ring
-- (the ring plays the role of the GB border blocks around small maps).

local Assets = require("src.render.Assets")
local PaletteFX = require("src.render.PaletteFX")

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
    imageCache[path] = Assets.image(path)
  end
  return imageCache[path]
end

-- ------------------------------------------------------------------
-- Tile animation (home/vcopy.asm): tilesets with TILEANIM_WATER[_FLOWER]
-- rotate water tile $14 one pixel every 20 frames (4 steps right, 4
-- left) and cycle flower tile $03 through 3 frames.
-- Those two cycles are the *defaults* a vanilla tileset record derives
-- from its `animation` string; a tileset that carries `animatedTiles`
-- declares its own set instead and animates with no engine change.
-- ------------------------------------------------------------------

local WATER_TILE, FLOWER_TILE = 0x14, 0x03
-- cumulative pixel offset per animation step (the rrca/rlca sequence)
local WATER_OFFSETS = { 1, 2, 3, 2, 1, 0, 7, 0 }
-- flower frame per step (wMovingBGTilesCounter2 & 3: <2 -> 1, 2, 3)
local FLOWER_FRAMES = { 1, 2, 3, 1, 1, 2, 3, 1 }
local ANIM_PERIOD = 20
local FLOWER_IMAGES = {
  "assets/generated/tilesets/flower1.png",
  "assets/generated/tilesets/flower2.png",
  "assets/generated/tilesets/flower3.png",
}
local SPINNER_STRIP = "assets/generated/tilesets/spinners.png"

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

-- ------------------------------------------------------------------
-- animatedTiles: the per-kind resource builders.  Each returns the
-- texture list a step indexes into, or false when the pixels are
-- unreachable (headless, or a missing frame file) -- false disables that
-- one entry and leaves the static batch showing through, which is what
-- the water/flower branches did before they were data.
-- ------------------------------------------------------------------

-- shade 0-3 -> one of `colors`' 4 entries (same cutoffs PaletteFX's shader
-- uses), alpha passed through unchanged; nil colors leaves r,g,b as-is.
-- Shared by the whole-atlas bake (getGbcAtlas) and the animated-tile
-- variants below, so water/flowers/spinners match the static tiles around
-- them under RED++ instead of showing their un-recolored grayscale.
local function recolorSample(r, g, b, a, colors)
  if not (colors and a > 0) then return r, g, b, a end
  local col = r > 0.83 and colors[1] or r > 0.5 and colors[2]
              or r > 0.17 and colors[3] or colors[4]
  return col[1] / 255, col[2] / 255, col[3] / 255, a
end

-- the 8 shifted variants of one tile (built once per sheet + tile id [+
-- gbcKey, when `colors` recolors it for RED++ -- see buildAnim])
local shiftVariants = {}
local function getShiftVariants(tilesetImagePath, perRow, tile, colors, gbcKey)
  local key = tilesetImagePath .. "#" .. tile .. (gbcKey or "")
  if shiftVariants[key] ~= nil then return shiftVariants[key] end
  if not (love.image and love.image.newImageData) then
    shiftVariants[key] = false
    return false
  end
  local id = Assets.imageData(tilesetImagePath)
  local sx = (tile % perRow) * 8
  local sy = math.floor(tile / perRow) * 8
  local out = {}
  for o = 0, 7 do
    local v = love.image.newImageData(8, 8)
    for y = 0, 7 do
      for x = 0, 7 do
        local r, g, b, a = id:getPixel(sx + x, sy + y)
        r, g, b, a = recolorSample(r, g, b, a, colors)
        v:setPixel((x + o) % 8, y, r, g, b, a)
      end
    end
    out[o + 1] = love.graphics.newImage(v)
  end
  shiftVariants[key] = out
  return out
end

local frameImages = {}
local function getFrameImages(paths, colors, gbcKey)
  local key = table.concat(paths, "|") .. (gbcKey or "")
  if frameImages[key] ~= nil then return frameImages[key] end
  local out = {}
  for i, path in ipairs(paths) do
    local ok, img = pcall(function()
      if not (colors and love.image and love.image.newImageData) then
        return getImage(path)
      end
      local id = Assets.imageData(path)
      local w, h = id:getDimensions()
      local out2 = love.image.newImageData(w, h)
      for y = 0, h - 1 do
        for x = 0, w - 1 do
          local r, g, b, a = id:getPixel(x, y)
          r, g, b, a = recolorSample(r, g, b, a, colors)
          out2:setPixel(x, y, r, g, b, a)
        end
      end
      return love.graphics.newImage(out2)
    end)
    if not ok then
      frameImages[key] = false
      return false
    end
    out[i] = img
  end
  frameImages[key] = out
  return out
end

-- the tileset's own atlas ImageData with the patched tile slots blitted
-- over with a shared strip (vanilla: assets/generated/tilesets/spinners.png,
-- extracted from gfx/overworld/spinners.png); cached per tileset + strip
local toggleImages = {}
local stripData = {}
local function getToggleImage(spec, tilesetImagePath, perRow)
  local key = tilesetImagePath .. "#" .. tostring(spec.image)
  if toggleImages[key] ~= nil then return toggleImages[key] end
  local offsets = spec.stripOffsets
  if not (love.image and love.image.newImageData) or not offsets then
    toggleImages[key] = false
    return false
  end
  if stripData[spec.image] == nil then
    local ok, id = pcall(Assets.imageData, spec.image)
    stripData[spec.image] = ok and id or false
  end
  local strip = stripData[spec.image]
  if not strip then
    toggleImages[key] = false
    return false
  end
  local atlas = Assets.imageData(tilesetImagePath)
  local clone = love.image.newImageData(atlas:getWidth(), atlas:getHeight())
  clone:paste(atlas, 0, 0, 0, 0, atlas:getWidth(), atlas:getHeight())
  for id, offset in pairs(offsets) do
    local sx = offset * 8
    local dx = (id % perRow) * 8
    local dy = math.floor(id / perRow) * 8
    for y = 0, 7 do
      for x = 0, 7 do
        local r, g, b, a = strip:getPixel(sx + x, y)
        clone:setPixel(dx + x, dy + y, r, g, b, a)
      end
    end
  end
  local img = love.graphics.newImage(clone)
  toggleImages[key] = img
  return img
end

-- a toggle entry names the predicate that decides whether its patch shows
-- this frame; an unknown name (or none) is always on
TileRenderer.GATES = {
  spinning = function() return TileRenderer.spinBlurActive() end,
}

function TileRenderer.registerGate(name, predicate)
  TileRenderer.GATES[name] = predicate
end

local function gateOpen(name)
  local predicate = TileRenderer.GATES[name]
  if not predicate then return true end
  return predicate() and true or false
end

-- The vanilla animation set as data: what the importer would write onto a
-- tileset record derived from its `animation` string and its spinner-tile
-- row.  Consulted only when the record declares no animatedTiles of its
-- own, so the vanilla frame is byte-for-byte what it always was.
function TileRenderer.defaultAnimatedTiles(tileset)
  local out = {}
  local anim = tileset.animation
  if anim == "TILEANIM_WATER" or anim == "TILEANIM_WATER_FLOWER" then
    out[#out + 1] = { tile = WATER_TILE, kind = "hshift",
                      period = ANIM_PERIOD, offsets = WATER_OFFSETS }
  end
  if anim == "TILEANIM_WATER_FLOWER" then
    out[#out + 1] = { tile = FLOWER_TILE, kind = "frames",
                      period = ANIM_PERIOD, images = FLOWER_IMAGES,
                      sequence = FLOWER_FRAMES }
  end
  local spinners = TileRenderer.SPINNER_ARROW_TILES[tileset.id]
  if spinners then
    out[#out + 1] = { tiles = spinners, kind = "toggle", image = SPINNER_STRIP,
                      stripOffsets = SPINNER_STRIP_OFFSET[tileset.id],
                      gate = "spinning" }
  end
  return out
end

-- one entry's runtime form: the tile ids it claims, the textures a step
-- picks from, and either a step sequence (hshift/frames) or a gate
-- (toggle).  nil when the entry's pixels could not be built.
--
-- gbc, when present (RED++ with a baked atlas -- see getGbcAtlas), recolors
-- hshift/frames entries (water/flowers) the same way the atlas bakes their
-- static tile, so they match their surroundings instead of showing raw
-- grayscale over an otherwise fully-colored map. The "toggle" kind
-- (spinner puzzle blur, gfx/overworld/spinners.png) is a whole-atlas clone
-- built from the ORIGINAL grayscale atlas, not worth recoloring for a rare,
-- gameplay-gated blur -- it is skipped under gbc, same as the buildAnim
-- caller already does for a texture-build failure (the static, correctly-
-- colored tile shows through unanimated).
local function buildAnim(spec, tilesetImagePath, perRow, quads, gbc)
  local tiles = spec.tiles
  if not tiles then
    if spec.tile == nil then return nil end
    tiles = { spec.tile }
  end
  local period = spec.period or ANIM_PERIOD
  local colors
  if gbc then
    local group = PaletteFX.worldGroupAt(gbc.tilesetId, gbc.mapId, tiles[1])
    colors = group and gbc.groupColors[group + 1]
  end
  if spec.kind == "hshift" then
    local offsets = spec.offsets
    if not offsets or #offsets == 0 then return nil end
    local textures = getShiftVariants(tilesetImagePath, perRow, tiles[1],
                                      colors, gbc and gbc.key)
    if not textures then return nil end
    local sequence = {}
    for i, offset in ipairs(offsets) do sequence[i] = offset + 1 end
    return { tiles = tiles, textures = textures, sequence = sequence,
             period = period }
  elseif spec.kind == "frames" then
    local sequence = spec.sequence
    if not (spec.images and sequence and #sequence > 0) then return nil end
    local textures = getFrameImages(spec.images, colors, gbc and gbc.key)
    if not textures then return nil end
    return { tiles = tiles, textures = textures, sequence = sequence,
             period = period }
  elseif spec.kind == "toggle" then
    if gbc then return nil end
    local image = getToggleImage(spec, tilesetImagePath, perRow)
    if not image then return nil end
    -- the patch texture is a whole-atlas clone, so each cell needs the
    -- quad of the tile it stands in rather than a single-tile image
    return { tiles = tiles, textures = { image }, gate = spec.gate,
             quadFor = function(tile) return quads[tile] end }
  end
  return nil
end

-- True GBC overworld coloring (COLORS=RED++): recolor the WHOLE tileset
-- atlas once, per (tileset image, map), rather than trying to retrofit the
-- SGB zone/shade-remap-shader post-process (built for a handful of coarse
-- screen regions) into per-tile precision -- pokered-gbc's real model is
-- "one of 8 four-color BG palettes baked per tile GRAPHIC"
-- (color/loadpalettes.asm LoadTilesetPalette), which is exactly a
-- recolored atlas, not a shader pass. Every existing draw path (batches,
-- quads, border fill) then just works unmodified, with no shader at
-- draw time; OverworldState.sgbWorldZones skips the shade-remap zone pass
-- entirely when this is active (re-running it over already-true-color
-- pixels would corrupt them), and SpriteRenderer's own OBP bake composites
-- on top with ordinary alpha blending -- no trueColor exemption needed,
-- because there is no shader left for it to be exempted from.
--
-- Only the ROOF group (index 6, OVERWORLD/PLATEAU only) varies by town
-- (LoadTownPalette); Route 6's mid-map Saffron-roof y<2 split is not
-- reproduced (it would need a rebuild on crossing the boundary for two
-- tile-rows of one route -- not worth the complexity), so it bakes with
-- the route's own default roof (Vermilion's) throughout.
local gbcAtlasCache = {}

local function getGbcAtlas(imagePath, tilesetId, mapId, perRow, data)
  local key = imagePath .. "#gbc:" .. mapId
  if gbcAtlasCache[key] ~= nil then return gbcAtlasCache[key] or nil end
  local img = false
  if love.image and love.image.newImageData then
    local groupColors = PaletteFX.worldGroupColors(data, tilesetId, mapId, nil)
    if groupColors then
      local src = Assets.imageData(imagePath)
      local iw, ih = src:getDimensions()
      local total = (iw / 8) * (ih / 8)
      local out = love.image.newImageData(iw, ih)
      local tileColors = {}
      for t = 0, total - 1 do
        local colors = tileColors[t]
        if colors == nil then
          local group = PaletteFX.worldGroupAt(tilesetId, mapId, t)
          colors = (group and groupColors[group + 1]) or false
          tileColors[t] = colors
        end
        local ox, oy = (t % perRow) * 8, math.floor(t / perRow) * 8
        for py = 0, 7 do
          for px = 0, 7 do
            local sx, sy = ox + px, oy + py
            local r, g, b, a = src:getPixel(sx, sy)
            r, g, b, a = recolorSample(r, g, b, a, colors)
            out:setPixel(sx, sy, r, g, b, a)
          end
        end
      end
      -- duplicate-tile aliases: bake a copy of a shared tile graphic into
      -- a spare slot under a different palette group, so block cells that
      -- draw the alias can color apart from cells sharing the raw tile
      for _, al in ipairs(PaletteFX.TILE_ALIASES and PaletteFX.TILE_ALIASES[mapId] or {}) do
        if al.alias < total then
          local colors = groupColors[al.group + 1]
          local sxo = (al.tile % perRow) * 8
          local syo = math.floor(al.tile / perRow) * 8
          local dxo = (al.alias % perRow) * 8
          local dyo = math.floor(al.alias / perRow) * 8
          for py = 0, 7 do
            for px = 0, 7 do
              local r, g, b, a = src:getPixel(sxo + px, syo + py)
              r, g, b, a = recolorSample(r, g, b, a, colors)
              out:setPixel(dxo + px, dyo + py, r, g, b, a)
            end
          end
        end
      end
      img = love.graphics.newImage(out)
    end
  end
  gbcAtlasCache[key] = img
  return img or nil
end

-- data: Game.data (threaded through explicitly, not required lazily, so
-- headless tests that build a map from a plain local table still work)
function TileRenderer.new(map, data)
  local self = setmetatable({}, TileRenderer)
  self.map = map
  self.data = data
  self.image = getImage(map.tileset.image)
  local gbcCtx
  if data and PaletteFX.usesGbcPack() and PaletteFX.hasWorldTileset(map.tileset.id) then
    local gbc = getGbcAtlas(map.tileset.image, map.tileset.id, map.id,
                            map.tileset.tilesPerRow, data)
    if gbc then
      self.image = gbc
      self.gbcAtlas = true
      -- also recolors the animated water/flower entries below, so they
      -- match the atlas's static tiles instead of showing raw grayscale
      gbcCtx = { tilesetId = map.tileset.id, mapId = map.id, key = "#gbc:" .. map.id,
                groupColors = PaletteFX.worldGroupColors(data, map.tileset.id, map.id, nil) }
    end
  end
  -- a full-color atlas colors everything it paints, ring and border fill
  -- included, so every draw entry point claims its rect out of the pass
  self.trueColor = map.tileset.trueColor or nil

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
  -- animated tiles overdraw the static batches each frame.  Entry order
  -- decides which one claims a tile listed twice, so the vanilla defaults
  -- keep the old water-then-flower-then-spinner precedence.
  local anims, claimedBy = {}, {}
  local declared = map.tileset.animatedTiles
                   or TileRenderer.defaultAnimatedTiles(map.tileset)
  for _, spec in ipairs(declared) do
    local anim = buildAnim(spec, map.tileset.image, perRow, self.quads, gbcCtx)
    if anim then
      anim.cells = {}
      anims[#anims + 1] = anim
      for _, tile in ipairs(anim.tiles) do
        if claimedBy[tile] == nil then claimedBy[tile] = anim end
      end
    end
  end

  -- duplicate-tile alias remap (RED++ atlas only): [blockId][0-based cell]
  -- -> alias tile id (see PaletteFX.TILE_ALIASES / getGbcAtlas's bake)
  local aliasMap
  if gbcCtx then
    for _, al in ipairs(PaletteFX.TILE_ALIASES and PaletteFX.TILE_ALIASES[map.id] or {}) do
      aliasMap = aliasMap or {}
      local cells = aliasMap[al.block] or {}
      for ci in pairs(al.cells) do cells[ci] = al.alias end
      aliasMap[al.block] = cells
    end
  end

  for by = -BORDER_BLOCKS, hB + BORDER_BLOCKS - 1 do
    for bx = -BORDER_BLOCKS, wB + BORDER_BLOCKS - 1 do
      local inside = bx >= 0 and by >= 0 and bx < wB and by < hB
      local batch = inside and self.mapBatch or self.ringBatch
      -- beyond-edge ring cells use the same override drawBorderFill does,
      -- so the ring and the far background fill agree (OVERWORLD maps
      -- whose raw border_block is water still ring with the tree wall)
      local blockId = inside and map:blockAt(bx, by) or borderBlockFor(map)
      local block = map.tileset.blocks[blockId + 1]
      if not block then
        -- a tileset without the tree-wall block keeps its own border
        blockId = map:blockAt(bx, by)
        block = map.tileset.blocks[blockId + 1]
      end
      local remap = aliasMap and aliasMap[blockId]
      for ty = 0, 3 do
        for tx = 0, 3 do
          local ci = ty * 4 + tx
          local tile = block[ci + 1]
          if remap and remap[ci] then tile = remap[ci] end
          local quad = self.quads[tile]
          if quad then
            batch:add(quad, bx * 32 + tx * 8, by * 32 + ty * 8)
          end
          local anim = claimedBy[tile]
          if anim then
            local cells = anim.cells
            cells[#cells + 1] = { bx * 32 + tx * 8, by * 32 + ty * 8, inside, tile }
          end
        end
      end
    end
  end

  -- animated overdraw batches: the full set (ring + body) for the
  -- current map, and a body-only set for connected-map drawing --
  -- a neighbor's water ring must never overdraw this map's tiles.
  -- `quadFor`, when given, looks up a per-entry quad (used by toggle
  -- entries, whose texture is a full tileset-atlas clone rather than a
  -- single-tile image like the hshift/frames variants).
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
  for _, anim in ipairs(anims) do
    anim.batch, anim.bodyBatch =
      animBatches(anim.cells, anim.textures[1], anim.quadFor)
    anim.cells = nil
  end
  self.anims = anims

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
  if self.trueColor then PaletteFX.markTrueColor(0, 0, vw, vh) end
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

-- queue the same bottom tile row for the post-zone sprite-redraw pass
-- (GBC mode: OBP-baked sprites replay after the zone shader, so the
-- grass patch that hides their feet must replay over them, colorized
-- with the map's palette and color-0 keyed)
function TileRenderer:markCellBottomRedraw(cx, cy, camX, camY, colors)
  local ty = cy * 2 + 1
  for i = 0, 1 do
    local tx = cx * 2 + i
    local quad = self.quads[self.map:tileAt(tx, ty)]
    if quad then
      PaletteFX.markSpriteRedraw(self.image, quad, tx * 8 - math.floor(camX),
                                 ty * 8 - math.floor(camY), 1, colors, true)
    end
  end
end

-- animated overdraw at the current step; bodyOnly skips the ring
-- positions (connected maps draw body-only)
function TileRenderer:drawAnimated(camX, camY, bodyOnly)
  local anims = self.anims
  if not anims then return end
  local x, y = -math.floor(camX), -math.floor(camY)
  for _, anim in ipairs(anims) do
    local batch = bodyOnly and anim.bodyBatch or anim.batch
    if batch then
      if anim.gate then
        -- a gated entry has only the two frames the asm has (patch /
        -- restore-to-static); when the gate is shut draw nothing so the
        -- already-static mapBatch/ringBatch tile shows through unchanged
        if gateOpen(anim.gate) then love.graphics.draw(batch, x, y) end
      else
        local step = math.floor(animFrame / anim.period) % #anim.sequence + 1
        batch:setTexture(anim.textures[anim.sequence[step]])
        love.graphics.draw(batch, x, y)
      end
    end
  end
end

-- the drawn extent of one batch in world-canvas pixels; `blocks` is the
-- ring width the batch reaches past the map body on every side
function TileRenderer:markTrueColor(camX, camY, blocks)
  local def = self.map.def
  PaletteFX.markTrueColor(-math.floor(camX) - blocks * 32,
                          -math.floor(camY) - blocks * 32,
                          (def.width + 2 * blocks) * 32,
                          (def.height + 2 * blocks) * 32)
end

function TileRenderer:draw(camX, camY)
  if self.trueColor then self:markTrueColor(camX, camY, BORDER_BLOCKS) end
  love.graphics.draw(self.ringBatch, -math.floor(camX), -math.floor(camY))
  love.graphics.draw(self.mapBatch, -math.floor(camX), -math.floor(camY))
  self:drawAnimated(camX, camY)
end

-- body only, for connected-map strips
function TileRenderer:drawMapOnly(camX, camY)
  if self.trueColor then self:markTrueColor(camX, camY, 0) end
  love.graphics.draw(self.mapBatch, -math.floor(camX), -math.floor(camY))
  self:drawAnimated(camX, camY, true)
end

-- rebuild after a block change (Cut trees)
function TileRenderer:rebuild()
  local fresh = TileRenderer.new(self.map, self.data)
  self.image = fresh.image
  self.gbcAtlas = fresh.gbcAtlas
  self.quads = fresh.quads
  self.ringBatch = fresh.ringBatch
  self.mapBatch = fresh.mapBatch
  self.anims = fresh.anims
  self.borderFill = fresh.borderFill
end

-- drop every atlas and every derived animation texture so the next
-- TileRenderer.new re-resolves through the asset search path.  Live
-- instances keep the batches they already built; MapLoader.invalidateAll
-- is what drops those (14 §cache-invalidation contract).
function TileRenderer.invalidate()
  imageCache = {}
  shiftVariants = {}
  frameImages = {}
  toggleImages = {}
  stripData = {}
end

Assets.register(TileRenderer.invalidate)

return TileRenderer
