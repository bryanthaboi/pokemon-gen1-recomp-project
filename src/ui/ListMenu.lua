-- Generic full-screen scrollable list: items are { label=..., right=...,
-- value=... }; onChoose(item) / onCancel().  Used by the bag, shops, the
-- box and the Pokédex.

local Font = require("src.render.Font")
local Theme = require("src.ui.Theme")

local ListMenu = {}
ListMenu.__index = ListMenu
ListMenu.isOpaque = true

-- SGB: generic whole-screen palette (SET_PAL_GENERIC)
function ListMenu:sgbPalettes(game)
  return require("src.render.PaletteFX").wholeNamed(game.data, "MEWMON")
end

local ROWS = 7

function ListMenu.new(game, title, items, opts)
  opts = opts or {}
  local self = setmetatable({}, ListMenu)
  self.game = game
  self.title = title
  self.items = items
  self.index = 1
  self.scroll = 0
  self.onChoose = opts.onChoose
  self.onCancel = opts.onCancel
  self.footer = opts.footer
  self.pageJump = opts.pageJump    -- Left/Right move a page at a time
  self.onSelectKey = opts.onSelectKey -- SELECT pressed on an item
  -- scripted mode (the old man tutorial): update() runs the script
  -- every frame INSTEAD of reading input -- DisplayListMenuID's old-man
  -- branch (home/list_menu.asm:65-80) never calls HandleMenuInput
  self.script = opts.script
  -- shop mode: the footer becomes the clerk's line in a framed bottom
  -- text box, a money box sits top-right, and the list shortens to
  -- clear them (DisplayPokemartDialogue_'s screen)
  self.dialogue = opts.dialogue
  self.money = opts.money          -- () -> current money for the box
  self.rows = opts.dialogue and 4 or ROWS
  return self
end

function ListMenu:update(dt)
  if self.script then
    self.script(self)
    return
  end
  local input = self.game.input
  if #self.items == 0 then
    if input:wasPressed("a") or input:wasPressed("b") then
      self.game.stack:pop()
      if self.onCancel then self.onCancel() end
    end
    return
  end
  if input:wasPressed("up") then
    self.index = math.max(1, self.index - 1)
  elseif input:wasPressed("down") then
    self.index = math.min(#self.items, self.index + 1)
  elseif self.pageJump and input:wasPressed("left") then
    self.index = math.max(1, self.index - self.rows)
  elseif self.pageJump and input:wasPressed("right") then
    self.index = math.min(#self.items, self.index + self.rows)
  elseif self.onSelectKey and input:wasPressed("select") then
    self.onSelectKey(self.items[self.index], self)
  elseif input:wasPressed("b") then
    self.game.stack:pop()
    if self.onCancel then self.onCancel() end
    return
  elseif input:wasPressed("a") then
    local item = self.items[self.index]
    if self.onChoose then
      self.onChoose(item, self)
    end
    return
  end
  if self.index - self.scroll > self.rows then
    self.scroll = self.index - self.rows
  end
  if self.index - self.scroll < 1 then self.scroll = self.index - 1 end
end

-- remove current item (e.g. consumed); keeps cursor valid
function ListMenu:removeCurrent()
  table.remove(self.items, self.index)
  self.index = math.max(1, math.min(self.index, #self.items))
end

function ListMenu:close()
  local top = self.game.stack:top()
  if top == self then self.game.stack:pop() end
end

function ListMenu:draw()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 144)
  love.graphics.setColor(0, 0, 0, 1)
  Font.draw(self.title, 8, 4)
  if #self.items == 0 then
    Font.draw("Nothing here.", 16, 64)
  end
  for row = 1, self.rows do
    local i = self.scroll + row
    local item = self.items[i]
    if not item then break end
    local y = 8 + row * 16
    Font.draw(item.label, 16, y)
    if item.ball then -- the Pokédex owned-ball marker tile
      local bx = 16 + (#item.label + 1) * 8 + 3
      local by = y + 3
      love.graphics.circle("fill", bx, by, 3.5)
      love.graphics.setColor(1, 1, 1, 1)
      love.graphics.rectangle("fill", bx - 3.5, by - 0.5, 7, 1)
      love.graphics.circle("fill", bx, by, 1.2)
      love.graphics.setColor(0, 0, 0, 1)
    end
    if item.right then
      Font.draw(item.right, 160 - 8 - Font.width(item.right), y)
    end
    if i == self.index then
      -- hollowIndex: a chosen row keeps the hollow '▷' left behind by
      -- pokered's PlaceUnfilledArrowMenuCursor (the old man demo's
      -- auto A-press, home/list_menu.asm:89-91)
      Font.drawCode((self.swapIndex == i or self.hollowIndex == i)
                    and Theme.cursorHollow or Theme.cursor, 8, y)
    end
    if self.swapIndex == i and i ~= self.index then
      Font.drawCode(Theme.cursorHollow, 8, y) -- ▷ marks the item being moved
    end
  end
  if self.dialogue then
    -- money box (DisplayTextBoxID MONEY_BOX, hlcoord 11,0): the amount
    -- right-aligned on its middle row
    Font.drawBox(11, 0, 9, 3)
    love.graphics.setColor(0, 0, 0, 1)
    local money = ("¥%d"):format(self.money and self.money() or 0)
    Font.draw(money, 152 - Font.width(money), 8)
    -- the clerk's line in the standard bottom text box; long prompts
    -- wrap and keep their last two lines, like the GB's scrolled box
    Font.drawBox(0, 12, 20, 6)
    love.graphics.setColor(0, 0, 0, 1)
    if self.footer then
      local flat = {}
      for _, page in ipairs(require("src.render.TextBox").paginate(self.footer)) do
        for _, line in ipairs(page) do flat[#flat + 1] = line end
      end
      local y = 112
      for i = math.max(1, #flat - 1), #flat do
        Font.draw(flat[i], 8, y)
        y = y + 16
      end
    end
  elseif self.footer then
    -- PC deposit/withdraw footers use "\n"; draw the last two lines so
    -- long item names are not clipped at the screen edge (#115).
    local flat = {}
    for _, page in ipairs(require("src.render.TextBox").paginate(self.footer)) do
      for _, line in ipairs(page) do flat[#flat + 1] = line end
    end
    local y = (#flat >= 2) and 120 or 136
    for i = math.max(1, #flat - 1), #flat do
      Font.draw(flat[i], 8, y)
      y = y + 16
    end
  end
  love.graphics.setColor(1, 1, 1, 1)
end

return ListMenu
