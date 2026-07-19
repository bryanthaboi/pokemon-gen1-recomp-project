-- Asset transforms (D11): the manifest's assets_transforms file, run once
-- at install / first load to generate derived art from the player's *own*
-- imported cache.  A mod ships the recipe, never the pixels, which is the
-- only sanctioned way to port art that overlaps vanilla Red
-- (17-total-conversions.md §legal posture).
--
-- The chunk runs in a restricted context: a table of image utilities and
-- exactly two filesystem roots -- read assets/generated/**, write
-- save/mod-derived/<id>/** -- with no require, no love, no io, no os.
-- assets/generated is never written because re-import wipes it whole
-- (RomImporter), so anything a transform put there would vanish.
--
-- A stamp of (cache marker + transform source hash) gates the run, so the
-- cost is paid once per install and re-paid only when the cache is
-- re-imported or the recipe changes.

local Logger = require("src.core.Logger")
local Runtime = require("src.mods.Runtime")

local unpack = table.unpack or unpack
local loadstring = loadstring or load

local AssetTransform = {}

local SOURCE_ROOT = "assets/generated/"
local DERIVED_ROOT = "save/mod-derived/"
local CACHE_MARKER = "rom-cache.complete"
local STAMP = ".stamp"

AssetTransform.SOURCE_ROOT = SOURCE_ROOT
AssetTransform.DERIVED_ROOT = DERIVED_ROOT

-- ------- path sandbox

-- a relative path that cannot climb out of the root it is joined to
local function safeRelative(rel)
  if type(rel) ~= "string" or rel == "" then return nil end
  if rel:sub(1, 1) == "/" then return nil end
  if rel:find("\\", 1, true) then return nil end
  for segment in rel:gmatch("[^/]+") do
    if segment == ".." or segment == "." then return nil end
  end
  return rel
end

local function requireRelative(rel, what)
  local safe = safeRelative(rel)
  if not safe then
    error(("%s must stay inside its root, got %q"):format(what, tostring(rel)), 0)
  end
  return safe
end

-- ------- the restricted context

-- shade classification matching the importer's 4 grays and the render
-- thresholds (PaletteFX 0.83 / 0.5 / 0.17), so recolor lands on the same
-- buckets every other consumer reads
local function shadeIndex(r)
  if r > 0.83 then return 1 end
  if r > 0.5 then return 2 end
  if r > 0.17 then return 3 end
  return 4
end

-- shade index -> new color, as 0-255 triples (a palettes record's shape).
-- Alpha rides through untouched so a matted battle pic stays matted.
function AssetTransform.recolor(imageData, shades)
  assert(type(shades) == "table" and #shades == 4,
    "recolor needs 4 colors, lightest first")
  local out = love.image.newImageData(imageData:getDimensions())
  out:paste(imageData, 0, 0, 0, 0, imageData:getDimensions())
  out:mapPixel(function(_, _, r, g, b, a)
    if a == 0 then return r, g, b, a end
    local c = shades[shadeIndex(r)]
    return c[1] / 255, c[2] / 255, c[3] / 255, a
  end)
  return out
end

local function contextFor(modId, fs)
  local ImageWriter = require("src.import.ImageWriter")
  local derivedRoot = DERIVED_ROOT .. modId .. "/"
  local written = 0
  local ctx = {}

  function ctx.source(rel)
    return SOURCE_ROOT .. requireRelative(rel, "source path")
  end

  function ctx.derived(rel)
    return derivedRoot .. requireRelative(rel, "derived path")
  end

  function ctx.exists(rel)
    return fs.getInfo(ctx.source(rel)) ~= nil
  end

  function ctx.readImage(rel)
    return love.image.newImageData(ctx.source(rel))
  end

  function ctx.writeImage(imageData, rel)
    local path = ctx.derived(rel)
    local dir = path:match("^(.*)/[^/]+$")
    -- an injected headless fs implies its directories from key prefixes
    if dir and fs.createDirectory then fs.createDirectory(dir) end
    local encoded = imageData:encode("png")
    local ok, err = fs.write(path, encoded)
    if not ok then error("could not write " .. path .. ": " .. tostring(err), 0) end
    written = written + 1
    return path
  end

  ctx.blank = ImageWriter.blank
  ctx.blit = ImageWriter.blit
  ctx.matte = ImageWriter.matteColor0
  ctx.recolor = AssetTransform.recolor

  return ctx, function() return written end
end

-- Globals the recipe sees.  Everything that could reach the filesystem,
-- the network or another engine module is absent, so the only way out of
-- the sandbox is the ctx table the transform is handed.
local function sandboxEnv()
  return {
    math = math, string = string, table = table,
    ipairs = ipairs, pairs = pairs, next = next, select = select,
    type = type, tostring = tostring, tonumber = tonumber,
    assert = assert, error = error, pcall = pcall, unpack = unpack,
  }
end

-- The recipe is compiled from source we already read rather than through
-- fs.load, because that is the only way the environment is ours to set:
-- 5.1/LuaJIT swap it after the fact with setfenv, 5.2+ dropped setfenv and
-- take the env as load's 4th argument.  Getting this wrong hands the chunk
-- the real globals -- require, love, io -- so it is never left to chance.
local function loadSandboxed(source, chunkname)
  local env = sandboxEnv()
  if setfenv then
    local chunk, err = loadstring(source, chunkname)
    if not chunk then return nil, err end
    setfenv(chunk, env)
    return chunk
  end
  return load(source, chunkname, "t", env)
end

-- ------- stamp

-- djb2 over the recipe source; only has to change when the file does
local function hash(text)
  local h = 5381
  for i = 1, #text do
    h = (h * 33 + text:byte(i)) % 4294967296
  end
  return string.format("%08x", h)
end

local function stampFor(fs, source)
  local marker = fs.read(CACHE_MARKER) or "no-cache"
  return marker .. "|" .. hash(source)
end

-- ------- runner

-- Run one mod's transform.  Returns true when the derived assets are
-- current (whether this call built them or a previous one did); false
-- plus a reason when the recipe failed, which disables that mod's derived
-- art and nothing else.  force skips the stamp (dev-mode hot reload).
function AssetTransform.runFor(mod, fs, force)
  fs = fs or (love and love.filesystem)
  local manifest = mod.manifest
  local relative = manifest and manifest.assets_transforms
  if not relative then return true end
  local modId = manifest.id
  local path = mod.path .. "/" .. relative

  local source = fs.read(path)
  if not source then
    return false, "assets_transforms unreadable: " .. relative
  end

  local stampPath = DERIVED_ROOT .. modId .. "/" .. STAMP
  local want = stampFor(fs, source)
  if not force and fs.read(stampPath) == want then return true end

  local chunk, err = loadSandboxed(source, path)
  if not chunk then return false, "assets_transforms: " .. tostring(err) end

  local ctx, count = contextFor(modId, fs)
  local ok, result = pcall(chunk)
  if ok and type(result) == "function" then
    ok, result = pcall(result, ctx)
  elseif ok and type(result) ~= "function" then
    ok, result = false, "assets_transforms must return a function(ctx)"
  end
  if not ok then
    local reason = "asset transform failed: " .. tostring(result)
    Logger.error("[%s] %s", modId, reason)
    Runtime.reportError(modId, reason)
    return false, reason
  end

  if fs.createDirectory then fs.createDirectory(DERIVED_ROOT .. modId) end
  fs.write(stampPath, want)
  Runtime.emit("assets.transformed", { modId = modId, count = count() })
  return true
end

-- every loaded mod that declares a transform, in load order.  A failing
-- recipe is reported against its mod and the rest still run.
function AssetTransform.run(loader, force)
  local ran = 0
  for _, mod in ipairs(loader.loaded or {}) do
    if mod.manifest.assets_transforms then
      local ok, reason = AssetTransform.runFor(mod, loader.fs, force)
      if ok then
        ran = ran + 1
      elseif reason then
        loader.errors[#loader.errors + 1] = mod.manifest.id .. ": " .. reason
      end
    end
  end
  return ran
end

return AssetTransform
