-- Map object (NPC/item) built from a generated object_event entry.
-- STAY objects keep their facing; WALK objects wander randomly within the
-- roam constraint (ANY_DIR / UP_DOWN / LEFT_RIGHT), like the original.

local Collision = require("src.world.Collision")
local SpriteRenderer = require("src.render.SpriteRenderer")

local NPC = {}
NPC.__index = NPC

local STEP_FRAMES = 16

local FACING_FROM_RANGE = {
  DOWN = "down", UP = "up", LEFT = "left", RIGHT = "right",
}

local ROAM_DIRS = {
  ANY_DIR = { "up", "down", "left", "right" },
  UP_DOWN = { "up", "down" },
  LEFT_RIGHT = { "left", "right" },
}

function NPC.new(data, mapId, objDef)
  local self = setmetatable({}, NPC)
  self.def = objDef
  self.id = string.format("%s_obj_%d", mapId, objDef.index)
  local spriteDef = data.sprites[objDef.sprite]
  assert(spriteDef, "unknown sprite " .. tostring(objDef.sprite))
  self.sprite = SpriteRenderer.new(spriteDef, self.id)
  -- object_event coordinates are already walk-grid cells
  self.cellX, self.cellY = objDef.x, objDef.y
  self.px, self.py = self.cellX * 16, self.cellY * 16
  self.facing = FACING_FROM_RANGE[objDef.range] or "down"
  self.moving = false
  self.progress = 0
  self.stepFlip = false
  self.frozen = false -- scripts freeze NPCs while talking
  self.wanders = objDef.movement == "WALK"
  self.roamDirs = ROAM_DIRS[objDef.range] or ROAM_DIRS.ANY_DIR
  self.timer = love.math.random(30, 120)
  return self
end

function NPC:facePlayer(player)
  local dx = player.cellX - self.cellX
  local dy = player.cellY - self.cellY
  if math.abs(dx) > math.abs(dy) then
    self.facing = dx > 0 and "right" or "left"
  else
    self.facing = dy > 0 and "down" or "up"
  end
end

function NPC:update(map, entities)
  if self.moving then
    self.progress = self.progress + 1
    -- NPC_CHANGE_FACING: animate the walk cycle in place, no translation
    -- (movement.asm ChangeFacingDirection zeroes the delta); px/py stay
    -- pinned to the current cell while walkPhase() cycles.
    if self.marching then
      if self.progress >= STEP_FRAMES then
        self.progress = 0
        self.moving = false
        self.marching = false
        self.stepFlip = not self.stepFlip
      end
      return
    end
    local d = Collision.DELTA[self.facing]
    self.px = self.cellX * 16 + d[1] * self.progress
    self.py = self.cellY * 16 + d[2] * self.progress
    if self.progress >= STEP_FRAMES then
      self.cellX, self.cellY = self.targetX, self.targetY
      self.targetX, self.targetY = nil, nil
      self.px, self.py = self.cellX * 16, self.cellY * 16
      self.moving = false
      self.stepFlip = not self.stepFlip
    end
    return
  end
  if self.frozen or not self.wanders then return end
  self.timer = self.timer - 1
  if self.timer > 0 then return end
  self.timer = love.math.random(30, 180)
  local dir = self.roamDirs[love.math.random(#self.roamDirs)]
  self.facing = dir
  if love.math.random() < 0.5 then return end -- sometimes just turn
  -- never wander onto warps, so NPCs don't walk out of the map
  local tx, ty = Collision.target(self.cellX, self.cellY, dir)
  if map:warpAtCell(tx, ty) then return end
  if Collision.canMove(map, entities, self, dir) then
    self.targetX, self.targetY = tx, ty
    self.moving = true
    self.progress = 0
  end
end

function NPC:walkPhase()
  if not self.moving then return 0 end
  local p = self.progress % 16
  return (p >= 4 and p < 12) and 1 or 0
end

function NPC:draw(camX, camY)
  self.sprite:draw(self.px, self.py, camX, camY, self.facing,
                   self:walkPhase(), self.stepFlip)
end

return NPC
