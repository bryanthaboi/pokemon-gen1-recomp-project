-- Movement permission checks: tile passability (from generated collision
-- data), map bounds, and entity occupancy.

local Runtime = require("src.mods.Runtime")

local Collision = {}

local DELTA = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }
Collision.DELTA = DELTA

function Collision.target(cx, cy, dir)
  local d = DELTA[dir]
  return cx + d[1], cy + d[2]
end

-- entities: array of anything with cellX/cellY (and optional targetX/targetY
-- while mid-step, so nobody walks into a cell being entered).
function Collision.occupied(entities, cx, cy, ignore)
  for _, e in ipairs(entities) do
    if e ~= ignore then
      if (e.cellX == cx and e.cellY == cy) or
         (e.targetX == cx and e.targetY == cy) then
        return e
      end
    end
  end
  return nil
end

-- Tile-pair (elevation) collisions: certain tile pairs can't be crossed
-- in a given tileset (cave/forest ledges).  data set via Collision.load.
local tilePairs = nil

function Collision.load(data)
  tilePairs = data.field and data.field.tilePairs or { land = {}, water = {} }
end

local function pairBlocked(map, mover, sx, sy, tx, ty)
  if not tilePairs then return false end
  local list = mover.surfing and tilePairs.water or tilePairs.land
  if not list or #list == 0 then return false end
  local tileset = map.def.tileset
  local a = map:cellTile(sx, sy)
  local b = map:cellTile(tx, ty)
  for _, p in ipairs(list) do
    if p.tileset == tileset
       and ((p.a == a and p.b == b) or (p.a == b and p.b == a)) then
      return true
    end
  end
  return false
end

local function verdict(map, entities, mover, dir, tx, ty)
  if not map:inBounds(tx, ty) then
    return false, "bounds"
  end
  if not map:isWalkableCell(tx, ty) then
    -- surfers may ride water cells
    if not (mover.surfing and map:isWaterCell(tx, ty)) then
      return false, "tile"
    end
  end
  if pairBlocked(map, mover, mover.cellX, mover.cellY, tx, ty) then
    return false, "tile"
  end
  if Collision.occupied(entities, tx, ty, mover) then
    return false, "entity"
  end
  return true
end

-- the movement.collision chain sees the boolean; a wrapper that flips it
-- rewrites ctx.reason to say why (the engine's own reasons are bounds /
-- tile / entity), so the hook stays a single-value middleware
local function passthrough(allowed) return allowed end

-- Returns true when the mover may step from (cx,cy) toward dir.
-- Out-of-bounds is blocked here; the OverworldController handles map
-- connections and edge warps before asking.  Per-step hot path: with an
-- empty chain this costs one table lookup and no ctx allocation.
function Collision.canMove(map, entities, mover, dir)
  local tx, ty = Collision.target(mover.cellX, mover.cellY, dir)
  local allowed, why = verdict(map, entities, mover, dir, tx, ty)
  if Runtime.wantsHook("movement.collision") then
    local ctx = { map = map, mover = mover, dir = dir,
                  fromX = mover.cellX, fromY = mover.cellY,
                  toX = tx, toY = ty, reason = why }
    allowed = Runtime.call("movement.collision", passthrough, allowed, ctx)
    why = ctx.reason
  end
  if allowed then return true end
  return false, why
end

return Collision
