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

  self.warpAt = {}
  for i, w in ipairs(def.warps) do
    self.warpAt[w.y * self.widthCells + w.x] = { index = i, def = w }
  end
  self.signAt = {}
  for _, s in ipairs(def.signs) do
    self.signAt[s.y * self.widthCells + s.x] = s
  end
  return self
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

-- Water and eastern-shore tiles (item_effects.asm IsNextTileShoreOrWater,
-- home/overworld.asm CollisionCheckOnWater): $14 everywhere; the shore
-- tiles $32 and $48 (Safari Zone) everywhere EXCEPT the SHIP_PORT
-- tileset, where $32 is the dock's boarding platform (a land tile).
-- Tileset membership in water_tilesets.asm is checked by the caller.
function Map:isWaterCell(cx, cy)
  local t = self:cellTile(cx, cy)
  if t == 0x14 then return true end
  if self.def.tileset == "SHIP_PORT" then return false end
  return t == 0x32 or t == 0x48
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
