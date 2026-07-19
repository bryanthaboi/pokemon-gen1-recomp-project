-- The four-box options viewport, extracted from OptionsMenu so the mod
-- manager's per-mod options auto-UI renders schemas in the same idiom.
-- Rows are descriptors:
--   { id, label, value = fn(game) -> string,
--     step = fn(game, dir) -> changed, activate = fn(game) }
-- step handles Left/Right/A cyclers; activate is the A-press action for
-- rows that open something instead (MODS, CANCEL stays the caller's).

local Font = require("src.render.Font")
local Theme = require("src.ui.Theme")

local OptionRows = {}

OptionRows.VISIBLE = 4 -- option boxes on screen at once (4 tiles each)

-- keep the cursor's box inside the viewport; the fixed bottom row shows
-- the tail of the list
function OptionRows.clampScroll(index, scroll, total, bottomRow)
  if bottomRow and index >= bottomRow then
    return math.max(0, total - OptionRows.VISIBLE)
  elseif index <= scroll then
    return index - 1
  elseif index > scroll + OptionRows.VISIBLE then
    return index - OptionRows.VISIBLE
  end
  return scroll
end

-- one bordered box per row, label line + value line, with the fixed
-- bottom line below (CANCEL in the options menu, the manager's footer)
function OptionRows.draw(game, rows, index, scroll, bottomLabel, bottomRow)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 144)
  for slot = 1, OptionRows.VISIBLE do
    local i = scroll + slot
    local row = rows[i]
    if not row then break end
    Font.drawBox(0, (slot - 1) * 4, 20, 4)
    love.graphics.setColor(0, 0, 0, 1)
    Font.draw(row.label, 16, ((slot - 1) * 4 + 1) * 8)
    Font.draw(row.value and row.value(game) or "", 24, ((slot - 1) * 4 + 2) * 8)
    if i == index then
      Font.drawCode(Theme.cursor, 8, ((slot - 1) * 4 + 1) * 8)
    end
  end
  if scroll + OptionRows.VISIBLE < #rows then
    Font.drawCode(Theme.moreArrow, 144, 128)
  end
  if bottomLabel then
    love.graphics.setColor(0, 0, 0, 1)
    Font.draw(bottomLabel, 16, 136)
    if bottomRow and index == bottomRow then
      Font.drawCode(Theme.cursor, 8, 136)
    end
  end
  love.graphics.setColor(1, 1, 1, 1)
end

return OptionRows
