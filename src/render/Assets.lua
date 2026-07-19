-- Central image cache plus the mod-visible asset search path.  Every
-- renderer that used to call love.graphics.newImage(path) straight goes
-- through Assets.image, so an enabled mod shadows a generated asset with
-- its own file without editing a single record, and one flush() drops
-- every downstream cache for dev-mode hot reload.
--
-- No loader installed means resolve() is the identity, which is what
-- keeps a mod-free boot (and every headless test) loading exactly the
-- paths it always did.

local Assets = {}

-- resolved path -> love Image
local cache = {}
-- downstream caches that must empty when the search path changes
local invalidators = {}

-- The loader bridge: overrideOrder() yields mods highest-priority-first
-- and derivedPath(rel) yields an existing save/mod-derived/<id>/<rel>.
-- nil until the loader installs one.
Assets.loader = nil

local GENERATED = "assets/generated/"

local function exists(path)
  local fs = love and love.filesystem
  if not (fs and fs.getInfo) then return false end
  return fs.getInfo(path) ~= nil
end
Assets.exists = exists

-- an override dir shadows the generated cache; a transform's derived
-- output is the fallback under it, so hand-authored art beats generated
function Assets.resolve(path)
  local loader = Assets.loader
  if not loader or type(path) ~= "string" then return path end
  if path:sub(1, #GENERATED) ~= GENERATED then return path end
  local rel = path:sub(#GENERATED + 1)
  for _, mod in ipairs(loader:overrideOrder()) do
    local candidate = mod.path .. "/overrides/" .. rel
    if exists(candidate) then return candidate end
  end
  return loader:derivedPath(rel) or path
end

function Assets.image(path)
  local resolved = Assets.resolve(path)
  local image = cache[resolved]
  if not image then
    image = love.graphics.newImage(resolved)
    cache[resolved] = image
  end
  return image
end

-- pixel-level reads (tile-shift variants, the spinner strip blit) resolve
-- the same way but stay uncached: the caller keeps the derived product
function Assets.imageData(path)
  return love.image.newImageData(Assets.resolve(path))
end

function Assets.register(invalidate)
  invalidators[#invalidators + 1] = invalidate
end

-- hot reload's single entry point (20-developer-tooling): drop the central
-- cache and fan out to every registered downstream one.  A cache whose
-- invalidator throws must not strand the ones behind it in the list.
function Assets.invalidate()
  cache = {}
  for _, fn in ipairs(invalidators) do pcall(fn) end
end

Assets.flush = Assets.invalidate

-- Loader:load hands over the live mod set once the merge is done.  Load
-- order is priority ascending, so the search walks it backwards: the mod
-- that wins the record merge wins the asset lookup too.
function Assets.installLoader(loader)
  if not loader then
    Assets.loader = nil
    Assets.invalidate()
    return
  end
  local bridge = {}
  function bridge:overrideOrder()
    local order = {}
    local loaded = loader.loaded or {}
    for i = #loaded, 1, -1 do
      order[#order + 1] = { id = loaded[i].manifest.id, path = loaded[i].path }
    end
    return order
  end
  function bridge:derivedPath(rel)
    for _, mod in ipairs(self:overrideOrder()) do
      local candidate = "save/mod-derived/" .. mod.id .. "/" .. rel
      if exists(candidate) then return candidate end
    end
    return nil
  end
  Assets.loader = bridge
  Assets.invalidate()
end

return Assets
