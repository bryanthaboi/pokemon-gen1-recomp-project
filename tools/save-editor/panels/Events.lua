-- Events panel: flags, defeated trainers, taken items, and per-map object
-- visibility toggles. All four sections read/write directly into S.save so
-- edits show up immediately on the next Save.
--
-- Layout is a fixed grid (sub-tabs -> info row -> paged checkbox list ->
-- pagination/actions) so it stays predictable for both mouse hit-testing
-- and headless tests.

local M = {}

local ROW_H = 22
local VISIBLE_ROWS = 10

local SUB_TABS = {
  { id = "flags", label = "Flags" },
  { id = "trainers", label = "Trainers" },
  { id = "items", label = "Items taken" },
  { id = "toggles", label = "Object toggles" },
}

local function mark(S)
  S.dirty = true
end

local function sortedKeys(t)
  local keys = {}
  for k in pairs(t) do table.insert(keys, k) end
  table.sort(keys)
  return keys
end

local function contains(haystack, needle)
  if needle == "" then return true end
  return haystack:lower():find(needle:lower(), 1, true) ~= nil
end

-- Simple free-text capture for the flags filter field. Kit has no text
-- widget, so we edge-detect a-z/0-9/backspace against love.keyboard each
-- frame this panel is drawn (only while the Flags sub-tab is active).
local FILTER_KEYS = {}
for c = string.byte("a"), string.byte("z") do
  local ch = string.char(c)
  FILTER_KEYS[ch] = ch
end
for c = string.byte("0"), string.byte("9") do
  local ch = string.char(c)
  FILTER_KEYS[ch] = ch
end
FILTER_KEYS["-"] = "_"

local prevDown = {}

local function pollFilterInput(S)
  S.eventFilter = S.eventFilter or ""
  for key, ch in pairs(FILTER_KEYS) do
    local down = love.keyboard.isDown(key)
    if down and not prevDown[key] then
      S.eventFilter = S.eventFilter .. ch
    end
    prevDown[key] = down
  end
  local backspaceDown = love.keyboard.isDown("backspace")
  if backspaceDown and not prevDown.backspace then
    S.eventFilter = S.eventFilter:sub(1, -2)
  end
  prevDown.backspace = backspaceDown
end

local function clampScroll(S, total)
  S.eventsScroll = S.eventsScroll or 0
  local maxScroll = math.max(0, total - VISIBLE_ROWS)
  if S.eventsScroll > maxScroll then S.eventsScroll = maxScroll end
  if S.eventsScroll < 0 then S.eventsScroll = 0 end
  return S.eventsScroll
end

