-- The widget toolkit as the stable mod-facing surface (mod.ui): the six
-- widgets plus TextBox, Font and Theme, the screen push, and the
-- descriptor-list helpers for the menu-injection hooks.  Widgets load on
-- first touch so a headless loader never drags the render stack in.

local ModUI = {}

local MODULES = {
  Menu = "src.ui.Menu",
  ListMenu = "src.ui.ListMenu",
  ChoiceBox = "src.ui.ChoiceBox",
  QuantityBox = "src.ui.QuantityBox",
  NamingScreen = "src.ui.NamingScreen",
  PicBox = "src.ui.PicBox",
  TextBox = "src.render.TextBox",
  Font = "src.render.Font",
  Theme = "src.ui.Theme",
}

setmetatable(ModUI, { __index = function(t, key)
  local path = MODULES[key]
  if not path then return nil end
  local module = require(path)
  rawset(t, key, module)
  return module
end })

function ModUI.push(game, id, ...)
  return require("src.ui.Screens").push(game, id, ...)
end

local function indexOf(items, label)
  for i, item in ipairs(items) do
    if item.label == label then return i end
  end
  return nil
end

-- anchored on stable labels so mods place entries without counting rows;
-- a missing anchor appends, which keeps the entry reachable either way
function ModUI.insertBefore(items, anchorLabel, item)
  local i = indexOf(items, anchorLabel)
  table.insert(items, i or (#items + 1), item)
  return items
end

function ModUI.insertAfter(items, anchorLabel, item)
  local i = indexOf(items, anchorLabel)
  table.insert(items, i and (i + 1) or (#items + 1), item)
  return items
end

function ModUI.removeLabel(items, label)
  for i = #items, 1, -1 do
    if items[i].label == label then table.remove(items, i) end
  end
  return items
end

return ModUI
