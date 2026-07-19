-- Builds runtime Map objects (and their tile SpriteBatches) from generated
-- data, cached by map id.  The cache is keyed so a mod that patches one
-- map record after boot (or the dev-mode hot reload) can drop just that
-- entry instead of every map's SpriteBatches.

local Assets = require("src.render.Assets")
local Map = require("src.world.Map")
local TileRenderer = require("src.render.TileRenderer")

local MapLoader = {}

local cache = {}

function MapLoader.load(data, mapId)
  if cache[mapId] then return cache[mapId] end
  local def = data.maps[mapId]
  assert(def, "unknown map: " .. tostring(mapId) ..
         " (not in the maps registry)")
  local tilesetDef = data.tilesets[def.tileset]
  assert(tilesetDef, ("map %s wants unknown tileset: %s (not in the " ..
         "tilesets registry)"):format(tostring(mapId), tostring(def.tileset)))

  -- warp tiles are stored per tileset macro name; the generated tilesets
  -- module carries them in the tileset entry itself
  local map = Map.new(def, tilesetDef)
  map.renderer = TileRenderer.new(map)
  cache[mapId] = map
  return map
end

-- the live instance for a map id, or nil when it has not been loaded;
-- callers that must not build a map (invalidation, tests) use this
function MapLoader.cached(mapId)
  return cache[mapId]
end

-- drop one map so the next load re-reads its record and rebuilds its
-- renderer.  Callers holding the old instance keep it -- OverworldState
-- re-points self.map itself (WorldAPI:invalidateMap).
function MapLoader.invalidate(mapId)
  local had = cache[mapId] ~= nil
  cache[mapId] = nil
  return had
end

function MapLoader.invalidateAll()
  cache = {}
end

-- kept as the pre-v2 name
MapLoader.clearCache = MapLoader.invalidateAll

-- the cached Map objects own the per-map TileRenderer instances, so a flush
-- that skipped this one would leave live SpriteBatches built from the old
-- search path (14 cache-invalidation contract, rows 1 and 3)
Assets.register(MapLoader.invalidateAll)

return MapLoader
