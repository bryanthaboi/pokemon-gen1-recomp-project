-- Builds runtime Map objects (and their tile SpriteBatches) from generated
-- data, cached by map id.  The cache is keyed so a mod that patches one
-- map record after boot (or the dev-mode hot reload) can drop just that
-- entry instead of every map's SpriteBatches.
--
-- The resident set is trimmed LRU (trim) so exploring a large world never
-- holds every visited map's GPU objects at once.  Maps are built on demand
-- and cheaply: a map's tile layer draws windowed to the camera (see
-- TileRenderer), so there is no per-map batch to construct up front and thus
-- nothing to stream -- OverworldState:rebuildNeighbors just loads each
-- neighbor directly.

local Assets = require("src.render.Assets")
local Map = require("src.world.Map")
local TileRenderer = require("src.render.TileRenderer")

local MapLoader = {}

local cache = {}
-- mapId -> monotonic access stamp, for LRU eviction
local lru = {}
local accessSeq = 0
-- max map renderers kept resident.  Comfortably above the largest
-- current+neighbor set (~15 in dense overworld), so protected maps are
-- never the ones evicted; this only caps the lingering trail behind you.
local RESIDENT_CAP = 32

local function touch(mapId)
  accessSeq = accessSeq + 1
  lru[mapId] = accessSeq
end

local function build(data, mapId)
  local def = data.maps[mapId]
  assert(def, "unknown map: " .. tostring(mapId) ..
         " (not in the maps registry)")
  local tilesetDef = data.tilesets[def.tileset]
  assert(tilesetDef, ("map %s wants unknown tileset: %s (not in the " ..
         "tilesets registry)"):format(tostring(mapId), tostring(def.tileset)))

  -- warp tiles are stored per tileset macro name; the generated tilesets
  -- module carries them in the tileset entry itself
  local map = Map.new(def, tilesetDef)
  map.renderer = TileRenderer.new(map, data)
  cache[mapId] = map
  touch(mapId)
  return map
end

function MapLoader.load(data, mapId)
  local m = cache[mapId]
  if m then touch(mapId); return m end
  return build(data, mapId)
end

-- the live instance for a map id, or nil when it has not been loaded;
-- callers that must not build a map (invalidation, tests) use this
function MapLoader.cached(mapId)
  local m = cache[mapId]
  if m then touch(mapId) end
  return m
end

-- evict one resident map, releasing its renderer's GPU objects.  Callers
-- must ensure the map is not the current map and not drawn as a connected
-- strip (nothing live may hold its renderer) -- MapLoader.trim guarantees
-- this via its `protected` set.
function MapLoader.evict(mapId)
  local m = cache[mapId]
  if not m then return false end
  cache[mapId] = nil
  lru[mapId] = nil
  local r = m.renderer
  if r and r.release then pcall(r.release, r) end
  return true
end

-- keep the resident renderer set bounded.  `protected` (mapId -> true) is
-- never evicted (the current map and everything drawn as a connected
-- strip); the rest is trimmed least-recently-used down to RESIDENT_CAP.
function MapLoader.trim(protected)
  local n = 0
  for _ in pairs(cache) do n = n + 1 end
  if n <= RESIDENT_CAP then return end
  local ids = {}
  for id in pairs(cache) do
    if not (protected and protected[id]) then ids[#ids + 1] = id end
  end
  table.sort(ids, function(a, b) return (lru[a] or 0) < (lru[b] or 0) end)
  local over = n - RESIDENT_CAP
  for _, id in ipairs(ids) do
    if over <= 0 then break end
    MapLoader.evict(id)
    over = over - 1
  end
end

-- drop one map so the next load re-reads its record and rebuilds its
-- renderer.  Deliberately does NOT release the old renderer: callers
-- holding the old instance keep drawing it until they re-point themselves
-- (OverworldState re-points self.map / self.neighbors via setMap /
-- rebuildNeighbors), so releasing here would free a batch still in use.
-- The orphaned instance is reclaimed by GC; MapLoader.evict is the path
-- that releases eagerly, and it only runs on maps nothing live holds.
function MapLoader.invalidate(mapId)
  local had = cache[mapId] ~= nil
  cache[mapId] = nil
  lru[mapId] = nil
  return had
end

function MapLoader.invalidateAll()
  cache = {}
  lru = {}
end

-- kept as the pre-v2 name
MapLoader.clearCache = MapLoader.invalidateAll

-- the cached Map objects own the per-map TileRenderer instances, so a flush
-- that skipped this one would leave live SpriteBatches built from the old
-- search path (14 cache-invalidation contract, rows 1 and 3)
Assets.register(MapLoader.invalidateAll)

return MapLoader