-- Draws up to VISIBLE_ROWS checkbox rows starting at rows[scroll+1], calling
-- onToggle(row, newChecked) when a row's box is clicked. `checkedOf(row)`
-- and `labelOf(row)` extract display state from whatever row shape the
-- caller uses (plain strings for Flags/Trainers/Items, tables for Toggles).
local function drawRows(S, Kit, x, listY, rows, scroll, checkedOf, labelOf, onToggle)
  for i = 1, math.min(VISIBLE_ROWS, #rows - scroll) do
    local row = rows[scroll + i]
    local ry = listY + (i - 1) * ROW_H
    local checked = checkedOf(row)
    if checked == nil then
      Kit.label(x + 28, ry + 4, labelOf(row))
    else
      local newChecked, changed = Kit.checkbox(x, ry, checked, labelOf(row))
      if changed then
        onToggle(row, newChecked)
      end
    end
  end
end

local function drawPager(S, Kit, x, y, total, scroll)
  local maxScroll = math.max(0, total - VISIBLE_ROWS)
  if Kit.button(x, y, 90, 26, "Prev") then
    S.eventsScroll = math.max(0, scroll - VISIBLE_ROWS)
  end
  if Kit.button(x + 100, y, 90, 26, "Next") then
    S.eventsScroll = math.min(maxScroll, scroll + VISIBLE_ROWS)
  end
  local shown = math.min(VISIBLE_ROWS, math.max(0, total - scroll))
  Kit.label(x + 210, y + 5, string.format("%d-%d of %d",
    total > 0 and scroll + 1 or 0, scroll + shown, total))
end

local function drawFlagsTab(S, Kit, x, y)
  pollFilterInput(S)

  Kit.label(x, y + 4, "Filter: " .. S.eventFilter .. "_")
  if Kit.button(x + 320, y, 110, 26, "Clear filter") then
    S.eventFilter = ""
  end

  local filtered = {}
  for _, name in ipairs(S.events or {}) do
    if contains(name, S.eventFilter) then
      table.insert(filtered, name)
    end
  end

  local listY = y + 32
  local scroll = clampScroll(S, #filtered)
  drawRows(S, Kit, x, listY, filtered, scroll,
    function(name) return S.save.flags[name] == true end,
    function(name) return name end,
    function(name, newChecked)
      S.save.flags[name] = newChecked and true or nil
      mark(S)
    end)

  drawPager(S, Kit, x, listY + VISIBLE_ROWS * ROW_H + 8, #filtered, scroll)
end

local function drawKeyToggleTab(S, Kit, x, y, note, tableKey, clearLabel)
  Kit.label(x, y + 4, note)

  S.save[tableKey] = S.save[tableKey] or {}
  local t = S.save[tableKey]
  local keys = sortedKeys(t)

  local listY = y + 32
  local scroll = clampScroll(S, #keys)
  drawRows(S, Kit, x, listY, keys, scroll,
    function(k) return t[k] == true end,
    function(k) return k end,
    function(k, newChecked)
      t[k] = newChecked
      mark(S)
    end)

  local pagerY = listY + VISIBLE_ROWS * ROW_H + 8
  drawPager(S, Kit, x, pagerY, #keys, scroll)
  if Kit.button(x + 400, pagerY, 190, 26, clearLabel) then
    S.save[tableKey] = {}
    mark(S)
  end
end

local function drawTogglesTab(S, Kit, x, y)
  Kit.label(x, y + 4, "Per-map object visibility overrides")

  S.save.objectToggles = S.save.objectToggles or {}
  local toggles = S.save.objectToggles

  local rows = {}
  for _, mapId in ipairs(sortedKeys(toggles)) do
    table.insert(rows, { header = true, mapId = mapId })
    for _, objName in ipairs(sortedKeys(toggles[mapId])) do
      table.insert(rows, { header = false, mapId = mapId, name = objName })
    end
  end

  local listY = y + 32
  local scroll = clampScroll(S, #rows)
  drawRows(S, Kit, x, listY, rows, scroll,
    function(row)
      if row.header then return nil end
      return toggles[row.mapId][row.name] == true
    end,
    function(row) return row.header and ("[" .. row.mapId .. "]") or row.name end,
    function(row, newChecked)
      toggles[row.mapId][row.name] = newChecked
      mark(S)
    end)

  drawPager(S, Kit, x, listY + VISIBLE_ROWS * ROW_H + 8, #rows, scroll)
end

function M.draw(S, Kit, x, y)
  S.eventFilter = S.eventFilter or ""
  S.eventsTab = S.eventsTab or "flags"

  Kit.label(x, y, "Events")

  local newTab = Kit.tabs(x, y + 24, SUB_TABS, S.eventsTab)
  if newTab then
    S.eventsTab = newTab
    S.eventsScroll = 0
  end

  local contentY = y + 64
  if S.eventsTab == "flags" then
    drawFlagsTab(S, Kit, x, contentY)
  elseif S.eventsTab == "trainers" then
    drawKeyToggleTab(S, Kit, x, contentY,
      "Keys look like MAP_obj_N (defeatedTrainers)",
      "defeatedTrainers", "Clear all trainers")
  elseif S.eventsTab == "items" then
    drawKeyToggleTab(S, Kit, x, contentY,
      "Keys look like MAP_obj_N (itemsTaken)",
      "itemsTaken", "Clear all items taken")
  elseif S.eventsTab == "toggles" then
    drawTogglesTab(S, Kit, x, contentY)
  end
end

return M
