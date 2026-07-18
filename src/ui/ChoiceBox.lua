-- YES/NO choice box (top-left of the text box area, like the original).

local Font = require("src.render.Font")

local ChoiceBox = {}
ChoiceBox.__index = ChoiceBox

local CURSOR = 0xED

function ChoiceBox.new(game, onChoose, opts)
  local self = setmetatable({}, ChoiceBox)
  self.game = game
  self.onChoose = onChoose
  -- some of the original's prompts start on NO (e.g. release)
  self.index = (opts and opts.defaultNo) and 2 or 1
  -- BIT_NO_MENU_BUTTON_SOUND: PC-session prompts stay silent
  self.noSound = (opts and opts.noSound) or false
  return self
end

function ChoiceBox:update(dt)
  local input = self.game.input
  if input:wasPressed("up") or input:wasPressed("down") then
    self.index = self.index == 1 and 2 or 1
  elseif input:wasPressed("a") then
    -- HandleMenuInput_ (home/window.asm): SFX_PRESS_AB on A and B alike
    if not self.noSound then
      require("src.core.Sound").play(self.game.data, "Press_AB")
    end
    self.game.stack:pop()
    self.onChoose(self.index == 1)
  elseif input:wasPressed("b") then
    if not self.noSound then
      require("src.core.Sound").play(self.game.data, "Press_AB")
    end
    self.game.stack:pop()
    self.onChoose(false)
  end
end

function ChoiceBox:draw()
  Font.drawBox(0, 7, 6, 5)
  love.graphics.setColor(0, 0, 0, 1)
  Font.draw("YES", 16, 8 * 8)
  Font.draw("NO", 16, 10 * 8)
  Font.drawCode(CURSOR, 8, (self.index == 1 and 8 or 10) * 8)
  love.graphics.setColor(1, 1, 1, 1)
end

return ChoiceBox
