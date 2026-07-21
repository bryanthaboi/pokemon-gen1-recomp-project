-- Runtime map built from generated data.  All queries use "cells": the
-- 16x16 walk grid (2x2 tiles).  A map is width x height blocks; each block
-- is 2x2 cells (4x4 tiles).
--
-- Collision follows the original engine: a cell is passable when the
-- BOTTOM-LEFT 8x8 tile of the cell is in the tileset's walkable list
-- (pokered checks the tile at the sprite's feet).  Doors, warp tiles and
-- grass use the same convention.

local Map = {}
Map.__index = Map

-- Stale-cache fallbacks for the tileset properties the importer does not
-- stamp yet (item_effects.asm IsNextTileShoreOrWater, home/overworld.asm
-- CollisionCheckOnWater): $14 is water everywhere; the shore tiles $32 and
-- $48 (Safari Zone) everywhere EXCEPT SHIP_PORT, where $32 is the dock's
-- boarding platform -- a land tile.  A tileset record that carries
-- waterTiles/shoreTiles wins outright, which is how a new tileset gets
-- surfable water without naming Kanto's.
local WATER_TILES = { 0x14 }
local SHORE_TILES = { 0x32, 0x48 }
local NO_SHORE_TILESETS = { SHIP_PORT = true }

-- what counts as "outside" for the wLastMap memory (CheckIfInOutsideMap)
local OUTSIDE_TILESETS = { "OVERWORLD", "PLATEAU" }

local function hashSet(list, into)
  for _, t in ipairs(list) do into[t] = true end
  return into
end

-- Passability of a cell of an UNLOADED map def -- the connected neighbor
-- during an edge crossing.  pokered's collision check reads the neighbor
-- strip's tile bytes, so a step off the map edge onto a solid tile of
-- the connected map bumps exactly like an in-map wall; the port needs
-- the same read without building the whole Map.  Same math as cellTile
-- on the raw blocks, honoring the surf rule (water/shore passable only
-- while surfing, same fallbacks as Map.new).
function Map.defPassable(def, tilesetDef, cx, cy, surfing)
  if not (def and tilesetDef and tilesetDef.blocks and tilesetDef.walkable) then
    return true -- no data to judge with: keep the old permissive behavior
  end
  local tx, ty = cx * 2, cy * 2 + 1
  local bx, by = math.floor(tx / 4), math.floor(ty / 4)
  local id
  if bx < 0 or by < 0 or bx >= def.width or by >= def.height then
    id = def.borderBlock
  else
    id = def.blocks[by * def.width + bx + 1]
  end
  local block = tilesetDef.blocks[(id or 0) + 1]
  if not block then return false end
  local tile = block[(ty % 4) * 4 + (tx % 4) + 1]
  for _, t in ipairs(tilesetDef.walkable) do
    if t == tile then return true end
  end
  if surfing then
    for _, t in ipairs(tilesetDef.waterTiles or WATER_TILES) do
      if t == tile then return true end
    end
    local shore = tilesetDef.shoreTiles
    if shore == nil and not NO_SHORE_TILESETS[def.tileset] then
      shore = SHORE_TILES
    end
    for _, t in ipairs(shore or {}) do
      if t == tile then return true end
    end
  end
  return false
end

function Map.new(def, tilesetDef)
  local self = setmetatable({}, Map)
  self.def = def
  self.tileset = tilesetDef
  self.id = def.id
  self.widthCells = def.width * 2
  self.heightCells = def.height * 2

  self.walkable = {}
  for _, t in ipairs(tilesetDef.walkable) do self.walkable[t] = true end
  self.doorTiles = {}
  for _, t in ipairs(tilesetDef.doorTiles or {}) do self.doorTiles[t] = true end
  self.warpTiles = {}
  for _, t in ipairs(tilesetDef.warpTiles or {}) do self.warpTiles[t] = true end
  -- water and shore share one lookup: both are surfable, only the caller's
  -- water_tilesets.asm membership check separates them
  self.waterTiles = hashSet(tilesetDef.waterTiles or WATER_TILES, {})
  local shore = tilesetDef.shoreTiles
  if shore == nil and not NO_SHORE_TILESETS[def.tileset] then shore = SHORE_TILES end
  hashSet(shore or {}, self.waterTiles)

  self.warpAt = {}
  for i, w in ipairs(def.warps or {}) do
    self.warpAt[w.y * self.widthCells + w.x] = { index = i, def = w }
  end
  self.signAt = {}
  for _, s in ipairs(def.signs or {}) do
    self.signAt[s.y * self.widthCells + s.x] = s
  end
  return self
end

-- ------- map record properties (authored maps set them; vanilla falls back)

-- town/route surface: door SFX, the walk-out step, the Fly menu and the
-- town map all mean this one
function Map.isOutdoor(def)
  if def.outdoor ~= nil then return def.outdoor end
  return def.tileset == "OVERWORLD"
end

-- CheckIfInOutsideMap, a strictly wider set: Route 23 / Indigo Plateau are
-- outside for the wLastMap memory without being outdoor for the door SFX
function Map.isOutside(def, tilesets)
  if Map.isOutdoor(def) then return true end
  for _, ts in ipairs(tilesets or OUTSIDE_TILESETS) do
    if ts == def.tileset then return true end
  end
  return false
end

-- region groups maps a rule applies to without naming them; the id prefix
-- is the fallback for caches that predate the property
function Map.inRegion(def, region, prefix)
  if def.region ~= nil then return def.region == region end
  return prefix ~= nil and def.id:find(prefix, 1, true) == 1
end

-- unidentifiable wild battles on this map unless the player holds an item
function Map.ghostBattles(def)
  if def.ghostBattles ~= nil then return def.ghostBattles end
  if def.id:find("POKEMON_TOWER", 1, true) == 1 then
    return { unlessItem = "SILPH_SCOPE" }
  end
  return nil
end

-- strength-pushable map objects (engine/overworld/push_boulder.asm)
function Map.isPushable(objDef)
  if objDef.pushable ~= nil then return objDef.pushable end
  return objDef.sprite == "SPRITE_BOULDER"
end

function Map:blockAt(bx, by)
  if bx < 0 or by < 0 or bx >= self.def.width or by >= self.def.height then
    return self.def.borderBlock
  end
  return self.def.blocks[by * self.def.width + bx + 1]
end

-- tile id at tile coordinates (8px grid), border-extended
function Map:tileAt(tx, ty)
  local bx, by = math.floor(tx / 4), math.floor(ty / 4)
  local block = self.tileset.blocks[self:blockAt(bx, by) + 1]
  local ix = (ty % 4) * 4 + (tx % 4) + 1
  return block[ix]
end

-- the collision tile of a cell: bottom-left 8x8 tile
function Map:cellTile(cx, cy)
  return self:tileAt(cx * 2, cy * 2 + 1)
end

function Map:inBounds(cx, cy)
  return cx >= 0 and cy >= 0 and cx < self.widthCells and cy < self.heightCells
end

function Map:isWalkableCell(cx, cy)
  return self.walkable[self:cellTile(cx, cy)] or false
end

function Map:isGrassCell(cx, cy)
  local grass = self.tileset.grassTile
  return grass ~= nil and self:cellTile(cx, cy) == grass
end

-- Water and eastern-shore tiles, from the tileset's waterTiles/shoreTiles
-- (hash sets built in Map.new).  Tileset membership in water_tilesets.asm
-- is checked by the caller.
function Map:isWaterCell(cx, cy)
  return self.waterTiles[self:cellTile(cx, cy)] or false
end

-- Replace a block (Cut trees); the caller rebuilds the renderer.
function Map:setBlock(bx, by, block)
  if bx < 0 or by < 0 or bx >= self.def.width or by >= self.def.height then
    return
  end
  self.def.blocks[by * self.def.width + bx + 1] = block
end

-- true if the cell's collision tile is a door or warp-activating tile
function Map:isWarpTileCell(cx, cy)
  local t = self:cellTile(cx, cy)
  return self.doorTiles[t] or self.warpTiles[t] or false
end

-- counter tiles allow talking to NPCs across them (mart clerks, nurses)
function Map:isCounterCell(cx, cy)
  local t = self:cellTile(cx, cy)
  for _, c in ipairs(self.tileset.counterTiles or {}) do
    if c == t then return true end
  end
  return false
end

function Map:warpAtCell(cx, cy)
  return self.warpAt[cy * self.widthCells + cx]
end

function Map:signAtCell(cx, cy)
  return self.signAt[cy * self.widthCells + cx]
end

function Map:connection(dir)
  return self.def.connections and self.def.connections[dir]
end

return Map
