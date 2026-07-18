-- Trainer card (engine/menus/start_sub_menus.asm DrawTrainerInfo):
-- NAME / MONEY / TIME with the player's front pic upper-right, the
-- circle-dotted BADGES banner, and the numbered badge grid.  The boxes
-- are built from the real trainer_info.png frame tiles (the patterned
-- band + line style).

local Font = require("src.render.Font")

local TrainerCard = {}
TrainerCard.__index = TrainerCard
TrainerCard.isOpaque = true

-- SGB: PalPacket_TrainerCard leads with MEWMON
function TrainerCard:sgbPalettes(game)
  return require("src.render.PaletteFX").wholeNamed(game.data, "MEWMON")
end

-- gym order (data/scripts/victories.lua badge order)
local BADGES = {
  "BOULDERBADGE", "CASCADEBADGE", "THUNDERBADGE", "RAINBOWBADGE",
  "SOULBADGE", "MARSHBADGE", "VOLCANOBADGE", "EARTHBADGE",
}

local function tryImage(path)
  local ok, img = pcall(love.graphics.newImage, path)
  return ok and img or nil
end

local function quads16(img, count, stride, x0, y0)
  local q = {}
  local iw, ih = img:getDimensions()
  for i = 0, count - 1 do
    q[i] = love.graphics.newQuad(x0 or 0, (y0 or 0) + i * stride, 16, 16, iw, ih)
  end
  return q
end

function TrainerCard.new(game)
  local self = setmetatable({ game = game }, TrainerCard)
  local img = tryImage("assets/generated/trainer_card/badges.png")
  if img then
    -- 8 pairs of [gym leader face, badge]
    self.badges = { img = img, quads = quads16(img, 8, 32, 0, 16) }
  end
  local nums = tryImage("assets/generated/trainer_card/badge_numbers.png")
  if nums then
    self.nums = { img = nums, quads = {} }
    local iw, ih = nums:getDimensions()
    for i = 0, 7 do
      self.nums.quads[i] = love.graphics.newQuad((i % 2) * 8,
                                                 math.floor(i / 2) * 8,
                                                 8, 8, iw, ih)
    end
  end
  -- frame tiles (3x3 sheet): 0 bottom, 1 right, 2 tl, 3 top, 4 tr,
  -- 5 left, 6 bl, 7 br, 8 solid pattern
  local frame = tryImage("assets/generated/trainer_card/trainer_info.png")
  if frame then
    self.frame = { img = frame, quads = {} }
    for i = 0, 8 do
      self.frame.quads[i] = love.graphics.newQuad((i % 3) * 8,
                                                  math.floor(i / 3) * 8,
                                                  8, 8, frame:getDimensions())
    end
  end
  self.circle = tryImage("assets/generated/trainer_card/circle_tile.png")
  self.pic = tryImage("assets/generated/trainer_card/red.png")
  return self
end

function TrainerCard:update(dt)
  local input = self.game.input
  if input:wasPressed("a") or input:wasPressed("b") then
    self.game.stack:pop()
  end
end

-- a frame box in tile coords from the trainer_info tiles
function TrainerCard:frameBox(tx, ty, tw, th)
  if not self.frame then
    love.graphics.setColor(0, 0, 0, 1)
    love.graphics.rectangle("line", tx * 8 + 0.5, ty * 8 + 0.5,
                            tw * 8 - 1, th * 8 - 1)
    love.graphics.setColor(1, 1, 1, 1)
    return
  end
  local img, q = self.frame.img, self.frame.quads
  love.graphics.setColor(1, 1, 1, 1)
  local x1, y1 = (tx + tw - 1) * 8, (ty + th - 1) * 8
  love.graphics.draw(img, q[2], tx * 8, ty * 8)
  love.graphics.draw(img, q[4], x1, ty * 8)
  love.graphics.draw(img, q[6], tx * 8, y1)
  love.graphics.draw(img, q[7], x1, y1)
  for i = 1, tw - 2 do
    love.graphics.draw(img, q[3], (tx + i) * 8, ty * 8)
    love.graphics.draw(img, q[0], (tx + i) * 8, y1)
  end
  for j = 1, th - 2 do
    love.graphics.draw(img, q[5], tx * 8, (ty + j) * 8)
    love.graphics.draw(img, q[1], x1, (ty + j) * 8)
  end
end

function TrainerCard:draw()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 144)
  local save = self.game.save

  -- top card (rows 0-7): NAME / MONEY / TIME, pic upper-right
  self:frameBox(0, 0, 20, 8)
  if self.pic then
    love.graphics.draw(self.pic, 104, 4)
  end
  love.graphics.setColor(0, 0, 0, 1)
  Font.draw("NAME/" .. (save.player.name or "RED"), 16, 16)
  Font.draw(("MONEY/¥%d"):format(save.money or 0), 16, 32)
  local t = math.floor(save.playTime or 0)
  Font.draw(("TIME/%3d:%02d"):format(math.floor(t / 3600),
                                     math.floor(t / 60) % 60), 16, 48)

  -- the circle-dotted BADGES banner (TrainerInfo_BadgesText)
  self:frameBox(0, 8, 20, 3)
  love.graphics.setColor(0, 0, 0, 1)
  Font.draw("BADGES", 56, 72)
  if self.circle then
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(self.circle, 48, 72)
    love.graphics.draw(self.circle, 104, 72)
    love.graphics.setColor(0, 0, 0, 1)
  end

  -- numbered badge grid (rows 11-17): earned solid, unearned dimmed
  self:frameBox(0, 11, 20, 7)
  for i = 1, 8 do
    local col, row = (i - 1) % 4, math.floor((i - 1) / 4)
    local tx, ty = 16 + col * 32, 94 + row * 24
    if self.nums then
      love.graphics.setColor(1, 1, 1, 1)
      love.graphics.draw(self.nums.img, self.nums.quads[i - 1], tx, ty)
    end
    if self.badges and save.inventory[BADGES[i]] then
      -- unearned badge slots stay blank (DrawBadges)
      love.graphics.setColor(1, 1, 1, 1)
      love.graphics.draw(self.badges.img, self.badges.quads[i - 1],
                         tx + 4, ty + 6)
    end
  end
  love.graphics.setColor(1, 1, 1, 1)
end

return TrainerCard
