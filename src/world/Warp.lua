-- Warp resolution.  A warp fires when:
--   * the player finishes a step onto a warp cell whose collision tile is a
--     door tile or warp tile (stairs, doors, mats, cave entrances), or
--   * the player stands on a warp cell and tries to walk off the map edge
--     (exit carpets at the bottom of interiors), or
--   * the player stands on a warp cell and the "extra" check passes -- on
--     arrival with the d-pad held, or on a blocked step (route-gate
--     doorways, the Vermilion dock entrance, ...).
-- This mirrors pokered's CheckWarpsNoCollision / CheckWarpsCollision /
-- ExtraWarpCheck (home/overworld.asm).

local Warp = {}

-- Returns the warp entry to take when arriving at (cx,cy), or nil.
function Warp.onArrive(map, cx, cy)
  local w = map:warpAtCell(cx, cy)
  if w and map:isWarpTileCell(cx, cy) then
    return w
  end
  return nil
end

local function inList(list, v)
  for _, x in ipairs(list) do
    if x == v then return true end
  end
  return false
end

-- ExtraWarpCheck: may the player standing at (cx,cy) facing dir warp
-- without a door/warp tile underfoot?  On the carpet maps/tilesets the
-- tile in FRONT of the player must be a warp-carpet tile for the facing
-- direction (IsWarpTileInFrontOfPlayer; SS_ANNE_BOW tests one hardcoded
-- tile instead); everywhere else the player must face the map edge
-- (IsPlayerFacingEdgeOfMap).  carpets = field.warpCarpets.
function Warp.extraCheck(map, carpets, cx, cy, dir)
  local Collision = require("src.world.Collision")
  local facingEdge =
    (dir == "up" and cy == 0)
    or (dir == "down" and cy == map.heightCells - 1)
    or (dir == "left" and cx == 0)
    or (dir == "right" and cx == map.widthCells - 1)
  if not carpets then return facingEdge end
  -- the map exceptions are tested before the tileset (ExtraWarpCheck)
  local useCarpet
  if inList(carpets.edgeMaps, map.id) then
    useCarpet = false
  elseif inList(carpets.function2Maps, map.id) then
    useCarpet = true
  else
    useCarpet = inList(carpets.function2Tilesets, map.def.tileset)
  end
  if not useCarpet then return facingEdge end
  local tx, ty = Collision.target(cx, cy, dir)
  local front = map:cellTile(tx, ty)
  if map.id == carpets.ssAnneBow.map then
    return front == carpets.ssAnneBow.tile
  end
  return inList(carpets.tiles[dir], front)
end

-- Returns the warp entry when standing on (cx,cy) and the extra check
-- passes toward dir (fired from a blocked step, or on arrival with the
-- d-pad held).
function Warp.onCollision(map, carpets, cx, cy, dir)
  local w = map:warpAtCell(cx, cy)
  if w and Warp.extraCheck(map, carpets, cx, cy, dir) then
    return w
  end
  return nil
end

-- Returns the warp entry when standing on (cx,cy) and moving toward dir
-- takes the player out of bounds.
function Warp.onEdge(map, cx, cy, dir)
  local w = map:warpAtCell(cx, cy)
  if not w then return nil end
  local Collision = require("src.world.Collision")
  local tx, ty = Collision.target(cx, cy, dir)
  if not map:inBounds(tx, ty) then
    return w
  end
  return nil
end

-- Resolve a warp's destination to map id + cell.  LAST_MAP destinations
-- (returning from an interior) resolve against the remembered outdoor
-- map; the landing cell is that map's warp entry named by the warp id
-- (wDestinationWarpID placement -- two-sided route gates land you on
-- the side you exit, not where you entered).
function Warp.destination(data, warpDef, lastMap)
  local destMap = warpDef.destMap
  if destMap == "LAST_MAP" then
    assert(lastMap, "LAST_MAP warp with no remembered outdoor map")
    destMap = lastMap.id
    local destDef = data.maps[destMap]
    local dw = destDef and destDef.warps[warpDef.destWarp]
    if dw then
      return destMap, dw.x, dw.y
    end
    -- out-of-range data: fall back to where the player entered
    return destMap, lastMap.x, lastMap.y
  end
  local destDef = data.maps[destMap]
  assert(destDef, "warp to unknown map " .. tostring(destMap))
  local dw = destDef.warps[warpDef.destWarp]
  assert(dw, ("warp to %s#%d out of range"):format(destMap, warpDef.destWarp))
  return destMap, dw.x, dw.y
end

return Warp
