-- The "how many?" selector (DisplayChooseQuantityMenu, home/list_menu.asm):
-- Up/Down step by 1 with 1..max roll-over, A confirms, B cancels.
-- Shows a running price when opts.unitPrice is set.

local Font = require("src.render.Font")

local QuantityBox = {}
QuantityBox.__index = QuantityBox
QuantityBox.isOpaque = false

function QuantityBox.new(game, opts)
  local self = setmetatable({}, QuantityBox)
  self.game = game
  self.max = math.max(1, opts.max or 99)
  self.qty = math.min(opts.start or 1, self.max)
  self.unitPrice = opts.unitPrice
  self.onDone = opts.onDone -- onDone(qty | nil on cancel)
  return self
end

local function wrap(v, max)
  if v < 1 then return max end
  if v > max then return 1 end
  return v
end

function QuantityBox:update(dt)
  local input = self.game.input
  if input:wasPressed("up") then
    self.qty = wrap(self.qty + 1, self.max)
  elseif input:wasPressed("down") then
    self.qty = wrap(self.qty - 1, self.max)
  elseif input:wasPressed("a") then
    self.game.stack:pop()
    if self.onDone then self.onDone(self.qty) end
  elseif input:wasPressed("b") then
    self.game.stack:pop()
    if self.onDone then self.onDone(nil) end
  end
end

function QuantityBox:draw()
  local w = self.unitPrice and 11 or 7
  local tx = 20 - w - 1
  Font.drawBox(tx, 13, w, 3)
  love.graphics.setColor(0, 0, 0, 1)
  local s = ("×%02d"):format(self.qty) -- the multiply glyph tile
  if self.unitPrice then
    s = s .. (" ¥%d"):format(self.qty * self.unitPrice)
  end
  Font.draw(s, (tx + 1) * 8, 14 * 8)
  love.graphics.setColor(1, 1, 1, 1)
end

return QuantityBox
