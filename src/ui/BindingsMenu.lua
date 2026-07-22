-- Rebinding over the logical Game Boy buttons (gap C2's file-12 half,
-- 12-ui-extensibility 4.4): one row per button, A arms a "PRESS A BUTTON"
-- capture and the captured key or pad button lands in
-- save.options.bindings, which Input:applyBindings layers over its fixed
-- default map (see src/core/Input.lua and Game:applyOptions).

local Font = require("src.render.Font")
local ListMenu = require("src.ui.ListMenu")
local Input = require("src.core.Input")

local BindingsMenu = setmetatable({}, { __index = ListMenu })
BindingsMenu.__index = BindingsMenu

-- Input.lua's map, primary key first where several keys share a button
local BUTTONS = {
  { id = "up", label = "UP", key = "up" },
  { id = "down", label = "DOWN", key = "down" },
  { id = "left", label = "LEFT", key = "left" },
  { id = "right", label = "RIGHT", key = "right" },
  { id = "a", label = "A", key = "z" },
  { id = "b", label = "B", key = "x" },
  { id = "start", label = "START", key = "escape" },
  { id = "select", label = "SELECT", key = "rshift" },
}

-- a binding is a plain key string or { key, pad }; absent = the fixed
-- map, so a vanilla save renders today's keys byte-identically
local function boundKey(overlay, def)
  local b = overlay and overlay[def.id]
  if type(b) == "table" then return b.key or def.key end
  if type(b) == "string" then return b end
  return def.key
end

function BindingsMenu.new(game)
  local overlay = game.save and game.save.options
                  and game.save.options.bindings
  local items = {}
  for i, def in ipairs(BUTTONS) do
    items[i] = { label = def.label,
                 right = boundKey(overlay, def):upper(), button = def }
  end
  local self = setmetatable(ListMenu.new(game, "CONTROLS", items, {}),
                            BindingsMenu)
  self.onChoose = function(item) self:beginCapture(item) end
  return self
end

-- the capture handlers are per-instance slots, so Game's raw-input
-- routing only ever sees this screen while a capture is armed
function BindingsMenu:beginCapture(item)
  self.capture = item
  self.onKeyPressed = BindingsMenu.captureKey
  self.onGamepadPressed = BindingsMenu.capturePad
end

function BindingsMenu:captureKey(key)
  self:storeBinding("key", key)
end

function BindingsMenu:capturePad(button)
  self:storeBinding("pad", button)
end

function BindingsMenu:storeBinding(slot, value)
  local item = self.capture
  self.capture = nil
  self.onKeyPressed = nil
  self.onGamepadPressed = nil
  local game = self.game
  if not (item and value and game.save and game.save.options) then return end
  local opts = game.save.options
  opts.bindings = opts.bindings or {}
  local b = opts.bindings[item.button.id]
  if type(b) ~= "table" then
    -- keep a direct-edited plain key string when only the pad changes
    b = { key = type(b) == "string" and b or nil }
  end
  b[slot] = value
  opts.bindings[item.button.id] = b
  item.right = boundKey(opts.bindings, item.button):upper()
  Input:applyBindings(opts.bindings)
  if game.writeOptions then game:writeOptions() end
end

function BindingsMenu:update(dt)
  if self.capture then return end -- the raw capture owns the input
  ListMenu.update(self, dt)
end

function BindingsMenu:draw()
  ListMenu.draw(self)
  if self.capture then
    Font.drawBox(1, 6, 18, 4)
    love.graphics.setColor(0, 0, 0, 1)
    Font.draw("PRESS A BUTTON", 24, 60)
    love.graphics.setColor(1, 1, 1, 1)
  end
end

return BindingsMenu
