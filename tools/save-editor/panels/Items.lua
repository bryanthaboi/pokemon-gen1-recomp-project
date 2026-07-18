-- Items panel: money, the 20-slot bag (Bag.add/remove, ordered by
-- Bag.order), gym badges (boolean flags on inventory), and PC Item
-- storage (a plain S.save.pcItems dict, created on first use).

local Bag = require("src.inventory.Bag")

local M = {}

local ROW_H = 20
local LIST_H = 200
local VISIBLE_ROWS = math.floor(LIST_H / ROW_H)

local function mark(S)
  S.dirty = true
end

-- Prev/Next pagination (mirrors Events/Dex panels) so bag/PC lists longer
-- than VISIBLE_ROWS stay fully reachable instead of truncating silently.
local function clampScroll(scroll, total)
  local maxScroll = math.max(0, total - VISIBLE_ROWS)
  scroll = scroll or 0
  if scroll > maxScroll then scroll = maxScroll end
  if scroll < 0 then scroll = 0 end
  return scroll
end

local function pageSlice(items, scroll)
  local page = {}
  for i = 1, math.min(VISIBLE_ROWS, #items - scroll) do
    page[i] = items[scroll + i]
  end
  return page
end

local function drawPager(Kit, x, y, total, scroll, onPrev, onNext)
  if Kit.button(x, y, 90, 26, "Prev") then onPrev() end
  if Kit.button(x + 100, y, 90, 26, "Next") then onNext() end
  local shown = math.min(VISIBLE_ROWS, math.max(0, total - scroll))
  Kit.label(x + 210, y + 5, string.format("%d-%d of %d",
    total > 0 and scroll + 1 or 0, scroll + shown, total))
end

local function clamp(n, lo, hi)
  if n < lo then return lo end
  if n > hi then return hi end
  return n
end

local function isBadgeId(id)
  return id:find("BADGE", 1, true) ~= nil
end

local function badgeIds(cat)
  local ids = {}
  for _, id in ipairs(cat.items) do
    if isBadgeId(id) then table.insert(ids, id) end
  end
  return ids
end

local function bagLines(save)
  local order = Bag.order(save)
  local lines = {}
  for i, id in ipairs(order) do
    lines[i] = string.format("%-16s x%d", id, save.inventory[id] or 0)
  end
  return lines, order
end

local function pcItemOrder(pcItems)
  local ids = {}
  for id in pairs(pcItems) do table.insert(ids, id) end
  table.sort(ids)
  return ids
end

local function pcLines(pcItems, order)
  local lines = {}
  for i, id in ipairs(order) do
    lines[i] = string.format("%-16s x%d", id, pcItems[id] or 0)
  end
  return lines
end

local function pcAdd(save, id, qty)
  save.pcItems = save.pcItems or {}
  local pc = save.pcItems
  pc[id] = math.min(99, (pc[id] or 0) + (qty or 1))
end

local function pcRemove(save, id, qty)
  local pc = save.pcItems
  if not pc or not pc[id] then return end
  pc[id] = pc[id] - (qty or 1)
  if pc[id] <= 0 then pc[id] = nil end
end

function M.draw(S, Kit, x, y)
  S.save.pcItems = S.save.pcItems or {}

  -- Money
  Kit.label(x, y, "Money: $" .. tostring(S.save.money))
  local moneyBtnY = y + 22
  if Kit.button(x, moneyBtnY, 60, 26, "-100") then
    S.save.money = clamp(S.save.money - 100, 0, 999999); mark(S)
  end
  if Kit.button(x + 66, moneyBtnY, 60, 26, "-10") then
    S.save.money = clamp(S.save.money - 10, 0, 999999); mark(S)
  end
  if Kit.button(x + 132, moneyBtnY, 60, 26, "+10") then
    S.save.money = clamp(S.save.money + 10, 0, 999999); mark(S)
  end
  if Kit.button(x + 198, moneyBtnY, 60, 26, "+100") then
    S.save.money = clamp(S.save.money + 100, 0, 999999); mark(S)
  end

  -- Item picker (species-like picker over S.cat.items) shared by bag/PC add
  local pickerY = moneyBtnY + 40
  S.itemPickerIdx = clamp(S.itemPickerIdx or 1, 1, #S.cat.items)
  local pickId = S.cat.items[S.itemPickerIdx]
  Kit.label(x, pickerY + 5, "Item:")
  if Kit.button(x + 46, pickerY, 26, 26, "<") then
    S.itemPickerIdx = ((S.itemPickerIdx - 2) % #S.cat.items) + 1
  end
  Kit.label(x + 82, pickerY + 5, pickId)
  if Kit.button(x + 280, pickerY, 26, 26, ">") then
    S.itemPickerIdx = (S.itemPickerIdx % #S.cat.items) + 1
  end
  if Kit.button(x + 320, pickerY, 110, 26, "Add to Bag") then
    if Bag.add(S.save, pickId, 1) then mark(S) end
  end
  if Kit.button(x + 440, pickerY, 110, 26, "Add to PC") then
    pcAdd(S.save, pickId, 1); mark(S)
  end

  -- Bag list
  local bagLabelY = pickerY + 40
  Kit.label(x, bagLabelY, string.format("Bag (%d/%d slots)", Bag.slots(S.save), Bag.CAPACITY))
  local bagListY = bagLabelY + 20
  local lines, order = bagLines(S.save)
  S.selectedBagIdx = clamp(S.selectedBagIdx or 1, 1, math.max(#order, 1))
  S.bagScroll = clampScroll(S.bagScroll, #order)
  local bagClick = Kit.list(x, bagListY, 300, LIST_H, pageSlice(lines, S.bagScroll),
    S.selectedBagIdx - S.bagScroll, ROW_H)
  if bagClick then S.selectedBagIdx = S.bagScroll + bagClick end

  local bagPagerY = bagListY + LIST_H + 8
  drawPager(Kit, x, bagPagerY, #order, S.bagScroll,
    function() S.bagScroll = clampScroll(S.bagScroll - VISIBLE_ROWS, #order) end,
    function() S.bagScroll = clampScroll(S.bagScroll + VISIBLE_ROWS, #order) end)

  local bagActionsY = bagPagerY + 34
  if Kit.button(x, bagActionsY, 100, 28, "Remove 1") then
    local id = order[S.selectedBagIdx]
    if id then
      Bag.remove(S.save, id, 1)
      S.selectedBagIdx = clamp(S.selectedBagIdx, 1, math.max(#Bag.order(S.save), 1))
      mark(S)
    end
  end
  if Kit.button(x + 110, bagActionsY, 100, 28, "Remove all") then
    local id = order[S.selectedBagIdx]
    if id then
      Bag.remove(S.save, id, S.save.inventory[id])
      S.selectedBagIdx = clamp(S.selectedBagIdx, 1, math.max(#Bag.order(S.save), 1))
      mark(S)
    end
  end

  -- PC items list (mirrors bag UX; plain dict, no slot cap)
  local pcLabelY = bagActionsY + 40
  local pcOrder = pcItemOrder(S.save.pcItems)
  Kit.label(x, pcLabelY, string.format("PC Items (%d kinds)", #pcOrder))
  local pcListY = pcLabelY + 20
  S.selectedPcIdx = clamp(S.selectedPcIdx or 1, 1, math.max(#pcOrder, 1))
  S.pcScroll = clampScroll(S.pcScroll, #pcOrder)
  local pcClick = Kit.list(x, pcListY, 300, LIST_H,
    pageSlice(pcLines(S.save.pcItems, pcOrder), S.pcScroll),
    S.selectedPcIdx - S.pcScroll, ROW_H)
  if pcClick then S.selectedPcIdx = S.pcScroll + pcClick end

  local pcPagerY = pcListY + LIST_H + 8
  drawPager(Kit, x, pcPagerY, #pcOrder, S.pcScroll,
    function() S.pcScroll = clampScroll(S.pcScroll - VISIBLE_ROWS, #pcOrder) end,
    function() S.pcScroll = clampScroll(S.pcScroll + VISIBLE_ROWS, #pcOrder) end)

  local pcActionsY = pcPagerY + 34
  if Kit.button(x, pcActionsY, 100, 28, "Remove 1") then
    local id = pcOrder[S.selectedPcIdx]
    if id then
      pcRemove(S.save, id, 1)
      pcOrder = pcItemOrder(S.save.pcItems)
      S.selectedPcIdx = clamp(S.selectedPcIdx, 1, math.max(#pcOrder, 1))
      mark(S)
    end
  end
  if Kit.button(x + 110, pcActionsY, 100, 28, "Remove all") then
    local id = pcOrder[S.selectedPcIdx]
    if id then
      pcRemove(S.save, id, S.save.pcItems[id])
      pcOrder = pcItemOrder(S.save.pcItems)
      S.selectedPcIdx = clamp(S.selectedPcIdx, 1, math.max(#pcOrder, 1))
      mark(S)
    end
  end

  -- Badges: boolean flags directly on inventory, toggled by click
  local badgeLabelY = pcActionsY + 40
  Kit.label(x, badgeLabelY, "Badges (click to toggle)")
  local badgeY = badgeLabelY + 20
  local ids = badgeIds(S.cat)
  for i, id in ipairs(ids) do
    local col = (i - 1) % 4
    local row = math.floor((i - 1) / 4)
    local bx = x + col * 150
    local by = badgeY + row * 30
    local on = S.save.inventory[id] == true
    if Kit.button(bx, by, 144, 26, id .. (on and " [X]" or "")) then
      if on then S.save.inventory[id] = nil else S.save.inventory[id] = true end
      mark(S)
    end
  end
end

return M
