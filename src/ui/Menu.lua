-- Generic bordered list menu with the blinking ▶ cursor.
-- items: { { label=..., onSelect=function }, ... }
-- Pops itself on B (unless cancelable=false); also on START only when
-- opts.startCloses is set -- pokered's wMenuWatchedKeys mask varies per
-- menu and only the start menu's adds PAD_START.

local Font = require("src.render.Font")

local Menu = {}
Menu.__index = Menu

local CURSOR = 0xED -- "▶" glyph (right arrow) in font.png

function Menu.new(game, items, opts)
  local self = setmetatable({}, Menu)
  opts = opts or {}
  self.game = game
  self.items = items
  self.index = 1
  self.tx = opts.tx or 10
  self.ty = opts.ty or 0
  self.tw = opts.tw or 10
  self.th = opts.th or (#items * 2 + 2)
  self.cancelable = opts.cancelable ~= false
  -- Whether START closes the menu.  In pokered a menu responds only to the
  -- keys in its wMenuWatchedKeys mask; the common PAD_A | PAD_B (and the
  -- list menu's PAD_A | PAD_B | PAD_SELECT) masks leave START unwatched, so
  -- only menus whose real mask includes PAD_START -- the start menu
  -- (engine/menus/draw_start_menu.asm) -- opt in here.
  self.startCloses = opts.startCloses or false
  self.onCancel = opts.onCancel
  -- BIT_NO_MENU_BUTTON_SOUND (wMiscFlags): the PC session runs its
  -- menus silent (home/window.asm HandleMenuInput_)
  self.noSound = opts.noSound or false
  return self
end

function Menu:update(dt)
  local input = self.game.input
  if input:wasPressed("up") then
    self.index = self.index > 1 and self.index - 1 or #self.items
  elseif input:wasPressed("down") then
    self.index = self.index < #self.items and self.index + 1 or 1
  elseif input:wasPressed("a") then
    -- HandleMenuInput_ (home/window.asm): SFX_PRESS_AB on every A press
    if not self.noSound then
      require("src.core.Sound").play(self.game.data, "Press_AB")
    end
    local item = self.items[self.index]
    -- keepOpen entries run without closing the menu (e.g. the
    -- Pokédex CRY option keeps the side menu up)
    if not item.keepOpen then self.game.stack:pop() end
    if item.onSelect then item.onSelect() end
  elseif self.cancelable and (input:wasPressed("b")
      or (self.startCloses and input:wasPressed("start"))) then
    -- HandleMenuInput_ returns for any watched key, but only replays
    -- SFX_PRESS_AB for the PAD_A | PAD_B branch -- so B beeps and START
    -- (when watched, e.g. the start menu) closes silently.
    if input:wasPressed("b") and not self.noSound then
      require("src.core.Sound").play(self.game.data, "Press_AB")
    end
    self.game.stack:pop()
    if self.onCancel then self.onCancel() end
  end
end

function Menu:draw()
  Font.drawBox(self.tx, self.ty, self.tw, self.th)
  love.graphics.setColor(0, 0, 0, 1)
  for i, item in ipairs(self.items) do
    Font.draw(item.label, (self.tx + 2) * 8, (self.ty + i * 2 - 1) * 8)
  end
  Font.drawCode(CURSOR, (self.tx + 1) * 8, (self.ty + self.index * 2 - 1) * 8)
  love.graphics.setColor(1, 1, 1, 1)
end

return Menu
