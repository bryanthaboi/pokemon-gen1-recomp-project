-- Link/in-game trade cinematic (engine/movie/trade.asm, trade2.asm):
-- the traded POKéMON rises away with its cry and a goodbye, then the
-- received one descends with its cry and "take good care" text.
-- A skips the slide animations ahead.  Calls onDone() after popping.

local Sound = require("src.core.Sound")
local TextBox = require("src.render.TextBox")

local TradeAnim = {}
TradeAnim.__index = TradeAnim
TradeAnim.isOpaque = true

-- SGB: generic whole-screen palette (SET_PAL_GENERIC)
function TradeAnim:sgbPalettes(game)
  return require("src.render.PaletteFX").wholeNamed(game.data, "MEWMON")
end

local SLIDE_FRAMES = 90
local REST_Y = 44 -- resting top of the sprite, roughly screen centre

local function tryImage(path)
  if not path then return nil end
  local ok, img = pcall(love.graphics.newImage, path)
  return ok and img or nil
end

local function nameOf(game, mon)
  local def = game.data.pokemon[mon.species]
  return mon.nickname or (def and def.name) or mon.species
end

local function spriteOf(game, mon)
  local def = game.data.pokemon[mon.species]
  return tryImage(def and def.spriteFront)
end

function TradeAnim.new(game, opts)
  opts = opts or {}
  local self = setmetatable({}, TradeAnim)
  self.game = game
  self.sent = opts.sent
  self.received = opts.received
  self.onDone = opts.onDone
  self.sentSprite = spriteOf(game, self.sent)
  self.receivedSprite = spriteOf(game, self.received)
  self.phase = "out"
  self.t = 0
  return self
end

function TradeAnim:enter()
  Sound.playCry(self.game.data, self.sent.species)
end

function TradeAnim:update(dt)
  local input = self.game.input
  if self.phase == "out" or self.phase == "in" then
    self.t = self.t + 1
    if input:wasPressed("a") then self.t = SLIDE_FRAMES end
    if self.t < SLIDE_FRAMES then return end
    if self.phase == "out" then
      self.phase = "goodbye"
      self.game.stack:push(TextBox.new(self.game,
        ("Goodbye %s!"):format(nameOf(self.game, self.sent)),
        function()
          self.phase = "in"
          self.t = 0
          Sound.playCry(self.game.data, self.received.species)
        end))
    else
      self.phase = "takecare"
      self.game.stack:push(TextBox.new(self.game,
        ("Take good care\nof %s!"):format(nameOf(self.game, self.received)),
        function()
          self.game.stack:pop()
          if self.onDone then self.onDone() end
        end))
    end
  end
end

function TradeAnim:draw()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 144)
  local sprite, y
  if self.phase == "out" then
    -- the sent mon rises up and off the screen
    sprite = self.sentSprite
    y = REST_Y - math.floor((self.t / SLIDE_FRAMES) * (REST_Y + 60))
  elseif self.phase == "in" or self.phase == "takecare" then
    -- the received mon descends into place
    sprite = self.receivedSprite
    local t = self.phase == "in" and self.t or SLIDE_FRAMES
    y = -60 + math.floor((t / SLIDE_FRAMES) * (REST_Y + 60))
  end
  if sprite and y then
    local w = sprite:getWidth()
    love.graphics.draw(sprite, math.floor((160 - w) / 2), y)
  end
end

return TradeAnim
