-- Gen 1 letter-grid naming screen (engine/menus/naming_screen.asm).
-- Full gen-1 glyph grid (data/text/alphabets.asm): five 9-cell rows
-- ending in ED, plus a case-switch row.  A picks a letter, B deletes,
-- SELECT flips case, START or the ED cell confirms.  If opts.presets is
-- given, a "NEW NAME" + presets menu is shown first
-- (engine/menus/main_menu.asm name lists).
-- Pops itself from the stack, then calls opts.onDone(name).

local Font = require("src.render.Font")
local Sound = require("src.core.Sound")
local Theme = require("src.ui.Theme")

local NamingScreen = {}
NamingScreen.__index = NamingScreen
NamingScreen.isOpaque = true

-- SGB: generic whole-screen palette (SET_PAL_GENERIC)
function NamingScreen:sgbPalettes(game)
  return require("src.render.PaletteFX").wholeNamed(game.data, "MEWMON")
end

-- both letter pages (wAlphabetCase, data/text/alphabets.asm): row 6 is
-- the case-switch cell, labelled with the page it flips to
local GRID_UPPER = {
  { "A", "B", "C", "D", "E", "F", "G", "H", "I" },
  { "J", "K", "L", "M", "N", "O", "P", "Q", "R" },
  { "S", "T", "U", "V", "W", "X", "Y", "Z", " " },
  { "×", "(", ")", ":", ";", "[", "]", "<PK>", "<MN>" },
  { "-", "?", "!", "♂", "♀", "/", ".", ",", "ED" },
  { "lower case" },
}
local GRID_LOWER = {
  { "a", "b", "c", "d", "e", "f", "g", "h", "i" },
  { "j", "k", "l", "m", "n", "o", "p", "q", "r" },
  { "s", "t", "u", "v", "w", "x", "y", "z", " " },
  { "×", "(", ")", ":", ";", "[", "]", "<PK>", "<MN>" },
  { "-", "?", "!", "♂", "♀", "/", ".", ",", "ED" },
  { "UPPER CASE" },
}
local CASE_ROW = 6
local ED_ROW, ED_COL = 5, 9

function NamingScreen.new(game, opts)
  opts = opts or {}
  local self = setmetatable({}, NamingScreen)
  self.game = game
  self.title = opts.title or "YOUR NAME?"
  self.presets = opts.presets
  self.maxLen = opts.maxLen or 7
  self.default = opts.default
  self.onDone = opts.onDone
  self.glyphs = {} -- typed glyphs; multi-byte cells (<PK>, ♂, ×) count as 1
  self.row, self.col = 1, 1
  self.lower = false
  return self
end

function NamingScreen:enter()
  if self.presets and #self.presets > 0 then
    local Menu = require("src.ui.Menu")
    local items = { { label = "NEW NAME" } }
    for _, preset in ipairs(self.presets) do
      table.insert(items, {
        label = preset,
        onSelect = function()
          -- the menu already popped itself; pop the naming screen too
          self.game.stack:pop()
          if self.onDone then self.onDone(preset) end
        end,
      })
    end
    self.game.stack:push(Menu.new(self.game, items, {
      tx = 4, ty = 0, tw = 12, th = #items * 2 + 2, cancelable = false,
    }))
  end
end

function NamingScreen:confirm()
  local name = table.concat(self.glyphs)
  if name == "" then
    name = (self.presets and self.presets[1]) or self.default or "A"
  end
  Sound.play(self.game.data, "Press_AB")
  self.game.stack:pop()
  if self.onDone then self.onDone(name) end
end

function NamingScreen:grid()
  return self.lower and GRID_LOWER or GRID_UPPER
end

-- Gen 1 jumps the cursor to ED once the name is full.
function NamingScreen:jumpToEnd()
  self.row, self.col = ED_ROW, ED_COL
end

function NamingScreen:update(dt)
  local GRID = self:grid()
  local input = self.game.input
  if input:wasPressed("start") then
    self:confirm()
    return
  end
  if input:wasPressed("select") then -- SELECT also flips the case page
    self.lower = not self.lower
    return
  end
  if input:wasPressed("up") then
    -- wrapping up from the top row lands on the case-switch cell
    self.row = self.row > 1 and self.row - 1 or CASE_ROW
    self.col = math.min(self.col, #GRID[self.row])
  elseif input:wasPressed("down") then
    self.row = self.row < #GRID and self.row + 1 or 1
    self.col = math.min(self.col, #GRID[self.row])
  elseif input:wasPressed("left") then
    -- no horizontal movement on the case-switch row
    if self.row ~= CASE_ROW then
      self.col = self.col > 1 and self.col - 1 or #GRID[self.row]
    end
  elseif input:wasPressed("right") then
    if self.row ~= CASE_ROW then
      self.col = self.col < #GRID[self.row] and self.col + 1 or 1
    end
  elseif input:wasPressed("b") then
    table.remove(self.glyphs)
  elseif input:wasPressed("a") then
    if self.row == ED_ROW and self.col == ED_COL then
      self:confirm()
      return
    end
    if self.row == CASE_ROW then
      self.lower = not self.lower
      return
    end
    if #self.glyphs < self.maxLen then
      Sound.play(self.game.data, "Press_AB")
      table.insert(self.glyphs, GRID[self.row][self.col])
      if #self.glyphs >= self.maxLen then self:jumpToEnd() end
    end
  end
end

function NamingScreen:draw()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 144)
  love.graphics.setColor(0, 0, 0, 1)
  Font.draw(self.title, 8, 8)
  -- typed name with dashes for the empty slots
  for i = 1, self.maxLen do
    Font.draw(self.glyphs[i] or "-", 56 + (i - 1) * 8, 24)
  end
  for r, row in ipairs(self:grid()) do
    for c, cell in ipairs(row) do
      Font.draw(cell, c * 16, 32 + r * 16)
    end
  end
  Font.drawCode(Theme.cursor, self.col * 16 - 8, 32 + self.row * 16)
  love.graphics.setColor(1, 1, 1, 1)
end

return NamingScreen
