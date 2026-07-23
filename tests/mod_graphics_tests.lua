-- Graphics and assets (M10): the asset search path and its central cache,
-- the invalidate() contract every image cache now exposes, animated tiles
-- as tileset data, the trueColor opt-out on battle pics and palette zones,
-- the font page / charmap consumption, the transitions registry plus the
-- transition.style hook, and the asset-transform sandbox.
package.path = "./?.lua;./?/init.lua;" .. package.path

local S = require("tests.harness").suite("mod graphics")
local check = S.check

-- ------- love stubs
-- Pixel-level image data (the base stub has no love.image at all) plus a
-- graphics recorder, so the zone blit and the battle pic quantize can be
-- asserted on rather than assumed.

local love = _G.love or require("tests.love_stub")
_G.love = love

local savedGraphics, savedImage = love.graphics, love.image
-- the in-memory stub filesystem and the mod buses are shared with every
-- other suite in the run, so everything this file touches is put back
local savedFiles = {}
local writtenFiles = {}
local function seedFile(path, content)
  if savedFiles[path] == nil then
    savedFiles[path] = love.filesystem.read(path) or false
    writtenFiles[#writtenFiles + 1] = path
  end
  love.filesystem.write(path, content)
end

local ImageData = {}
ImageData.__index = ImageData

local function newImageData(a, b)
  local self = setmetatable({ pixels = {} }, ImageData)
  if type(a) == "string" then
    self.path, self.w, self.h = a, 2, 2
    -- a pixel no 4-shade quantize would leave alone
    self:setPixel(0, 0, 0.4, 0.7, 0.9, 1)
    self:setPixel(1, 0, 1, 1, 1, 1)
    self:setPixel(0, 1, 0, 0, 0, 1)
    self:setPixel(1, 1, 0, 0, 0, 1)
  else
    self.w, self.h = a, b
    for y = 0, self.h - 1 do
      for x = 0, self.w - 1 do self:setPixel(x, y, 0, 0, 0, 0) end
    end
  end
  return self
end

function ImageData:getDimensions() return self.w, self.h end
function ImageData:getWidth() return self.w end
function ImageData:getHeight() return self.h end
function ImageData:setPixel(x, y, r, g, b, a)
  self.pixels[y * self.w + x] = { r, g, b, a }
end
function ImageData:getPixel(x, y)
  local p = self.pixels[y * self.w + x] or { 0, 0, 0, 0 }
  return p[1], p[2], p[3], p[4]
end
function ImageData:mapPixel(fn)
  for y = 0, self.h - 1 do
    for x = 0, self.w - 1 do
      self:setPixel(x, y, fn(x, y, self:getPixel(x, y)))
    end
  end
end
function ImageData:paste(source, dx, dy, sx, sy, w, h)
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      self:setPixel(dx + x, dy + y, source:getPixel(sx + x, sy + y))
    end
  end
end
function ImageData:encode() return "png-bytes" end

local Image = {}
Image.__index = Image
function Image:getDimensions() return self.w, self.h end
function Image:getWidth() return self.w end
function Image:getHeight() return self.h end

-- what the recorder collects between resets
local log = { shader = {}, draws = {} }
local function resetLog()
  log.shader, log.draws = {}, {}
end

local Shader = {}
Shader.__index = Shader
function Shader:send(name, value) self.sent[name] = value end

local function noop() end

love.image = { newImageData = newImageData }

love.graphics = {
  newImage = function(what)
    if type(what) == "table" then
      return setmetatable({ w = what.w, h = what.h, data = what }, Image)
    end
    return setmetatable({ w = 128, h = 128, path = what }, Image)
  end,
  newQuad = function(x, y, w, h) return { x = x, y = y, w = w, h = h } end,
  newCanvas = function(w, h)
    return setmetatable({ w = w, h = h, setFilter = noop,
                          getWidth = function(s) return s.w end,
                          getHeight = function(s) return s.h end }, Image)
  end,
  newShader = function() return setmetatable({ sent = {} }, Shader) end,
  newSpriteBatch = function(image, size)
    local batch = { image = image, sprites = {} }
    function batch:add(quad, x, y) table.insert(self.sprites, { quad, x, y }) end
    function batch:clear() self.sprites = {} end
    function batch:setTexture(tex) self.texture = tex end
    return batch
  end,
  setShader = function(shader)
    log.shader[#log.shader + 1] = shader or false
  end,
  draw = function(what)
    log.draws[#log.draws + 1] = { what = what, shader = log.shader[#log.shader] }
  end,
  rectangle = noop, setColor = noop, clear = noop, setCanvas = noop,
  setDefaultFilter = noop, print = noop, push = noop, pop = noop,
  translate = noop, scale = noop, rotate = noop, origin = noop,
  setScissor = noop, getColor = function() return 1, 1, 1, 1 end,
  getDimensions = function() return 640, 576 end,
}

-- Fresh copies of the modules that cache a compiled shader or a page set
-- at first use, so they see the recorder above -- and so the originals
-- every other suite holds never see it.  GBCFX is in the list because
-- Renderer:endFrame reaches it and parity_gbcfx asserts on its unset
-- shader cache.
-- The tile/sprite renderers join them because they report trueColor rects
-- to PaletteFX and resolve through Assets, and the loader because it holds
-- Assets as an upvalue: an earlier suite's copy of any of the three would
-- talk to the module instance this one just replaced.
local savedLoaded = {}
for _, name in ipairs({ "src.render.PaletteFX", "src.render.Renderer",
                        "src.render.Font", "src.render.Assets",
                        "src.render.GBCFX", "src.render.SpriteRenderer",
                        "src.render.TileRenderer", "src.mods.Loader" }) do
  savedLoaded[name] = package.loaded[name]
  package.loaded[name] = nil
end

local Assets = require("src.render.Assets")
local AssetTransform = require("src.mods.AssetTransform")
local BattleState = require("src.battle.BattleState")
local BattleTransition = require("src.render.BattleTransition")
local Events = require("src.mods.Events")
local Font = require("src.render.Font")
local Hooks = require("src.mods.Hooks")
local HudTiles = require("src.render.HudTiles")
local PaletteFX = require("src.render.PaletteFX")
local Registry = require("src.mods.Registry")
local Renderer = require("src.render.Renderer")
local Runtime = require("src.mods.Runtime")
local Schemas = require("src.mods.Schemas")
local SpriteRenderer = require("src.render.SpriteRenderer")
local TileRenderer = require("src.render.TileRenderer")
local Transition = require("src.render.Transition")

-- ------- asset resolution

check(Assets.loader == nil, "no loader installed by default")
check(Assets.resolve("assets/generated/tilesets/overworld.png")
      == "assets/generated/tilesets/overworld.png",
      "resolve is the identity with no loader (the no-op proof)")
check(Assets.resolve("mods/x/art.png") == "mods/x/art.png",
      "a non-generated path is never rewritten")

seedFile("mods/skin/overrides/tilesets/overworld.png", "png")
seedFile("save/mod-derived/skin/battle/back/redb.png", "png")

Assets.installLoader({
  loaded = { { manifest = { id = "skin" }, path = "mods/skin" } },
})

check(Assets.resolve("assets/generated/tilesets/overworld.png")
      == "mods/skin/overrides/tilesets/overworld.png",
      "an overrides/ file shadows the generated path with no record edit")
check(Assets.resolve("assets/generated/battle/back/redb.png")
      == "save/mod-derived/skin/battle/back/redb.png",
      "a transform's derived output resolves under the override dir")
check(Assets.resolve("assets/generated/fonts/font.png")
      == "assets/generated/fonts/font.png",
      "no override means the generated path, unchanged")

-- highest priority (last loaded) wins the lookup, like the record merge
seedFile("mods/hat/overrides/tilesets/overworld.png", "png")
Assets.installLoader({
  loaded = { { manifest = { id = "skin" }, path = "mods/skin" },
             { manifest = { id = "hat" }, path = "mods/hat" } },
})
check(Assets.resolve("assets/generated/tilesets/overworld.png")
      == "mods/hat/overrides/tilesets/overworld.png",
      "the later-loaded mod wins the asset search")

Assets.installLoader(nil)
check(Assets.resolve("assets/generated/tilesets/overworld.png")
      == "assets/generated/tilesets/overworld.png",
      "uninstalling the loader restores the vanilla path")

-- ------- the cache-invalidation contract

for name, module in pairs({ Assets = Assets, TileRenderer = TileRenderer,
    SpriteRenderer = SpriteRenderer, Font = Font, HudTiles = HudTiles,
    BattleState = BattleState }) do
  check(type(module.invalidate) == "function",
        name .. " exposes invalidate()")
end
check(type(require("src.world.MapLoader").invalidateAll) == "function",
      "MapLoader keeps its wave-1 invalidateAll")
check(type(require("src.core.Sound").invalidate) == "function",
      "Sound keeps its wave-1 invalidate")

-- the central cache hands back one image per resolved path, and flush
-- fans out to every registered downstream cache
local first = Assets.image("assets/generated/fonts/font.png")
check(Assets.image("assets/generated/fonts/font.png") == first,
      "the central cache returns the same image for a repeated path")
local fanout = 0
Assets.register(function() fanout = fanout + 1 end)
Assets.flush()
check(fanout == 1, "flush() fans out to registered invalidators")
check(Assets.image("assets/generated/fonts/font.png") ~= first,
      "flush() drops the central cache so the next load re-resolves")

-- an invalidator that throws must not strand the ones behind it
local reached = false
Assets.register(function() error("boom") end)
Assets.register(function() reached = true end)
Assets.flush()
check(reached, "a throwing invalidator does not stop the fan-out")

-- ------- animated tiles as tileset data

local overworld = TileRenderer.defaultAnimatedTiles(
  { id = "OVERWORLD", animation = "TILEANIM_WATER_FLOWER" })
check(#overworld == 2, "TILEANIM_WATER_FLOWER derives water + flower entries")
check(overworld[1].tile == 0x14 and overworld[1].kind == "hshift",
      "water is an hshift entry on tile $14")
check(table.concat(overworld[1].offsets, ",") == "1,2,3,2,1,0,7,0",
      "the water entry reproduces WATER_OFFSETS exactly")
check(overworld[1].period == 20, "water advances every 20 ticks")
check(overworld[2].tile == 0x03 and overworld[2].kind == "frames",
      "flower is a frames entry on tile $03")
check(table.concat(overworld[2].sequence, ",") == "1,2,3,1,1,2,3,1",
      "the flower entry reproduces FLOWER_FRAMES exactly")
check(#overworld[2].images == 3, "the flower entry names its 3 frame images")

local waterOnly = TileRenderer.defaultAnimatedTiles(
  { id = "PLATEAU", animation = "TILEANIM_WATER" })
check(#waterOnly == 1, "TILEANIM_WATER derives water alone")
local none = TileRenderer.defaultAnimatedTiles(
  { id = "HOUSE", animation = "TILEANIM_NONE" })
check(#none == 0, "a tileset with no animation derives nothing")

local gym = TileRenderer.defaultAnimatedTiles(
  { id = "GYM", animation = "TILEANIM_NONE" })
check(#gym == 1 and gym[1].kind == "toggle",
      "a spinner tileset derives its toggle entry")
check(gym[1].gate == "spinning", "the spinner toggle is gated on spinning")
check(gym[1].stripOffsets[0x3c] == 1 and gym[1].stripOffsets[0x4c] == 0,
      "the spinner toggle carries the asm's strip offsets")

-- a custom tileset declares its own animation and the engine consumes it
local customTiles = {}
for i = 1, 16 do customTiles[i] = 0x2f end
local map = {
  def = { width = 1, height = 1, tileset = "AQUA", borderBlock = 0 },
  tileset = { id = "AQUA", image = "assets/generated/tilesets/aqua.png",
              tilesPerRow = 16, blocks = { customTiles },
              animatedTiles = {
                { tile = 0x2f, kind = "frames", period = 12,
                  sequence = { 1, 2, 3, 2 },
                  images = { "mods/aqua/w1.png", "mods/aqua/w2.png",
                             "mods/aqua/w3.png" } },
              } },
  blockAt = function() return 0 end,
}
local renderer = TileRenderer.new(map)
check(#renderer.anims == 1, "a declared animatedTiles entry builds one anim")
check(renderer.anims[1].period == 12, "the declared period is honored")
check(#renderer.anims[1].textures == 3, "the declared frame images load")
-- the camera-window fill gathers the on-screen animated cells into anims[].batch
renderer:draw(0, 0)
check(renderer.anims[1].batch ~= nil, "the animated tile collected cells")

-- the vanilla water cycle, driven through the same data path: eight
-- shifted variants stepped every 20 ticks in WATER_OFFSETS order.  The
-- suite before this one built OVERWORLD under a stub with no love.image
-- and cached the miss, so this doubles as proof that invalidate() lets a
-- cache repopulate from a changed search path.
TileRenderer.invalidate()
local waterTiles = {}
for i = 1, 16 do waterTiles[i] = 0x14 end
local sea = TileRenderer.new({
  def = { width = 1, height = 1, tileset = "OVERWORLD", borderBlock = 0 },
  tileset = { id = "OVERWORLD", image = "assets/generated/tilesets/overworld.png",
              tilesPerRow = 16, blocks = { waterTiles },
              animation = "TILEANIM_WATER" },
  blockAt = function() return 0 end,
})
check(#sea.anims == 1, "an OVERWORLD tileset animates its water with no record edit")
check(#sea.anims[1].textures == 8, "the water entry builds 8 shifted variants")

-- fill the camera window so the water cells are gathered into the batch
sea:draw(0, 0)
local seen = {}
for step = 1, 8 do
  sea:drawAnimated(0, 0)
  local texture = sea.anims[1].batch.texture
  for i, candidate in ipairs(sea.anims[1].textures) do
    if candidate == texture then seen[step] = i end
  end
  for _ = 1, 20 do TileRenderer.tick() end
end
-- WATER_OFFSETS + 1, as texture indices; the phase depends on how many
-- ticks the process has run, so any rotation of it is the right cycle
local want = { 2, 3, 4, 3, 2, 1, 8, 1 }
local rotated = false
for offset = 0, 7 do
  local match = true
  for i = 1, 8 do
    if seen[i] ~= want[(i - 1 + offset) % 8 + 1] then match = false break end
  end
  if match then rotated = true break end
end
check(rotated, "the water cycle steps through WATER_OFFSETS in order")

-- a gate name nothing registered is always on; a registered one decides
TileRenderer.registerGate("test_gate", function() return false end)
check(TileRenderer.GATES.test_gate() == false, "a gate predicate is registered")
check(TileRenderer.GATES.spinning() == false,
      "the spinning gate is shut while nothing is spinning")

-- ------- trueColor: the battle pic quantize opt-out

BattleState.invalidate()
local monPalette = { { 255, 0, 0 }, { 0, 255, 0 }, { 0, 0, 255 }, { 0, 0, 0 } }
local picData = {
  pokemon = {
    SHADED = { spriteFront = "assets/generated/battle/front/shaded.png",
               spriteBack = "assets/generated/battle/back/shaded.png" },
    FULLCOLOR = { spriteFront = "assets/generated/battle/front/full.png",
                  spriteBack = "assets/generated/battle/back/full.png",
                  trueColor = true },
  },
  palettes = { palettes = { GRAYMON = monPalette }, pokemon = {} },
}
local battle = setmetatable({ data = picData }, BattleState)

local shaded = battle:speciesSprite("SHADED", false)
local r, g, b = shaded.data:getPixel(0, 0)
-- r = 0.4 lands in shade bucket 2 (> 0.17), the palette's third color
check(r == 0 and g == 0 and b == 1,
      "a 4-shade pic is palette-quantized onto its shade bucket")

local full = battle:speciesSprite("FULLCOLOR", false)
r, g, b = full.data:getPixel(0, 0)
check(math.abs(r - 0.4) < 1e-6 and math.abs(g - 0.7) < 1e-6
      and math.abs(b - 0.9) < 1e-6,
      "a trueColor pic keeps a pixel no 4-shade palette contains")

-- ------- trueColor: the colors == false zone sentinel

check(PaletteFX.zone(nil, 0, 0, 1, 1) == nil, "nil colors is still no zone")
local bare = PaletteFX.trueColorZone(0, 0, 19, 17)
check(bare ~= nil and bare.colors == false,
      "colors == false survives as a real zone")
check(bare.w == 160 and bare.h == 144, "the trueColor zone covers the screen")
check(PaletteFX.ensureZones({ bare })[1] == bare,
      "a trueColor-only zone list is left alone")

Renderer:init()
Renderer:beginFrame(false)
resetLog()
Renderer:endFrame({ PaletteFX.whole(PaletteFX.GRAYS) })
local shadedDraw = nil
for _, d in ipairs(log.draws) do
  if d.what and d.what.w == 160 then shadedDraw = d end
end
check(shadedDraw and shadedDraw.shader,
      "an ordinary zone blits through the shade-remap shader")

Renderer:beginFrame(false)
resetLog()
Renderer:endFrame({ bare })
local bareDraw = nil
for _, d in ipairs(log.draws) do
  if d.what and d.what.w == 160 then bareDraw = d end
end
check(bareDraw, "the trueColor zone still blits its rect")
check(bareDraw.shader == false,
      "a colors == false zone blits with no shader bound")

-- ------- trueColor: a record's rect reaching the frame's zone list
-- The state that returns the zone list knows nothing about which records
-- the frame drew, so the renderers report the rect a trueColor record
-- covered and endFrame splices it in.  Driven through the real draw path
-- rather than by handing endFrame a hand-built zone.

local GRAYS = PaletteFX.GRAYS
local function canvasDraws(canvas)
  local drawn = {}
  for _, d in ipairs(log.draws) do
    if d.what == canvas then drawn[#drawn + 1] = d end
  end
  return drawn
end

local function fullWorldZones()
  local vw, vh = Renderer:worldViewSize()
  return { { colors = GRAYS, x = 0, y = 0, w = vw, h = vh } }
end

-- the flag reaches the renderer on a real record, registered and merged
-- through the public API rather than hand-built here
local spriteReg = Registry.new("sprites", Schemas.REGISTRIES.sprites)
spriteReg:register("SPRITE_TITLE_LOGO",
                   { image = "mods/logo/logo.png", frames = 1,
                     trueColor = true }, "logo_mod")
local logoDef = spriteReg:get("SPRITE_TITLE_LOGO")
check(Schemas.check(Schemas.REGISTRIES.sprites, "sprites", "SPRITE_TITLE_LOGO",
                    logoDef, "register"),
      "a trueColor sprites record validates against the catalog schema")
check(logoDef.trueColor == true, "and keeps the flag through the merge")

Renderer:init()
local plainSprite = SpriteRenderer.new(
  { image = "assets/generated/sprites/red.png", frames = 1 })
local litSprite = SpriteRenderer.new(logoDef)

Renderer:beginFrame(true)
check(#PaletteFX.trueColorRects("ui") == 0
      and #PaletteFX.trueColorRects("world") == 0,
      "beginFrame drops the previous frame's rects")
Renderer:beginWorldPass()
plainSprite:draw(32, 32, 0, 0, "down", 0, false)
check(#PaletteFX.trueColorRects("world") == 0,
      "a vanilla sprite reports nothing, so the zone list is untouched")
Renderer:endWorldPass()
resetLog()
Renderer:endFrame({ PaletteFX.whole(GRAYS) }, fullWorldZones())
local worldDrawn = canvasDraws(Renderer.worldCanvas)
check(#worldDrawn == 1 and worldDrawn[1].shader,
      "the vanilla world pass blits its one zone through the shader")

Renderer:beginFrame(true)
Renderer:beginWorldPass()
litSprite:draw(32, 32, 0, 0, "down", 0, false)
local spriteRects = PaletteFX.trueColorRects("world")
check(#spriteRects == 1 and spriteRects[1].colors == false,
      "a trueColor sprite reports a colors == false zone")
check(spriteRects[1].x == 32 and spriteRects[1].y == 28
      and spriteRects[1].w == 16 and spriteRects[1].h == 16,
      "the zone covers the 16x16 cell the sprite drew into")
Renderer:endWorldPass()
resetLog()
Renderer:endFrame({ PaletteFX.whole(GRAYS) }, fullWorldZones())
worldDrawn = canvasDraws(Renderer.worldCanvas)
check(#worldDrawn == 2, "the reported zone joins the world list endFrame blits")
check(worldDrawn[1].shader and worldDrawn[2].shader == false,
      "the colorized pass runs first, then the sprite's rect with no shader")

-- the same path on the UI canvas, which is where a full-color title logo
-- or menu portrait lands
Renderer:beginFrame(false)
litSprite:draw(16, 16, 0, 0, "down", 0, false)
resetLog()
Renderer:endFrame({ PaletteFX.whole(GRAYS) })
local uiDrawn = canvasDraws(Renderer.canvas)
check(#uiDrawn == 2 and uiDrawn[2].shader == false,
      "a trueColor sprite renders unshaded on the UI pass too")

-- a pass with no zone list already blits the whole canvas bare, which is
-- what the rect wanted, so nothing is added
Renderer:beginFrame(true)
Renderer:beginWorldPass()
litSprite:draw(32, 32, 0, 0, "down", 0, false)
Renderer:endWorldPass()
resetLog()
Renderer:endFrame(nil, nil)
worldDrawn = canvasDraws(Renderer.worldCanvas)
check(#worldDrawn == 1 and not worldDrawn[1].shader,
      "an empty zone list is left alone (the whole canvas is already bare)")

-- tilt's upright canvas composites with no zone list of its own, so a
-- rect drawn there has nowhere to land
Renderer:beginFrame(true)
Renderer:beginWorldPass()
Renderer:beginUprightPass()
litSprite:draw(32, 32, 0, 0, "down", 0, false)
Renderer:endUprightPass()
check(#PaletteFX.trueColorRects("world") == 0,
      "the upright pass drops its rects instead of misplacing them")
Renderer:endWorldPass()
Renderer:endFrame({ PaletteFX.whole(GRAYS) }, fullWorldZones())

-- a trueColor tileset claims the extent it painted, ring and all
local litTiles = {}
for i = 1, 16 do litTiles[i] = 0x00 end
local tilesetReg = Registry.new("tilesets", Schemas.REGISTRIES.tilesets)
tilesetReg:register("AQUA",
                    { id = "AQUA", image = "assets/generated/tilesets/aqua.png",
                      tilesPerRow = 16, blocks = { litTiles },
                      animation = "TILEANIM_NONE", trueColor = true }, "aqua_mod")
local aquaDef = tilesetReg:get("AQUA")
check(Schemas.check(Schemas.REGISTRIES.tilesets, "tilesets", "AQUA",
                    aquaDef, "register"),
      "a trueColor tilesets record validates against the catalog schema")
local litMap = {
  def = { width = 2, height = 2, tileset = "AQUA", borderBlock = 0 },
  tileset = aquaDef,
  blockAt = function() return 0 end,
}
local litRenderer = TileRenderer.new(litMap)

Renderer:beginFrame(true)
Renderer:beginWorldPass()
litRenderer:draw(0, 0)
local tileRects = PaletteFX.trueColorRects("world")
check(#tileRects == 1 and tileRects[1].colors == false,
      "a trueColor tileset reports a colors == false zone")
check(tileRects[1].x == -96 and tileRects[1].y == -96
      and tileRects[1].w == 8 * 32 and tileRects[1].h == 8 * 32,
      "the zone covers the map body plus its 3-block border ring")
litRenderer:drawMapOnly(0, 0)
check(#tileRects == 2 and tileRects[2].w == 2 * 32,
      "a connected-map strip claims the body only")
Renderer:endWorldPass()
resetLog()
Renderer:endFrame({ PaletteFX.whole(GRAYS) }, fullWorldZones())
worldDrawn = canvasDraws(Renderer.worldCanvas)
check(#worldDrawn == 3 and worldDrawn[2].shader == false
      and worldDrawn[3].shader == false,
      "both tileset rects blit unshaded over the colorized pass")

litMap.tileset.trueColor = nil
Renderer:beginFrame(true)
Renderer:beginWorldPass()
TileRenderer.new(litMap):draw(0, 0)
check(#PaletteFX.trueColorRects("world") == 0,
      "the same tileset without the flag reports nothing")
Renderer:endWorldPass()
Renderer:endFrame({ PaletteFX.whole(GRAYS) }, fullWorldZones())

-- ------- font pages and charmap ordering

Font.load({
  font = {
    image = "assets/generated/fonts/font.png", mainBase = 0x80,
    imageExtra = "assets/generated/fonts/font_extra.png", extraBase = 0x60,
    glyphsPerRow = 16,
    -- deliberately shortest-first: load() must not trust this order
    charmap = { { code = 0x80, seq = "A" }, { code = 0x81, seq = "AB" } },
  },
})
check(Font.encode("AB")[1] == 0x81,
      "charmap buckets are sorted longest-first by load(), not the extractor")
check(#Font.encode("AB") == 1, "the longer sequence consumes both bytes")
check(Font.advanceOf(0x80) == 8, "a page with no advance stays 8px monospace")

-- a registered page joins the legacy two and takes its own code range
Font.load({
  font = {
    image = "assets/generated/fonts/font.png", mainBase = 0x80,
    imageExtra = "assets/generated/fonts/font_extra.png", extraBase = 0x60,
    glyphsPerRow = 16, charmap = {},
    border = { tl = 0x11 },
    pages = {
      kana = { image = "mods/jp/kana.png", base = 0x100, glyphsPerRow = 16,
               advance = 6, charmap = { { code = 0x100, seq = "\227\129\130" } } },
    },
  },
})
check(Font.encode("\227\129\130")[1] == 0x100,
      "a page's own charmap entries merge into the greedy matcher")
check(Font.advanceOf(0x100) == 6, "a page's advance drives the pen")
check(Font.advanceOf(0x80) == 8, "sibling pages keep their own advance")
check(Font.BORDER.tl == 0x11, "data.font.border rethemes the box glyphs")
check(Font.BORDER.br == Font.DEFAULT_BORDER.br,
      "an unthemed border glyph keeps its default")

resetLog()
check(Font.draw("\227\129\130", 0, 0) == 6,
      "draw() advances the pen by the page's own width")

-- ------- palettes registry consumption

local palData = { palettes = { palettes = { MODMON = monPalette },
                               pokemon = { TESTMON = "MODMON" } } }
check(PaletteFX.pal(palData, "MODMON") == monPalette,
      "PaletteFX.pal reads the merged palettes table")
check(PaletteFX.monPal(palData, "TESTMON") == monPalette,
      "a pokemon:<species> mapping steers monPal")
check(PaletteFX.monPal(palData, "UNKNOWN") == nil,
      "an unmapped species falls through to MEWMON (absent here)")

-- RED++ pack: per-species SuperPalettes from data/palettes_gbc.lua
local prevMode = PaletteFX.mode
PaletteFX.setMode("redpp")
check(PaletteFX.usesGbcPack(), "redpp mode selects the gbc pack")
local gbc = PaletteFX.gbcPack()
check(gbc ~= nil and gbc.palettes.BULBASAUR ~= nil,
      "data/palettes_gbc.lua ships per-species pals")
check(PaletteFX.monPalName({ palettes = nil }, "BULBASAUR") == "BULBASAUR",
      "RED++ monPalName resolves to the species palette id")
check(PaletteFX.monPal({ palettes = nil }, "BULBASAUR") == gbc.palettes.BULBASAUR,
      "RED++ monPal reads the species colors without a ROM pack")
check(PaletteFX.pal({ palettes = nil }, "ROUTE") == gbc.palettes.ROUTE,
      "RED++ still has ROUTE (aliased from VIRIDIAN)")
check(PaletteFX.effectiveColors(gbc.palettes.MEWMON) == gbc.palettes.MEWMON,
      "RED++ passes zone colors through like GBC")
PaletteFX.setMode(prevMode)

-- ------- the transitions registry

local transitions = Registry.new("transitions", Schemas.REGISTRIES.transitions)
BattleTransition.registerInto(transitions, nil, "engine")
for _, id in ipairs({ "doublecircle", "spiralin", "circle", "spiralout",
                      "hstripes", "shrink", "vstripes", "split" }) do
  check(transitions:get(id) ~= nil, "the engine registers wipe " .. id)
end
check(transitions:get("warp_fade").frames == 12,
      "the warp fade registers as a transitions record")
check(transitions:get("white_flash").frames == 7,
      "the white flash registers as a transitions record")

-- every registered record still validates against the catalog schema
for id, record in transitions:each() do
  local ok, err = Schemas.check(Schemas.REGISTRIES.transitions, "transitions",
                                id, record, "register")
  check(ok, ("transitions.%s validates (%s)"):format(id, tostring(err)))
end

-- the merged record retimes a fade without an engine change
local retimed = { transitions = { warp_fade = { kind = "fade", frames = 30 } } }
check(Transition.new({ data = retimed }).frames == 30,
      "a patched warp_fade record changes the fade length")
check(Transition.new({ data = { transitions = {} } }).frames == 12,
      "an unregistered id falls back to the built-in 12 frames")

-- issue #121: with the survey-zoom world pass active, the warp fade must
-- darken the full window composite (via Renderer.worldFadeAlpha), not just
-- paint a 160x144 rect on the UI letterbox.
do
  local rects = {}
  local color = { 1, 1, 1, 1 }
  local savedRect, savedColor = love.graphics.rectangle, love.graphics.setColor
  love.graphics.rectangle = function(mode, x, y, w, h)
    rects[#rects + 1] = {
      mode = mode, x = x, y = y, w = w, h = h,
      a = color[4], r = color[1],
    }
  end
  love.graphics.setColor = function(r, g, b, a)
    color[1], color[2], color[3], color[4] = r, g, b, a or 1
  end

  Renderer:init()
  local fade = Transition.new({ renderer = Renderer, stack = { pop = noop } })
  fade.t = 6 -- mid fade-out (12 frames)
  fade.phase = "out"

  Renderer:beginFrame(true)
  Renderer:beginWorldPass()
  Renderer:endWorldPass()
  check(Renderer.worldActive == true, "world pass stays marked active until endFrame")
  fade:draw()
  check(Renderer.worldFadeAlpha == 0.5,
        "warp fade hands mid-out alpha to the world composite overlay")
  check(#rects == 0,
        "warp fade does not paint the 160x144 UI letterbox while the world pass is up")

  resetLog()
  rects = {}
  Renderer:endFrame(nil, fullWorldZones())
  local fadeRect
  for _, r in ipairs(rects) do
    -- endFrame's letterbox clear is also a full-window black fill (a == 1);
    -- the warp overlay is the half-alpha one Transition requested
    if r.mode == "fill" and r.x == 0 and r.y == 0
       and r.w == 640 and r.h == 576 and r.r == 0 and r.a == 0.5 then
      fadeRect = r
    end
  end
  check(fadeRect ~= nil,
        "endFrame paints the warp fade over the full window at the fade alpha")
  check(Renderer.worldActive == false, "endFrame clears worldActive")

  -- without a world pass (opaque UI states), keep the classic UI rect
  Renderer:beginFrame(false)
  fade.t = 6
  fade.phase = "out"
  rects = {}
  fade:draw()
  check(Renderer.worldFadeAlpha == nil,
        "no world pass: warp fade does not set a world overlay")
  check(#rects == 1 and rects[1].w == 160 and rects[1].h == 144,
        "no world pass: warp fade still fills the 160x144 UI canvas")

  love.graphics.rectangle, love.graphics.setColor = savedRect, savedColor
end

-- ------- the transition.style hook

local stack = { pop = function() end }
local vanilla = BattleTransition.new({ stack = stack }, nil,
                                     { trainer = true, stronger = true })
check(vanilla.style == "spiralout",
      "the vanilla 3-bit select is the hook's default (trainer+stronger)")
check(vanilla.wipeLen == 40, "the selected wipe brings its own length")

local savedRuntime = { events = Runtime.events, hooks = Runtime.hooks,
                       errors = Runtime.errors }
local events, hooks = Events.new(), Hooks.new()
Runtime.install(events, hooks, {})
local seenCtx
hooks:wrap("transition.style", function(nextLink, ctx)
  seenCtx = ctx
  return "hstripes"
end, 0, "test")
local hooked = BattleTransition.new({ stack = stack }, nil, { trainer = true })
check(hooked.style == "hstripes", "a transition.style hook picks the wipe")
check(hooked.wipeLen == 24, "the hooked style brings its own length")
check(seenCtx.trainer == true and seenCtx.stronger == nil,
      "the hook receives the selection bits as context")

hooks:wrap("transition.style", function() return "no_such_style" end, 10, "test")
local fallback = BattleTransition.new({ stack = stack }, nil, {})
check(fallback.style == "doublecircle",
      "a hook naming an unregistered style falls back to the vanilla bits")
Runtime.install(Events.new(), Hooks.new(), {})

-- ------- asset transforms

local function seedTransform(id, source)
  seedFile("mods/" .. id .. "/transforms.lua", source)
  return { path = "mods/" .. id,
           manifest = { id = id, assets_transforms = "transforms.lua" } }
end

seedFile("assets/generated/battle/front/mew.png", "png")
seedFile("rom-cache.complete", "rom-cache-v5:abc")

local events2 = Events.new()
Runtime.install(events2, Hooks.new(), {})
local transformed
events2:on("assets.transformed", function(ev) transformed = ev end, 0, "test")

local recolorMod = seedTransform("recolor_mod", [[
return function(ctx)
  if not ctx.exists("battle/front/mew.png") then error("source root wrong") end
  local src = ctx.readImage("battle/front/mew.png")
  ctx.writeImage(ctx.recolor(src, { {40,80,200}, {70,120,230},
                                    {150,190,255}, {255,255,255} }),
                 "battle/front/mew.png")
end
]])
local ok, reason = AssetTransform.runFor(recolorMod, love.filesystem)
check(ok, "the recolor transform runs: " .. tostring(reason))
check(love.filesystem.read("save/mod-derived/recolor_mod/battle/front/mew.png")
      ~= nil, "the transform wrote under save/mod-derived/<id>/")
check(love.filesystem.read("save/mod-derived/recolor_mod/.stamp") ~= nil,
      "a stamp records that the recipe ran")
check(transformed and transformed.modId == "recolor_mod",
      "assets.transformed names the mod")
check(transformed.count == 1, "assets.transformed counts the files written")

-- the stamp gates the re-run: the output is not rebuilt until it changes
seedFile("save/mod-derived/recolor_mod/battle/front/mew.png", nil)
check(AssetTransform.runFor(recolorMod, love.filesystem),
      "a stamped transform reports current without re-running")
check(love.filesystem.read("save/mod-derived/recolor_mod/battle/front/mew.png")
      == nil, "the stamped run did no work")
check(AssetTransform.runFor(recolorMod, love.filesystem, true),
      "force re-runs a stamped transform")
check(love.filesystem.read("save/mod-derived/recolor_mod/battle/front/mew.png")
      ~= nil, "the forced run rebuilt the derived asset")

-- a changed cache marker invalidates the stamp
seedFile("rom-cache.complete", "rom-cache-v5:def")
seedFile("save/mod-derived/recolor_mod/battle/front/mew.png", nil)
check(AssetTransform.runFor(recolorMod, love.filesystem),
      "a re-imported cache re-runs the transform")
check(love.filesystem.read("save/mod-derived/recolor_mod/battle/front/mew.png")
      ~= nil, "the re-import rebuilt the derived asset")

-- write sandbox: nothing may climb out of save/mod-derived/<id>/
local escapee = seedTransform("escape_mod", [[
return function(ctx)
  ctx.writeImage(ctx.blank(1, 1), "../../assets/generated/tilesets/hack.png")
end
]])
ok, reason = AssetTransform.runFor(escapee, love.filesystem)
check(not ok, "a transform writing outside its derived root is rejected")
check(reason:find("root", 1, true), "the rejection names the root: " .. reason)
check(love.filesystem.read("assets/generated/tilesets/hack.png") == nil,
      "nothing was written outside the derived root")

-- read sandbox: the source root is the imported cache and nothing above it
local peeker = seedTransform("peek_mod", [[
return function(ctx) ctx.readImage("../../mods/peek_mod/transforms.lua") end
]])
ok = AssetTransform.runFor(peeker, love.filesystem)
check(not ok, "a transform reading outside assets/generated is rejected")

-- no require, no love, no io: the recipe runs in a bare sandbox
local breakout = seedTransform("breakout_mod", [[
return function(ctx) return require("src.core.Data") end
]])
ok = AssetTransform.runFor(breakout, love.filesystem)
check(not ok, "the sandbox has no require")

local loveReach = seedTransform("love_mod", [[
return function(ctx) return love.filesystem.write("pwned", "x") end
]])
ok = AssetTransform.runFor(loveReach, love.filesystem)
check(not ok, "the sandbox has no love")
check(love.filesystem.read("pwned") == nil, "the breakout wrote nothing")

-- a throwing recipe is isolated and attributed, never fatal
local thrower = seedTransform("throw_mod", [[
return function(ctx) error("recipe exploded") end
]])
ok, reason = AssetTransform.runFor(thrower, love.filesystem)
check(not ok, "a throwing transform is caught")
check(reason:find("recipe exploded", 1, true),
      "the failure carries the recipe's message")
check(love.filesystem.read("save/mod-derived/throw_mod/.stamp") == nil,
      "a failed transform leaves no stamp, so it retries next boot")

-- a recipe that is not a function(ctx) is a load error, not a crash
local shapeless = seedTransform("shape_mod", "return 42")
ok, reason = AssetTransform.runFor(shapeless, love.filesystem)
check(not ok, "a recipe that returns a non-function is rejected")

-- a mod with no assets_transforms is nothing to run
check(AssetTransform.runFor({ path = "mods/plain", manifest = { id = "plain" } },
                            love.filesystem),
      "a mod without a transform is trivially current")

-- the loader-level runner keeps a failing recipe off everything else
local errors = {}
local ran = AssetTransform.run({
  fs = love.filesystem, errors = errors,
  loaded = { thrower, seedTransform("good_mod", [[
    return function(ctx) ctx.writeImage(ctx.blank(1, 1), "out.png") end
  ]]) },
})
check(ran == 1, "the good recipe ran even though its neighbor failed")
check(#errors == 1 and errors[1]:find("throw_mod", 1, true),
      "the failure is attributed to its mod in the loader error feed")
check(love.filesystem.read("save/mod-derived/good_mod/out.png") ~= nil,
      "the good recipe's output landed")

-- the boot path itself runs the recipe: a mod that only declares a
-- transform still ends up with derived art on disk, resolvable through the
-- asset search path, without anyone calling the runner by hand
local Loader = require("src.mods.Loader")

local bootFiles = {
  ["rom-cache.complete"] = "rom-cache-v5:abc",
  ["assets/generated/battle/front/mew.png"] = "png",
  ["mods/boot_skin/manifest.json"] =
    '{"id":"boot_skin","name":"boot skin","version":"1.0.0","api":2,'
    .. '"entry":"main.lua","assets_transforms":"transforms.lua"}',
  ["mods/boot_skin/main.lua"] = "return function(mod) end",
  ["mods/boot_skin/transforms.lua"] = [[
return function(ctx)
  ctx.writeImage(ctx.recolor(ctx.readImage("battle/front/mew.png"),
                             { {40,80,200}, {70,120,230},
                               {150,190,255}, {255,255,255} }),
                 "battle/front/mew.png")
end
]],
}
local bootfs = {
  write = function(name, content) bootFiles[name] = content return true end,
  read = function(name) return bootFiles[name] end,
  getInfo = function(name)
    if bootFiles[name] then return { type = "file" } end
    local prefix = name .. "/"
    for key in pairs(bootFiles) do
      if key:sub(1, #prefix) == prefix then return { type = "directory" } end
    end
    return nil
  end,
  load = function(name)
    if not bootFiles[name] then return nil, "no file: " .. name end
    return load(bootFiles[name], name)
  end,
  getDirectoryItems = function(name)
    local seen, items = {}, {}
    local prefix = name .. "/"
    for key in pairs(bootFiles) do
      if key:sub(1, #prefix) == prefix then
        local child = key:sub(#prefix + 1):match("^[^/]+")
        if child and not seen[child] then
          seen[child] = true
          items[#items + 1] = child
        end
      end
    end
    table.sort(items)
    return items
  end,
}

-- the same boot is what hands the resolver the live mod set; seeded on the
-- love filesystem because that is where Assets.resolve stats for overrides
seedFile("mods/boot_skin/overrides/tilesets/overworld.png", "png")
Assets.installLoader(nil)

local booted = Loader.new({ fs = bootfs })
check(booted:load({}) == true,
      "the mod boots: " .. table.concat(booted.errors, "; "))
check(Assets.loader ~= nil,
      "loading mods installed the asset search path with no explicit call")
check(Assets.resolve("assets/generated/tilesets/overworld.png")
      == "mods/boot_skin/overrides/tilesets/overworld.png",
      "so the booted mod's overrides/ file shadows the generated path")
local derived = "save/mod-derived/boot_skin/battle/front/mew.png"
check(bootFiles[derived] ~= nil,
      "loading a mod ran its declared transform with no explicit call")
check(bootFiles["save/mod-derived/boot_skin/.stamp"] ~= nil,
      "the boot-time run stamped itself")

-- and that stamp is what keeps the second boot from paying for it again
bootFiles[derived] = nil
check(Loader.new({ fs = bootfs }):load({}) == true, "the mod boots again")
check(bootFiles[derived] == nil, "the next boot re-ran nothing")

-- ------- restore
-- Nothing this suite touched may reach the next one in the run: the mod
-- buses, the stub filesystem, the love facade and the module instances
-- all go back to what they were.

Runtime.install(savedRuntime.events, savedRuntime.hooks, savedRuntime.errors)
for _, path in ipairs(writtenFiles) do
  local before = savedFiles[path]
  love.filesystem.write(path, before ~= false and before or nil)
end
love.graphics, love.image = savedGraphics, savedImage
for name, module in pairs(savedLoaded) do package.loaded[name] = module end

S.finish()
