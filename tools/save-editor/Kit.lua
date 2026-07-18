-- Minimal immediate-mode, mouse-based UI kit for the save editor.
-- Call Kit.beginFrame(mx, my, clicked) once per love.draw() before using
-- any widget below; widgets read the frame's mouse state to decide hover
-- / click.

local Kit = {}
Kit.mouseX, Kit.mouseY = 0, 0
Kit.mouseClicked = false -- left button pressed this frame
Kit.hotField = nil
Kit.font = nil

function Kit.beginFrame(mx, my, clicked)
  Kit.mouseX, Kit.mouseY = mx, my
  Kit.mouseClicked = clicked
end

local function hit(x, y, w, h)
  return Kit.mouseX >= x and Kit.mouseX <= x + w
     and Kit.mouseY >= y and Kit.mouseY <= y + h
end

function Kit.label(x, y, text)
  love.graphics.setColor(0.9, 0.9, 0.9)
  love.graphics.print(text, x, y)
end

function Kit.button(x, y, w, h, label)
  local hover = hit(x, y, w, h)
  if hover then love.graphics.setColor(0.25, 0.35, 0.5)
  else love.graphics.setColor(0.15, 0.15, 0.18) end
  love.graphics.rectangle("fill", x, y, w, h, 4, 4)
  love.graphics.setColor(1, 1, 1)
  love.graphics.print(label, x + 8, y + h / 2 - 6)
  return hover and Kit.mouseClicked
end

function Kit.checkbox(x, y, checked, label)
  local on = Kit.button(x, y, 22, 22, checked and "X" or "")
  Kit.label(x + 28, y + 4, label)
  if on then return not checked, true end
  return checked, false
end

function Kit.list(x, y, w, h, items, selected, rowH)
  rowH = rowH or 22
  love.graphics.setColor(0.1, 0.1, 0.12)
  love.graphics.rectangle("fill", x, y, w, h)
  local clickedIndex = nil
  local maxRows = math.floor(h / rowH)
  for i = 1, math.min(#items, maxRows) do
    local ry = y + (i - 1) * rowH
    if i == selected then
      love.graphics.setColor(0.2, 0.4, 0.7)
      love.graphics.rectangle("fill", x, ry, w, rowH)
    end
    love.graphics.setColor(1, 1, 1)
    love.graphics.print(items[i], x + 6, ry + 4)
    if Kit.mouseClicked and hit(x, ry, w, rowH) then
      clickedIndex = i
    end
  end
  return clickedIndex
end

-- Tabs: returns new tab id if clicked
function Kit.tabs(x, y, tabs, current)
  local tx = x
  for _, t in ipairs(tabs) do
    local label = t.label
    local w = 8 * #label + 24
    local active = current == t.id
    love.graphics.setColor(active and 0.3 or 0.15, active and 0.45 or 0.15, active and 0.7 or 0.18)
    love.graphics.rectangle("fill", tx, y, w, 28, 4, 4)
    love.graphics.setColor(1, 1, 1)
    love.graphics.print(label, tx + 12, y + 7)
    if Kit.mouseClicked and hit(tx, y, w, 28) then
      return t.id
    end
    tx = tx + w + 4
  end
  return nil
end

return Kit
