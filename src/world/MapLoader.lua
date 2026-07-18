-- Builds runtime Map objects (and their tile SpriteBatches) from generated
-- data, cached by map id.

local Map = require("src.world.Map")
local TileRenderer = require("src.render.TileRenderer")

local MapLoader = {}

local cache = {}

function MapLoader.load(data, mapId)
  if cache[mapId] then return cache[mapId] end
  local def = data.maps[mapId]
  assert(def, "unknown map: " .. tostring(mapId))
  local tilesetDef = data.tilesets[def.tileset]
  assert(tilesetDef, "unknown tileset: " .. tostring(def.tileset))

  -- warp tiles are stored per tileset macro name; the generated tilesets
  -- module carries them in the tileset entry itself
  local map = Map.new(def, tilesetDef)
  map.renderer = TileRenderer.new(map)
  cache[mapId] = map
  return map
end

function MapLoader.clearCache()
  cache = {}
end

return MapLoader
