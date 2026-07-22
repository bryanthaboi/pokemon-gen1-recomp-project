local RomImporter = {}
RomImporter.__index = RomImporter

local ROM_SHA1 = "ea9bcae617fdf159b045185467ae58b2e4a48b9a"
local CACHE_MARKER = "rom-cache-v6:" .. ROM_SHA1
local MARKER_PATH = "rom-cache.complete"
local COMMUNITY_URL = "https://bois.icu"
local TRUST_WARNING = "if you did not get this from bryanthaboi's github " ..
  "or a link from the discord that bryanthaboi himself posted, just know " ..
  "it might have been tampered with. go to the discord to verify " ..
  COMMUNITY_URL .. " (or click the logo above)"
local REQUIRED_FILES = {
  "data/generated/constants.lua",
  "data/generated/maps.lua",
  "data/generated/text.lua",
  "data/generated/field.lua",
  "data/generated/battle_anims.lua",
  "assets/generated/title/pokemon_logo.png",
  "assets/generated/fonts/font.png",
  "assets/generated/battle/front/pikachu.png",
  "assets/generated/battle/anims/move_anim_0.png",
  "assets/generated/battle/anims/move_anim_1.png",
  "assets/generated/audio/programs.bin",
}

local function allRequiredFilesExist()
  for _, path in ipairs(REQUIRED_FILES) do
    if not love.filesystem.getInfo(path, "file") then return false end
  end
  return true
end

local function sourceTreeHasData()
  if not allRequiredFilesExist() or not love.filesystem.getRealDirectory then
    return false
  end
  local real = love.filesystem.getRealDirectory(REQUIRED_FILES[1])
  return real == love.filesystem.getSource()
end

function RomImporter.isReady()
  if sourceTreeHasData() then return true end
  return love.filesystem.read(MARKER_PATH) == CACHE_MARKER
    and allRequiredFilesExist()
end

local function removeTree(path)
  local info = love.filesystem.getInfo(path)
  if not info then return end
  if info.type == "directory" then
    for _, child in ipairs(love.filesystem.getDirectoryItems(path)) do
      removeTree(path .. "/" .. child)
    end
  end
  if love.filesystem.getRealDirectory
      and love.filesystem.getRealDirectory(path)
        ~= love.filesystem.getSaveDirectory() then
    return
  end
  local ok, err = love.filesystem.remove(path)
  if ok == false then
    error("could not remove stale cache: " .. tostring(err))
  end
end

local function decodeManifest()
  local raw, readError = love.filesystem.read("tools/rom_manifest.json")
  if not raw then error("ROM import metadata is missing: " .. tostring(readError)) end
  local Json = require("src.link.Json")
  local manifest, decodeError = Json.decode(raw)
  if not manifest then error("ROM import metadata is invalid: " .. tostring(decodeError)) end
  assert(manifest.romSha1 == ROM_SHA1, "ROM import metadata version mismatch")
  return manifest
end

local function sha1(data)
  local digest = love.data.hash("sha1", data)
  if type(digest) == "userdata" and digest.getString then
    digest = digest:getString()
  end
  return love.data.encode("string", "hex", digest)
end

local function readExternalPath(path)
  local file, openError = io.open(path, "rb")
  if not file then return nil, openError end
  local data = file:read("*a")
  file:close()
  return data
end

local function readDroppedFile(file)
  local ok, openError = file:open("r")
  if not ok then return nil, openError end
  local data, readError = file:read(file:getSize())
  file:close()
  return data, readError
end

local function trim(value)
  return value and value:gsub("^%s+", ""):gsub("%s+$", "") or ""
end

local function commandOutput(command)
  local pipe = io.popen(command, "r")
  if not pipe then return nil end
  local result = pipe:read("*a")
  pipe:close()
  result = trim(result)
  return result ~= "" and result or nil
end

local function chooseRom()
  local platform = love.system.getOS()
  if platform == "OS X" then
    return commandOutput(
      [[osascript -e 'POSIX path of (choose file with prompt "Choose your Pokemon Red ROM" of type {"gb"})' 2>/dev/null]])
  elseif platform == "Windows" then
    local script = table.concat({
      "Add-Type -AssemblyName System.Windows.Forms;",
      "$d=New-Object System.Windows.Forms.OpenFileDialog;",
      "$d.Title='Choose your Pokemon Red ROM';",
      "$d.Filter='Game Boy ROM (*.gb)|*.gb|All files (*.*)|*.*';",
      "if($d.ShowDialog() -eq 'OK'){[Console]::Write($d.FileName)}",
    })
    return commandOutput(
      'powershell -NoProfile -STA -Command "' .. script .. '"')
  elseif platform == "Linux" then
    local path = commandOutput(
      [[zenity --file-selection --title="Choose your Pokemon Red ROM" --file-filter="Game Boy ROM | *.gb" 2>/dev/null]])
    if path then return path end
    return commandOutput(
      [[kdialog --getopenfilename "$HOME" "*.gb|Game Boy ROM" 2>/dev/null]])
  end
  return nil
end

