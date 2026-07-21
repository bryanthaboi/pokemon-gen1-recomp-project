-- The player: tile-grid movement with pixel interpolation, faithful to the
-- original's feel: facing changes on a short tap, movement is tile-by-tile
-- at 1px per frame (16 frames per step), input locked while stepping.

local Collision = require("src.world.Collision")
local FieldDefaults = require("src.world.FieldDefaults")
local SpriteRenderer = require("src.render.SpriteRenderer")

local Player = {}
Player.__index = Player

local STEP_FRAMES = 16
-- a turn in place holds for the ~2 frames the original spends on the
-- extra OverworldLoop pass (home/overworld.asm .handleDirectionButtonPress
-- returns to the loop without moving after a direction change)
local TURN_FRAMES = 2

function Player.new(data, cx, cy, facing)
  local self = setmetatable({}, Player)
  self.stepFrames = FieldDefaults.world(data, "stepFrames") or STEP_FRAMES
  self.bikeStepFrames = FieldDefaults.world(data, "bikeStepFrames")
  self.turnFrames = FieldDefaults.world(data, "turnFrames") or TURN_FRAMES
  -- field.playerSprites: which sprite ids the player wears on foot, on the
  -- water and on the bicycle (LoadPlayerSpriteGraphics /
  -- LoadSurfingPlayerSpriteGraphics, home/overworld.asm)
  local walkId = FieldDefaults.fieldValue(data, "playerSprites", "walk")
  local surfId = FieldDefaults.fieldValue(data, "playerSprites", "surf")
  local bikeId = FieldDefaults.fieldValue(data, "playerSprites", "bike")
  self.sprite = SpriteRenderer.new(data.sprites[walkId], "player")
  if surfId and data.sprites[surfId] then
    self.surfSprite = SpriteRenderer.new(data.sprites[surfId], "player")
  end
  if bikeId and data.sprites[bikeId] then
    self.bikeSprite = SpriteRenderer.new(data.sprites[bikeId], "player")
  end
  -- the ledge-hop shadow quarter-tile (gfx/overworld/shadow.png,
  -- LedgeHoppingShadow, engine/overworld/ledges.asm)
  local fx = data.field and data.field.overworldFx
  if fx and fx.shadow then
    local ok, img = pcall(love.graphics.newImage, fx.shadow.path)
    self.shadowImg = ok and img or nil
  end
  self.cellX, self.cellY = cx, cy
  self.px, self.py = cx * 16, cy * 16
  self.facing = facing or "down"
  self.moving = false
  self.progress = 0
  self.stepFlip = false
  self.turnTimer = 0
  self.inputLocked = false
  return self
end

function Player:position()
  return self.cellX, self.cellY
end

-- Attempt to start a step; returns "moved"|"turned"|"blocked"|nil.
function Player:tryMove(dir, map, entities)
  if self.moving or self.inputLocked then return nil end
  if self.facing ~= dir then
    self.facing = dir
    self.turnTimer = self.turnFrames or TURN_FRAMES
    return "turned"
  end
  if self.turnTimer > 0 then return nil end
  local ok, why = Collision.canMove(map, entities, self, dir)
  if not ok then
    return "blocked", why
  end
  local tx, ty = Collision.target(self.cellX, self.cellY, dir)
  self.targetX, self.targetY = tx, ty
  self.moving = true
  self.progress = 0
  -- the bicycle doubles walking speed (8 frames per step)
  local save = require("src.core.Game").save
  self.stepFramesCur = (save and save.onBike) and self.bikeStepFrames
                       or self.stepFrames or STEP_FRAMES
  return "moved"
end

-- Advance one fixed step; returns true when a step just completed.
function Player:update()
  if self.turnTimer > 0 then
    self.turnTimer = self.turnTimer - 1
  end
  if not self.moving then return false end
  local stepLen = self.stepFramesCur or self.stepFrames or STEP_FRAMES
  self.progress = self.progress + 1
  local d = Collision.DELTA[self.facing]
  local px = math.floor(self.progress * 16 / stepLen)
  self.px = self.cellX * 16 + d[1] * px
  self.py = self.cellY * 16 + d[2] * px
  if self.progress >= stepLen then
    self.cellX, self.cellY = self.targetX, self.targetY
    self.targetX, self.targetY = nil, nil
    self.px, self.py = self.cellX * 16, self.cellY * 16
    self.moving = false
    self.stepFlip = not self.stepFlip
    return true
  end
  return false
end

function Player:facingCell()
  return Collision.target(self.cellX, self.cellY, self.facing)
end

function Player:walkPhase()
  if not self.moving then return 0 end
  -- walk frame during the middle of the step
  local p = self.progress % 16
  return (p >= 4 and p < 12) and 1 or 0
end

local SPIN_ORDER = { "down", "left", "up", "right" }

function Player:draw(camX, camY)
  local py = self.py
  -- ledge hops arc (set for 2 cells by the ledge handler); surfing bobs
  if self.hopFrames and self.hopFrames > 0 then
    self.hopFrames = self.hopFrames - 1
    local t = 1 - self.hopFrames / (self.hopTotal or 32)
    py = py - math.floor(10 * math.sin(t * math.pi) + 0.5)
    -- the shadow stays on the ground under the jumper: one 8x8 tile
    -- mirrored into a 2x2 block (normal/XFLIP/YFLIP/both) whose top-left
    -- is 8px below the sprite's standing top-left (LoadHoppingShadowOAM +
    -- LedgeHoppingShadowOAMBlock, engine/overworld/ledges.asm)
    if self.shadowImg then
      local sx = math.floor(self.px - camX)
      local sy = math.floor(self.py - camY) - 4 + 8
      love.graphics.draw(self.shadowImg, sx, sy)
      love.graphics.draw(self.shadowImg, sx + 16, sy, 0, -1, 1)
      love.graphics.draw(self.shadowImg, sx, sy + 16, 0, 1, -1)
      love.graphics.draw(self.shadowImg, sx + 16, sy + 16, 0, -1, -1)
    end
  elseif self.surfing then
    self.bobTimer = ((self.bobTimer or 0) + 1) % 32
    py = py + (self.bobTimer < 16 and 0 or 1)
  end
  local facing = self.facing
  if self.spinning then
    -- spinner tiles whirl the sprite (PlayerSpinningFacingOrder)
    self.spinTimer = (self.spinTimer or 0) + 1
    facing = SPIN_ORDER[math.floor(self.spinTimer / 4) % 4 + 1]
  end
  local sprite = (self.surfing and self.surfSprite)
                 or (self.onBike and self.bikeSprite) or self.sprite
  sprite:draw(self.px, py, camX, camY, facing,
              self:walkPhase(), self.stepFlip)
end

return Player
