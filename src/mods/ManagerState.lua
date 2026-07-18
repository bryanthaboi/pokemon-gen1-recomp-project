-- Built-in mod manager using the same tile boxes, cursor, spacing, and
-- navigation language as the game's START menu.
local Font = require("src.render.Font")

local ManagerState = {}
ManagerState.__index = ManagerState
ManagerState.isOpaque = true

local CURSOR = 0xED
local DOWN_ARROW = 0xEE

local function wrap(text, width)
  local lines = {}
  for paragraph in tostring(text or ""):gmatch("[^\n]+") do
    local line = ""
    for word in paragraph:gmatch("%S+") do
      while #word > width do
        if line ~= "" then
          lines[#lines + 1] = line
          line = ""
        end
        lines[#lines + 1] = word:sub(1, width)
        word = word:sub(width + 1)
      end
      if word ~= "" then
        local candidate = line == "" and word or line .. " " .. word
        if #candidate > width and line ~= "" then
          lines[#lines + 1] = line
          line = word
        else
          line = candidate
        end
      end
    end
    if line ~= "" then lines[#lines + 1] = line end
  end
  if #lines == 0 then lines[1] = "" end
  return lines
end

function ManagerState.new(game)
  return setmetatable({
    game = game,
    mode = "categories",
    categoryIndex = 1,
    modIndex = 1,
    scroll = 1,
    restartPending = false,
  }, ManagerState)
end

function ManagerState:enter()
  self:rebuildCategories()
end

function ManagerState:rebuildCategories()
  local status = self.game.modStatus or { available = {} }
  self.categories = {}
  self.byCategory = {}
  for _, manifest in ipairs(status.available or {}) do
    local category = manifest.category or "OTHER"
    self.byCategory[category] = self.byCategory[category] or {}
    self.byCategory[category][#self.byCategory[category] + 1] = manifest
  end
  for category in pairs(self.byCategory) do
    self.categories[#self.categories + 1] = category
  end
  table.sort(self.categories)
  self.categoryIndex = math.min(self.categoryIndex, math.max(1, #self.categories))
end

function ManagerState:currentMods()
  return self.byCategory[self.categories[self.categoryIndex]] or {}
end

function ManagerState:currentMod()
  return self:currentMods()[self.modIndex]
end

function ManagerState:openCategory()
  self.mode = "mods"
  self.modIndex = 1
end

function ManagerState:openMod()
  self.mode = "detail"
  self.scroll = 1
end

function ManagerState:toggleCurrent()
  local manifest = self:currentMod()
  if not manifest then return end
  self.game.mods:setEnabled(manifest.id, not manifest.enabled)
  self.game.modStatus = self.game.mods:status()
  self.restartPending = true
  self:rebuildCategories()
  for _, candidate in ipairs(self:currentMods()) do
    if candidate.id == manifest.id then
      self.modIndex = _
      break
    end
  end
  self.mode = "detail"
end

function ManagerState:restartGame()
  if self.game.restartWithMods then
    self.game:restartWithMods()
  elseif love.event and love.event.quit then
    love.event.quit("restart")
  end
end

function ManagerState:back()
  if self.mode == "detail" then
    self.mode = "mods"
  elseif self.mode == "mods" then
    self.mode = "categories"
  else
    self.game.stack:pop()
  end
end

function ManagerState:onKeyPressed(key)
  local activate = key == "return" or key == "kpenter" or key == "z"
                  or key == "space"
  if key == "escape" or key == "f10" or key == "x" or key == "backspace" then
    self:back()
    return
  end
  if self.mode == "categories" then
    if key == "up" and #self.categories > 0 then
      self.categoryIndex = self.categoryIndex > 1 and self.categoryIndex - 1 or #self.categories
    elseif key == "down" and #self.categories > 0 then
      self.categoryIndex = self.categoryIndex < #self.categories and self.categoryIndex + 1 or 1
    elseif activate and #self.categories > 0 then
      self:openCategory()
    end
  elseif self.mode == "mods" then
    local mods = self:currentMods()
    if key == "up" and #mods > 0 then
      self.modIndex = self.modIndex > 1 and self.modIndex - 1 or #mods
    elseif key == "down" and #mods > 0 then
      self.modIndex = self.modIndex < #mods and self.modIndex + 1 or 1
    elseif activate and #mods > 0 then
      self:openMod()
    end
  else
    if key == "up" then self.scroll = math.max(1, self.scroll - 1)
    elseif key == "down" then self.scroll = self.scroll + 1
    elseif activate then
      if self.restartPending then self:restartGame()
      else self:toggleCurrent() end
    end
  end
end

function ManagerState:update() end

local function drawList(items, index, tx, ty, tw, th)
  local visible = math.max(1, math.floor((th - 2) / 2))
  local first = math.max(1, index - visible + 1)
  local y = ty + 1
  for itemIndex = first, math.min(#items, first + visible - 1) do
    local itemLines = wrap(items[itemIndex], tw - 2)
    if itemIndex == index then
      Font.drawCode(CURSOR, (tx + 1) * 8, y * 8)
    end
    for lineIndex = 1, math.min(2, #itemLines) do
      Font.draw(itemLines[lineIndex], (tx + 2) * 8,
        (y + lineIndex - 1) * 8)
    end
    y = y + 2
  end
  if #items > first + visible - 1 then
    Font.drawCode(DOWN_ARROW, (tx + tw - 2) * 8, (ty + th - 1) * 8)
  end
end

function ManagerState:drawDetail(manifest)
  local title = wrap(manifest.name, 16)
  Font.draw(title[1], 2 * 8, 4 * 8)
  Font.draw(manifest.enabled and "ENABLED" or "DISABLED", 3 * 8, 6 * 8)
  local lines = wrap(manifest.description, 16)
  -- Rows 8-12 are description, row 13 is deliberately blank, and row 14
  -- is the option/restart action.
  local visible = 5
  for row = 1, visible do
    local line = lines[self.scroll + row - 1]
    if not line then break end
    Font.draw(line, 2 * 8, (7 + row) * 8)
  end
  if self.scroll + visible <= #lines then
    Font.drawCode(DOWN_ARROW, 17 * 8, 12 * 8)
  end
  if self.restartPending then
    Font.draw("RESTART REQUIRED", 2 * 8, 14 * 8)
    Font.draw("A:RESTART", 11 * 8, 15 * 8)
  else
    Font.draw(manifest.enabled and "DISABLE" or "ENABLE", 2 * 8, 14 * 8)
    Font.draw("A:CHANGE", 11 * 8, 15 * 8)
  end
end

function ManagerState:draw()
  love.graphics.setColor(0, 0, 0, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 144)
  love.graphics.setColor(1, 1, 1, 1)
  Font.drawBox(0, 0, 20, 18)
  Font.draw("MOD MENU", 2 * 8, 1 * 8)

  if self.mode == "detail" then
    self:drawDetail(self:currentMod())
    return
  end

  local categoryItems = {}
  for _, category in ipairs(self.categories) do
    categoryItems[#categoryItems + 1] = category
  end
  if #categoryItems == 0 then categoryItems[1] = "NO MODS" end
  if self.mode == "categories" then
    drawList(categoryItems, self.categoryIndex, 1, 4, 18, 11)
    Font.draw("A:OPEN", 2 * 8, 16 * 8)
    Font.draw("B:BACK", 12 * 8, 16 * 8)
    return
  end

  if self.mode == "mods" then
    local mods = self:currentMods()
    local labels = {}
    for _, manifest in ipairs(mods) do
      labels[#labels + 1] = (manifest.enabled and "" or "*") .. manifest.name
    end
    Font.draw(self.categories[self.categoryIndex] or "MODS", 2 * 8, 4 * 8)
    drawList(labels, self.modIndex, 1, 6, 18, 9)
    Font.draw("A:OPEN", 2 * 8, 16 * 8)
    Font.draw("B:BACK", 12 * 8, 16 * 8)
  end
end

return ManagerState
