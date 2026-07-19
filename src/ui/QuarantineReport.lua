-- Load-report screen (15-save-data D7.4): what the validation pass moved,
-- removed or remapped, shown once before the overworld.  Game:restoreSave
-- pushes it (Screens id "QuarantineReport") only when the report is
-- non-empty, so a vanilla load never constructs it.  Nothing here mutates
-- the save -- save.orphaned persists and the report stays re-derivable.

local Font = require("src.render.Font")
local SaveData = require("src.core.SaveData")

local QuarantineReport = {}
QuarantineReport.__index = QuarantineReport
QuarantineReport.isOpaque = true

local VISIBLE = 13   -- report rows on screen at once
local WIDTH = 18     -- text columns inside the border

local function clip(text)
  text = tostring(text)
  if #text > WIDTH then return text:sub(1, WIDTH) end
  return text
end

local function section(lines, header, rows)
  if #rows == 0 then return end
  if #lines > 0 then lines[#lines + 1] = "" end
  lines[#lines + 1] = header
  for _, row in ipairs(rows) do lines[#lines + 1] = clip(" " .. row) end
end

-- report shape: { lostMons = {{species, from}}, lostItems = {{id, count,
-- from}}, remappedMaps = {{id, to, field}}, restoredMons, restoredItems,
-- recovered, modsDiff }
local function buildLines(report, meta)
  local lines = {}
  if report.recovered then
    lines[#lines + 1] = "Save recovered from"
    lines[#lines + 1] = clip(" the ." .. tostring(report.recovered) .. " backup copy")
  end
  local rows = {}
  for _, mon in ipairs(report.lostMons or {}) do
    rows[#rows + 1] = ("%s (%s)"):format(mon.species or "?", mon.from or "?")
  end
  section(lines, "Moved to LOST box:", rows)
  rows = {}
  for _, item in ipairs(report.lostItems or {}) do
    rows[#rows + 1] = ("%s x%d"):format(item.id or "?", item.count or 1)
  end
  section(lines, "Items removed:", rows)
  rows = {}
  for _, map in ipairs(report.remappedMaps or {}) do
    if map.to then
      rows[#rows + 1] = ("%s>%s"):format(map.id or "?", map.to)
    else
      rows[#rows + 1] = ("%s (%s)"):format(map.id or "?", map.field or "?")
    end
  end
  section(lines, "Location reset:", rows)
  rows = {}
  for _, mon in ipairs(report.restoredMons or {}) do
    rows[#rows + 1] = ("%s to box %d"):format(mon.species or "?", mon.box or 0)
  end
  for _, item in ipairs(report.restoredItems or {}) do
    rows[#rows + 1] = ("%s x%d"):format(item.id or "?", item.count or 1)
  end
  section(lines, "Restored:", rows)
  local notice = SaveData.modsDiffNotice(report.modsDiff, meta)
  if notice then
    if #lines > 0 then lines[#lines + 1] = "" end
    -- wrap the one-line notice to the box width
    for word in notice:gmatch("%S+") do
      local last = lines[#lines]
      if last and last ~= "" and #last + #word + 1 <= WIDTH then
        lines[#lines] = last .. " " .. word
      else
        lines[#lines + 1] = word
      end
    end
  end
  return lines
end

function QuarantineReport.new(game, report)
  local self = setmetatable({
    game = game,
    report = report or {},
    offset = 0,
  }, QuarantineReport)
  self.lines = buildLines(self.report,
    game and game.save and game.save.meta)
  return self
end

function QuarantineReport:maxOffset()
  return math.max(0, #self.lines - VISIBLE)
end

function QuarantineReport:update()
  local input = self.game and self.game.input
  if not input then return end
  if input:wasPressed("up") then
    self.offset = math.max(0, self.offset - 1)
  elseif input:wasPressed("down") then
    self.offset = math.min(self:maxOffset(), self.offset + 1)
  elseif input:wasPressed("a") or input:wasPressed("start")
      or input:wasPressed("b") then
    -- CONTINUE: the overworld is already beneath this screen
    self.game.stack:pop()
  end
end

function QuarantineReport:draw()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 144)
  Font.drawBox(0, 0, 20, 18)
  love.graphics.setColor(0, 0, 0, 1)
  Font.draw("LOAD REPORT", 8, 8)
  for row = 1, VISIBLE do
    local line = self.lines[self.offset + row]
    if line then Font.draw(line, 8, 12 + row * 8) end
  end
  if self.offset < self:maxOffset() then
    Font.drawCode(require("src.ui.Theme").moreArrow, 144, 124)
  end
  Font.draw("A:CONTINUE", 8, 130)
  love.graphics.setColor(1, 1, 1, 1)
end

return QuarantineReport