function RomImporter.new(onComplete)
  local previousMarker = love.filesystem.read(MARKER_PATH)
  local returning = previousMarker ~= nil and previousMarker ~= CACHE_MARKER
  return setmetatable({
    onComplete = onComplete,
    logo = love.graphics.newImage("assets/logo/logo.png"),
    bcg = love.graphics.newImage("assets/logo/bcg.png"),
    state = "waiting",
    returning = returning,
    status = returning and "More assets are needed from your ROM"
      or "Choose or drop a Pokemon Red ROM",
    detail = returning
      and "This update pulls a few more things from your ROM. "
        .. "Please re-import it to continue (it's quick)."
      or "The ROM is verified before any files are created.",
    progress = 0,
    stageCurrent = 0,
    stageTotal = 1,
    pulse = 0,
    button = {},
  }, RomImporter)
end

function RomImporter:setError(message)
  self.state = "error"
  self.status = "That ROM could not be imported"
  self.detail = tostring(message)
  self.progress = 0
  self.worker = nil
  self.romData = nil
end

function RomImporter:startData(data, displayName)
  if self.state == "working" then return end
  if type(data) ~= "string" then
    self:setError("The selected file could not be read.")
    return
  end
  if #data ~= 1024 * 1024 then
    self:setError(("Expected a 1 MiB Pokemon Red ROM; this file is %.2f MiB.")
      :format(#data / 1024 / 1024))
    return
  end

  self.state = "working"
  self.status = "Verifying ROM"
  self.detail = displayName or "Pokemon Red"
  self.progress = 0
  self.romData = data
  self.worker = coroutine.create(function()
    local actualHash = sha1(self.romData)
    if actualHash ~= ROM_SHA1 then
      error(("Unsupported ROM (SHA-1 %s). Use an unmodified US Pokemon Red ROM.")
        :format(actualHash))
    end
    self.status = "Preparing private game data"
    coroutine.yield()
    removeTree("data/generated")
    removeTree("assets/generated")
    love.filesystem.remove(MARKER_PATH)

    local manifest = decodeManifest()
    local RomExtractor = require("src.import.RomExtractor")
    local extractor = RomExtractor.new(self.romData, manifest,
      function(progress, total, stage, current, stageTotal)
        self.status = stage
        self.progress = progress / total
        self.stageCurrent = current
        self.stageTotal = stageTotal
        coroutine.yield()
      end)
    extractor:run()
    self.romData = nil
    collectgarbage("collect")
    local ok, writeError = love.filesystem.write(MARKER_PATH, CACHE_MARKER)
    if not ok then error("could not finish the private cache: " .. tostring(writeError)) end
    self.state = "complete"
    self.status = "Ready"
    self.detail = "Starting Pokemon Red..."
    self.progress = 1
    if self.onComplete then self.onComplete() end
  end)
end

function RomImporter:startPath(path)
  if not path then return end
  local data, readError = readExternalPath(path)
  if not data then
    self:setError("Could not read the selected file: " .. tostring(readError))
    return
  end
  self:startData(data, path:match("[^/\\]+$") or path)
end

function RomImporter:filedropped(file)
  if self.state == "working" then return end
  local data, readError = readDroppedFile(file)
  if not data then
    self:setError("Could not read the dropped file: " .. tostring(readError))
    return
  end
  self:startData(data, file:getFilename())
end

function RomImporter:choose()
  if self.state == "working" then return end
  local path = chooseRom()
  if path then
    self:startPath(path)
  elseif love.system.getOS() ~= "OS X"
      and love.system.getOS() ~= "Windows"
      and love.system.getOS() ~= "Linux" then
    self:setError("File selection is unavailable here. Drop the .gb file onto the window.")
  end
end

function RomImporter:update(dt)
  self.pulse = self.pulse + dt
  if self.state ~= "working" or not self.worker then return end
  local started = love.timer.getTime()
  repeat
    local ok, workerError = coroutine.resume(self.worker)
    if not ok then
      print(debug.traceback(self.worker, tostring(workerError)))
      self:setError(tostring(workerError))
      return
    end
    if coroutine.status(self.worker) == "dead" then
      self.worker = nil
      return
    end
  until love.timer.getTime() - started >= 0.008
end

local function setColor255(r, g, b, a)
  love.graphics.setColor(r / 255, g / 255, b / 255, (a or 255) / 255)
end

local function printCentered(text, y, font, width)
  love.graphics.setFont(font)
  love.graphics.printf(text, 0, y, width, "center")
end

function RomImporter:draw()
  local width, height = love.graphics.getDimensions()
  setColor255(241, 243, 232)
  love.graphics.rectangle("fill", 0, 0, width, height)
  setColor255(181, 35, 42)
  love.graphics.rectangle("fill", 0, 0, width, math.max(8, height * 0.025))

  local fontKey = ("%dx%d"):format(width, height)
  if self.fontKey ~= fontKey then
    self.fontKey = fontKey
    self.bodyFont = love.graphics.newFont(
      math.max(16, math.min(22, height * 0.038)))
    self.smallFont = love.graphics.newFont(
      math.max(13, math.min(17, height * 0.029)))
    self.warningFont = love.graphics.newFont(
      math.max(10, math.min(12, height * 0.022)))
  end
  local bodyFont, smallFont, warningFont =
    self.bodyFont, self.smallFont, self.warningFont
  local contentWidth = math.min(width - 40, 520)
  local left = (width - contentWidth) / 2

  local logoWidth, logoHeight = self.logo:getDimensions()
  local logoScale = math.min(
    math.min(width - 48, 420) / logoWidth,
    height * 0.15 / logoHeight)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(
    self.logo,
    (width - logoWidth * logoScale) / 2,
    height * 0.075,
    0, logoScale, logoScale)
  setColor255(74, 88, 72)
  printCentered(self.returning and "UPDATE REQUIRED" or "FIRST RUN",
    height * 0.205, smallFont, width)

  local zoneY, zoneH = height * 0.29, math.min(180, height * 0.31)
  setColor255(215, 220, 202)
  love.graphics.rectangle("fill", left, zoneY, contentWidth, zoneH)
  setColor255(74, 88, 72)
  love.graphics.setLineWidth(2)
  love.graphics.rectangle("line", left, zoneY, contentWidth, zoneH)

  setColor255(25, 31, 28)
  printCentered(self.status, zoneY + zoneH * 0.25, bodyFont, width)
  setColor255(74, 88, 72)
  love.graphics.setFont(smallFont)
  local _, wrapped = smallFont:getWrap(self.detail, contentWidth - 48)
  local visible = {}
  for index = 1, math.min(#wrapped, 3) do visible[index] = wrapped[index] end
  love.graphics.printf(table.concat(visible, "\n"),
    left + 24, zoneY + zoneH * 0.52, contentWidth - 48, "center")

  if self.state == "working" or self.state == "complete" then
    local barY = zoneY + zoneH - 24
    setColor255(164, 172, 151)
    love.graphics.rectangle("fill", left + 24, barY, contentWidth - 48, 8)
    setColor255(181, 35, 42)
    love.graphics.rectangle("fill", left + 24, barY,
      (contentWidth - 48) * self.progress, 8)
  else
    local buttonWidth = math.min(260, contentWidth - 80)
    local buttonHeight = math.max(46, math.min(56, height * 0.09))
    local buttonX = (width - buttonWidth) / 2
    local buttonY = math.min(height - buttonHeight - 34, zoneY + zoneH + 36)
    self.button = {
      x = buttonX, y = buttonY, width = buttonWidth, height = buttonHeight,
    }
    setColor255(25, 31, 28)
    love.graphics.rectangle("fill", buttonX, buttonY, buttonWidth, buttonHeight)
    setColor255(255, 255, 255)
    love.graphics.setFont(bodyFont)
    love.graphics.printf("Choose ROM", buttonX,
      buttonY + (buttonHeight - bodyFont:getHeight()) / 2,
      buttonWidth, "center")
    setColor255(74, 88, 72)
    love.graphics.setFont(smallFont)
    love.graphics.printf("or drop the .gb file here",
      0, buttonY + buttonHeight + 12, width, "center")
  end

  local bcgWidth, bcgHeight = self.bcg:getDimensions()
  love.graphics.setFont(warningFont)
  local warningWidth = math.min(width - 32, 600)
  local _, warningLines = warningFont:getWrap(TRUST_WARNING, warningWidth)
  local warningHeight = #warningLines * warningFont:getHeight()
  local warningY = height - warningHeight - 8
  local bcgScale = math.min(
    math.min(width - 48, 220) / bcgWidth,
    height * 0.08 / bcgHeight)
  local bcgDrawWidth = bcgWidth * bcgScale
  local bcgDrawHeight = bcgHeight * bcgScale
  local bcgX = (width - bcgDrawWidth) / 2
  local bcgY = warningY - bcgDrawHeight - 8
  self.bcgButton = {
    x = bcgX, y = bcgY,
    width = bcgDrawWidth, height = bcgDrawHeight,
  }
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(
    self.bcg,
    bcgX, bcgY,
    0, bcgScale, bcgScale)
  setColor255(74, 88, 72)
  love.graphics.printf(
    TRUST_WARNING,
    (width - warningWidth) / 2, warningY,
    warningWidth, "center")
  love.graphics.setColor(1, 1, 1, 1)
end

function RomImporter:mousepressed(x, y, button)
  if button ~= 1 then return end
  local logo = self.bcgButton or {}
  if x >= (logo.x or 0) and x <= (logo.x or 0) + (logo.width or 0)
      and y >= (logo.y or 0) and y <= (logo.y or 0) + (logo.height or 0) then
    love.system.openURL(COMMUNITY_URL)
    return
  end
  if self.state == "working" then return end
  local rect = self.button
  if x >= (rect.x or 0) and x <= (rect.x or 0) + (rect.width or 0)
      and y >= (rect.y or 0) and y <= (rect.y or 0) + (rect.height or 0) then
    self:choose()
  end
end

function RomImporter:keypressed(key)
  if (key == "return" or key == "space") and self.state ~= "working" then
    self:choose()
  end
end

return RomImporter
