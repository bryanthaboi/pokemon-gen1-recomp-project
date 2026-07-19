-- Standalone: luajit mods/examples/example_shiny_palette/tests/example_shiny_palette_test.lua
-- Asserts the palette records merge and the transform degrades cleanly
-- when there is no imported cache to read.
package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local Data = require("src.core.Data")
Data:load()

-- The transform reads assets/generated/** and writes save/mod-derived/**.
-- Hiding the cache is what puts this run on the no-cache path, which is
-- the branch a mod owes the player: write nothing, load anyway.  The pixel
-- path needs a real LOVE run (love.image is not in the headless stub).
local MOD = "mods/examples/example_shiny_palette"

local function noCacheFs()
  local inner = T.fs.new(".")
  local overlay = {}
  local hidden = "assets/generated/"
  local mount = "mods/example_shiny_palette"

  local function map(path)
    if path == mount then return MOD end
    if path and path:sub(1, #mount + 1) == mount .. "/" then
      return MOD .. path:sub(#mount + 1)
    end
    return path
  end

  local fs = { root = inner.root }
  function fs.read(path)
    if path:sub(1, #hidden) == hidden then return nil end
    return overlay[path] or inner.read(map(path))
  end
  function fs.write(path, body) overlay[path] = body return true end
  function fs.createDirectory() return true end
  function fs.load(path) return inner.load(map(path)) end
  function fs.getInfo(path)
    if path == "mods" then return { type = "directory" } end
    if path:sub(1, #hidden) == hidden then return nil end
    if overlay[path] then return { type = "file" } end
    return inner.getInfo(map(path))
  end
  function fs.getDirectoryItems(path)
    if path == "mods" then return { "example_shiny_palette" } end
    return inner.getDirectoryItems(map(path))
  end
  return fs
end

local run = T.sdk.loadMod(MOD, { data = Data, fs = noCacheFs() })
T.eq(#run.errors, 0,
  "loads clean with no cache to transform (" .. tostring(run.errors[1]) .. ")")
T.eq(run.mod and run.mod.manifest.assets_transforms, "transforms.lua",
  "the manifest declares its transform")

-- ------- palettes

local shiny = Data.palettes.palettes.EXAMPLE_SHINY
T.check(shiny ~= nil, "the v2 named palette record merged")
T.eq(#shiny.colors, 4, "it carries exactly four colors")
T.eq(shiny.colors[1].r, 248, "the lightest shade is first")

local pallet = Data.palettes.palettes.PALLET
T.eq(#pallet, 4, "the town palette override kept the raw four-triple shape")
T.eq(pallet[2][2], 232, "the override took")

-- ------- the trueColor opt-out, applied by patch

for _, id in ipairs({ "SPRITE_RED", "SPRITE_RED_BIKE" }) do
  local sprite = Data.sprites[id]
  T.eq(sprite.trueColor, true, id .. " opted into trueColor")
  T.check(sprite.image ~= nil and sprite.image ~= "",
    id .. " kept its sheet path (patch named only the flag)")
  T.check(sprite.frames ~= nil, id .. " kept its frame count")
end

-- ------- the recipe itself compiles and is a function(ctx)

local chunk = assert(loadfile(MOD .. "/transforms.lua"))
local transform = chunk()
T.check(type(transform) == "function", "transforms.lua returns a function(ctx)")

-- driven with an empty cache it must write nothing and not raise
local wrote = 0
local ok, err = pcall(transform, {
  exists = function() return false end,
  readImage = function() error("must not read without exists()", 0) end,
  writeImage = function() wrote = wrote + 1 end,
  recolor = function(img) return img end,
})
T.check(ok, "the recipe survives an empty cache (" .. tostring(err) .. ")")
T.eq(wrote, 0, "and writes nothing rather than failing the mod")

-- with a cache present it derives one file per declared sheet
wrote = 0
local read = {}
T.check(pcall(transform, {
  exists = function() return true end,
  readImage = function(rel) read[#read + 1] = rel return { rel } end,
  writeImage = function() wrote = wrote + 1 end,
  recolor = function(img) return img end,
}), "the recipe runs over a populated cache")
T.eq(wrote, #read, "every sheet it read, it wrote back")
T.check(wrote >= 1, "at least one sheet is derived")

run.release()
T.finish("example_shiny_palette")
