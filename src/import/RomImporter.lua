local RomImporter = {}
RomImporter.__index = RomImporter

local ROM_SHA1 = "ea9bcae617fdf159b045185467ae58b2e4a48b9a"
local CACHE_MARKER = "rom-cache-v7:" .. ROM_SHA1
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

-- Split-screen ROM-selector palette (the "Split-screen ROM selector" design).
-- One column per game: Red is live, Blue and Yellow are placeholders until
-- those games are supported.  Values are 0-255 RGB.
local PAL = {
  bg          = { 241, 243, 232 },
  detail      = { 74, 88, 72 },
  heading     = { 25, 31, 28 },
  box         = { 215, 220, 202 },
  white       = { 255, 255, 255 },
  red         = { 181, 35, 42 },
  blue        = { 30, 86, 168 },
  gold        = { 214, 164, 0 },
  goldInk     = { 160, 120, 0 },
  disabled    = { 146, 158, 178 },
  disabledInk = { 238, 242, 247 },
}

local function allRequiredFilesExist()
  -- CacheFs.exists checks the game folder directly for a portable install,
  -- otherwise the save directory through love.filesystem.
  local CacheFs = require("src.import.CacheFs")
  for _, path in ipairs(REQUIRED_FILES) do
    if not CacheFs.exists(path) then return false end
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

-- ------- ROM cache location
--
-- The extracted cache (data/generated, assets/generated) plus the
-- rom-cache.complete marker normally live in LÖVE's per-user OS save
-- directory.  A portable install instead keeps them in the game folder next
-- to the executable (the folder holding portable.txt), so nothing is left on
-- the host machine.  Every cache write/read/remove goes through CacheFs,
-- which writes that folder with io.* and makes it readable (mounting it via
-- PhysFS for a fused build) -- there is no mirror step and no per-file
-- os.execute (issue #74: that flashed a console window per file on Windows
-- and froze the app).

-- Remove a cache subtree from the OS save directory.  The realDirectory
-- guard keeps this from ever deleting the game folder (portable installs
-- read the cache from there) or a developer's checked-out source tree.
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

-- Portable installs read the cache from the game folder.  Any copy an
-- earlier non-portable run -- or the pre-#74 build, which always wrote the
-- cache to the save directory and only mirrored it out -- left behind would
-- shadow it, because physfs searches the save directory before the source.
-- Clear it out once, and only when a remnant is actually present so a clean
-- install pays nothing.
local saveDirPurged = false
local function purgeSaveDirCache()
  if saveDirPurged then return end
  saveDirPurged = true
  local saveDir = love.filesystem.getSaveDirectory()
  local function saveDirHas(rel)
    local f = io.open(saveDir .. "/" .. rel, "rb")
    if not f then return false end
    f:close()
    return true
  end
  if not (saveDirHas(MARKER_PATH) or saveDirHas(REQUIRED_FILES[1])) then
    return
  end
  removeTree("data/generated")
  removeTree("assets/generated")
  love.filesystem.remove(MARKER_PATH)
end

function RomImporter.isReady()
  local CacheFs = require("src.import.CacheFs")
  if CacheFs.root() then
    -- Portable: the cache lives in the game folder next to the executable
    -- (mounted onto the read path for a fused build).  Drop any stale
    -- save-directory copy that would otherwise shadow it at runtime -- and,
    -- for a source run, hide the game folder from sourceTreeHasData below.
    purgeSaveDirCache()
  end
  -- Generated data sitting in the physfs source -- a developer checkout, a
  -- Python/bootstrap build, or a source-run portable import -- is always
  -- current (as it has always been).  A fused portable install is not the
  -- source, so it falls through to the version-marker gate.
  if sourceTreeHasData() then return true end
  return CacheFs.read(MARKER_PATH) == CACHE_MARKER and allRequiredFilesExist()
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

-- LOVE 11.5 on Android has no native file picker (love.window.showFileDialog
-- is a LOVE 12 nightly-only addition) and never fires love.filedropped, so
-- neither desktop path below works there. conf.lua points the Android save
-- directory at the app's external-files folder instead (readable/writable
-- via USB or a file manager, no runtime permission needed), and this scans
-- it directly through love.filesystem -- already mounted at the physfs
-- root, so no io.* absolute-path handling is needed.
local function scanForRom()
  for _, name in ipairs(love.filesystem.getDirectoryItems("")) do
    if name:lower():match("%.gb$") and love.filesystem.getInfo(name, "file") then
      return name
    end
  end
  return nil
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

-- onComplete hands off to the game (boot).  opts:
--   ready    -- this game's ROM is already imported: open on the Play state
--   launcher -- interactive launcher: a fresh import lands on the Play state
--               instead of auto-booting (headless callers omit this and keep
--               the old import-then-boot behavior)
--   romName  -- filename shown next to Play when already imported
function RomImporter.new(onComplete, opts)
  opts = opts or {}
  local previousMarker = require("src.import.CacheFs").read(MARKER_PATH)
  local returning = previousMarker ~= nil and previousMarker ~= CACHE_MARKER
  local android = love.system.getOS() == "Android"
  local self = setmetatable({
    onComplete = onComplete,
    launcher = opts.launcher or false,
    logo = love.graphics.newImage("assets/logo/logo.png"),
    bcg = love.graphics.newImage("assets/logo/bcg.png"),
    state = opts.ready and "ready" or "waiting",
    romName = opts.romName or "pokemon_red.gb",
    returning = returning,
    android = android,
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
  }, RomImporter)

  -- Only hunt for a ROM when one is actually needed; an already-imported
  -- game opens straight on Play.
  if android and self.state ~= "ready" then
    self.status = returning and "More ROM assets needed" or "Get your Pokemon Red ROM (.gb) in"
    self.detail = "Tap Choose ROM to pick your file"
    local name = scanForRom()
    if name then
      self:startData(love.filesystem.read(name), name)
    end
  end

  return self
end

-- The system picker runs as a separate top activity, so LOVE's own
-- love.focus/love.visible pause while it's up (see main.lua) -- once the
-- player returns here with a file picked, GameActivity has already copied
-- it into the folder scanForRom checks, so a rescan on refocus picks it up
-- without the player needing to tap the button again.
function RomImporter:focus(f)
  if not (f and self.android
      and (self.state == "waiting" or self.state == "error")) then
    return
  end
  local name = scanForRom()
  if name then
    self:startData(love.filesystem.read(name), name)
  end
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
    -- Clear any previous cache from both possible homes: the save directory
    -- (removeTree) and, for a portable install, the game folder (CacheFs).
    local CacheFs = require("src.import.CacheFs")
    removeTree("data/generated")
    removeTree("assets/generated")
    love.filesystem.remove(MARKER_PATH)
    CacheFs.removeTree("data/generated")
    CacheFs.removeTree("assets/generated")
    CacheFs.remove(MARKER_PATH)

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
    -- Written last: the marker is what isReady() checks, so it must only
    -- appear once every required file is in place.  CacheFs puts it beside
    -- the cache -- the game folder for a portable install, else the save
    -- directory.
    local ok, writeError = CacheFs.write(MARKER_PATH, CACHE_MARKER)
    if not ok then error("could not finish the private cache: " .. tostring(writeError)) end
    self.state = "complete"
    self.status = "Ready"
    self.detail = "Starting Pokemon Red..."
    self.progress = 1
    if self.launcher then
      -- Stay on the launcher and show Play for the game just imported; the
      -- player presses Play to boot it.
      self.romName = (displayName and (displayName:match("[^/\\]+$") or displayName))
        or self.romName
      self.state = "ready"
      return
    end
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
  if self.android then
    local name = scanForRom()
    if name then
      self:startData(love.filesystem.read(name), name)
    elseif not love.system.pickFile() then
      -- Picker unavailable (API < 19, or no document-picker app installed):
      -- fall back to the USB folder-drop path. Not setError(): that status
      -- text ("could not be imported") reads as a rejected file, not "none
      -- found yet" -- and detail only renders 3 wrapped lines, so the path
      -- again gets the line to itself.
      self.state = "waiting"
      self.status = "No picker available, copy your ROM into:"
      self.detail = love.filesystem.getSaveDirectory()
    end
    return
  end
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

-- Player pressed Play on a game whose ROM is imported: hand off to boot.
function RomImporter:play()
  if self.onComplete then self.onComplete() end
end

-- "re-import" from the Play state: drop back to the choose/drop UI so a fresh
-- ROM can be selected (the extract itself replaces the old cache).
function RomImporter:reimport()
  if self.state ~= "ready" then return end
  self.state = "waiting"
  self.returning = false
end

local function clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

-- set the current draw color from a PAL triple (0-255), with optional alpha 0-1
local function col(c, a)
  love.graphics.setColor(c[1] / 255, c[2] / 255, c[3] / 255, a or 1)
end

-- LOVE has no dashed-stroke primitive; step short segments along each edge so
-- the "coming soon" Blue/Yellow boxes read as placeholders
local function dashedRect(x, y, w, h, dash, gap)
  local step = dash + gap
  local function edge(x1, y1, x2, y2)
    local dx, dy = x2 - x1, y2 - y1
    local len = math.sqrt(dx * dx + dy * dy)
    if len == 0 then return end
    local ux, uy = dx / len, dy / len
    local d = 0
    while d < len do
      local e = math.min(d + dash, len)
      love.graphics.line(x1 + ux * d, y1 + uy * d, x1 + ux * e, y1 + uy * e)
      d = d + step
    end
  end
  edge(x, y, x + w, y)
  edge(x + w, y, x + w, y + h)
  edge(x + w, y + h, x, y + h)
  edge(x, y + h, x, y)
end

function RomImporter:draw()
  local width, height = love.graphics.getDimensions()
  local third = width / 3
  col(PAL.bg)
  love.graphics.rectangle("fill", 0, 0, width, height)

  -- top tri-colour stripe (Red | Blue | Yellow)
  local stripeH = math.max(8, height * 0.02)
  col(PAL.red);  love.graphics.rectangle("fill", 0, 0, third, stripeH)
  col(PAL.blue); love.graphics.rectangle("fill", third, 0, third, stripeH)
  col(PAL.gold); love.graphics.rectangle("fill", 2 * third, 0, width - 2 * third, stripeH)

  -- fonts, rebuilt only when the window size changes
  local fontKey = ("%dx%d"):format(width, height)
  if self.fontKey ~= fontKey then
    self.fontKey = fontKey
    local function f(frac, lo, hi) return love.graphics.newFont(clamp(height * frac, lo, hi)) end
    self.pillFont    = f(0.021, 12, 15)
    self.headFont    = f(0.030, 16, 22)
    self.detailFont  = f(0.023, 13, 16)
    self.buttonFont  = f(0.029, 16, 22)
    self.hintFont    = f(0.021, 12, 15)
    self.warningFont = f(0.017, 10, 12)
  end

  -- footer (Boi's Club Games logo + trust warning), pinned to the bottom and
  -- measured first so the columns know where they must stop
  local warningWidth = math.min(width - 32, 620)
  love.graphics.setFont(self.warningFont)
  local _, warningLines = self.warningFont:getWrap(TRUST_WARNING, warningWidth)
  local warningH = #warningLines * self.warningFont:getHeight()
  local warningY = height - warningH - 8
  local bcgW, bcgH = self.bcg:getDimensions()
  local bcgScale = math.min(math.min(width - 48, 200) / bcgW, height * 0.075 / bcgH)
  local bcgDW, bcgDH = bcgW * bcgScale, bcgH * bcgScale
  local bcgX, bcgY = (width - bcgDW) / 2, warningY - bcgDH - 8
  self.bcgButton = { x = bcgX, y = bcgY, width = bcgDW, height = bcgDH }
  local footerTop = bcgY - 10

  -- faint per-column tints under the split
  col(PAL.red, 0.07);  love.graphics.rectangle("fill", 0, stripeH, third, footerTop - stripeH)
  col(PAL.blue, 0.07); love.graphics.rectangle("fill", third, stripeH, third, footerTop - stripeH)
  col(PAL.gold, 0.08); love.graphics.rectangle("fill", 2 * third, stripeH, width - 2 * third, footerTop - stripeH)

  -- logo (larger, no subtitle), centred over the split
  local logoW, logoH = self.logo:getDimensions()
  local logoScale = math.min(math.min(width - 40, 560) / logoW, height * 0.20 / logoH)
  local logoDW, logoDH = logoW * logoScale, logoH * logoScale
  local logoY = stripeH + height * 0.02
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(self.logo, (width - logoDW) / 2, logoY, 0, logoScale, logoScale)

  -- shared column metrics so the three columns line up exactly
  local m = {
    boxW    = math.min(third - 32, 300),
    boxH    = clamp(height * 0.22, 120, 190),
    pillH   = self.pillFont:getHeight() + 10,
    buttonH = clamp(height * 0.072, 44, 56),
    gap1    = clamp(height * 0.028, 12, 22),
    gap2    = clamp(height * 0.030, 14, 24),
    gap3    = 10,
    hintH   = self.hintFont:getHeight(),
  }
  local stackH = m.pillH + m.gap1 + m.boxH + m.gap2 + m.buttonH + m.gap3 + m.hintH
  local regionTop = logoY + logoDH + height * 0.03
  local top = regionTop + math.max(0, (footerTop - regionTop - stackH) / 2)

  -- draw one column and return the button/link hit rects for the caller
  local function column(colX, spec)
    local cx = colX + third / 2
    local x = cx - m.boxW / 2
    local a = spec.alpha or 1
    local y = top

    -- pill badge
    love.graphics.setFont(self.pillFont)
    local pillW = self.pillFont:getWidth(spec.label) + 28
    col(spec.color, a)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", cx - pillW / 2, y, pillW, m.pillH, m.pillH / 2, m.pillH / 2)
    love.graphics.printf(spec.label, cx - pillW / 2,
      y + (m.pillH - self.pillFont:getHeight()) / 2, pillW, "center")
    y = y + m.pillH + m.gap1

    -- box
    col(PAL.box, a)
    love.graphics.rectangle("fill", x, y, m.boxW, m.boxH)
    love.graphics.setLineWidth(2)
    col(spec.color, a)
    if spec.dashed then
      dashedRect(x, y, m.boxW, m.boxH, 7, 5)
    else
      love.graphics.rectangle("line", x, y, m.boxW, m.boxH)
    end
    local pad = 14
    love.graphics.setFont(self.headFont)
    col(PAL.heading, a)
    love.graphics.printf(spec.heading, x + pad, y + pad, m.boxW - 2 * pad, "center")
    local _, headLines = self.headFont:getWrap(spec.heading, m.boxW - 2 * pad)
    local headBlock = math.max(1, #headLines) * self.headFont:getHeight()
    love.graphics.setFont(self.detailFont)
    col(PAL.detail, a)
    love.graphics.printf(spec.detail, x + pad, y + pad + headBlock + 8, m.boxW - 2 * pad, "center")
    if spec.progress then
      local barY = y + m.boxH - 20
      col(PAL.disabled, a)
      love.graphics.rectangle("fill", x + pad, barY, m.boxW - 2 * pad, 8)
      col(spec.color, a)
      love.graphics.rectangle("fill", x + pad, barY, (m.boxW - 2 * pad) * spec.progress, 8)
    end
    y = y + m.boxH + m.gap2

    -- button
    local rect
    if spec.button then
      rect = { x = x, y = y, width = m.boxW, height = m.buttonH }
      col(spec.button.bg, a)
      love.graphics.rectangle("fill", x, y, m.boxW, m.buttonH)
      love.graphics.setFont(self.buttonFont)
      local label = spec.button.text
      if spec.button.play then
        -- filled play triangle + label, centred as a group
        local tw = self.buttonFont:getWidth(label)
        local tri = self.buttonFont:getHeight() * 0.55
        local groupW = tri + 12 + tw
        local gx = x + (m.boxW - groupW) / 2
        local gy = y + m.buttonH / 2
        col(spec.button.fg, a)
        love.graphics.polygon("fill", gx, gy - tri / 2, gx, gy + tri / 2, gx + tri * 0.9, gy)
        love.graphics.print(label, gx + tri + 12,
          y + (m.buttonH - self.buttonFont:getHeight()) / 2)
      else
        col(spec.button.fg, a)
        love.graphics.printf(label, x,
          y + (m.buttonH - self.buttonFont:getHeight()) / 2, m.boxW, "center")
      end
    end
    y = y + m.buttonH + m.gap3

    -- hint line, or the "<rom> imported  ·  re-import" link
    love.graphics.setFont(self.hintFont)
    local reimportRect
    if spec.reimport then
      local prefix = spec.romName .. " imported   ·   "
      local link = "re-import"
      local pw = self.hintFont:getWidth(prefix)
      local lw = self.hintFont:getWidth(link)
      local startX = cx - (pw + lw) / 2
      col(PAL.detail, a)
      love.graphics.print(prefix, startX, y)
      love.graphics.print(link, startX + pw, y)
      love.graphics.setLineWidth(1)
      love.graphics.line(startX + pw, y + self.hintFont:getHeight(),
        startX + pw + lw, y + self.hintFont:getHeight())
      reimportRect = { x = startX + pw, y = y, width = lw, height = m.hintH + 2 }
    elseif spec.hint then
      col(PAL.detail, a)
      love.graphics.printf(spec.hint, x, y, m.boxW, "center")
    end

    return rect, reimportRect
  end

  -- Red column: live, driven by the import state machine
  local redHint = self.android and "or copy the .gb via USB" or "or drop the .gb file here"
  local redSpec = { color = PAL.red, label = "RED", dashed = false, alpha = 1 }
  if self.state == "ready" then
    redSpec.heading = "Red ROM ready"
    redSpec.detail  = "Your ROM is verified. Press Play to start."
    redSpec.button  = { text = "Play Red", bg = PAL.red, fg = PAL.white, play = true }
    redSpec.reimport = true
    redSpec.romName  = self.romName
  elseif self.state == "working" or self.state == "complete" then
    redSpec.heading  = self.status
    redSpec.detail   = self.detail
    redSpec.progress = self.progress or 0
  elseif self.state == "error" then
    redSpec.heading = "That ROM could not be imported"
    redSpec.detail  = self.detail
    redSpec.button  = { text = "Choose ROM", bg = PAL.red, fg = PAL.white }
    redSpec.hint    = redHint
  else -- waiting
    if self.android then
      redSpec.heading = self.status
      redSpec.detail  = self.detail
    elseif self.returning then
      redSpec.heading = "Update required"
      redSpec.detail  = "This build needs a few more things from your ROM. Re-import to continue."
    else
      redSpec.heading = "Choose or drop a Red ROM"
      redSpec.detail  = "The ROM is verified before any files are created."
    end
    redSpec.button = { text = "Choose ROM", bg = PAL.red, fg = PAL.white }
    redSpec.hint   = redHint
  end
  self.redButton, self.reimportRect = column(0, redSpec)

  -- Blue and Yellow columns: placeholders until those games are supported
  column(third, {
    color = PAL.blue, label = "BLUE", dashed = true, alpha = 0.72,
    heading = "Choose or drop a Blue ROM", detail = "Blue support is on the way.",
    button = { text = "Coming soon", bg = PAL.disabled, fg = PAL.disabledInk },
    hint = "not yet available",
  })
  column(2 * third, {
    color = PAL.gold, label = "YELLOW", dashed = true, alpha = 0.72,
    heading = "Choose or drop a Yellow ROM", detail = "Yellow support is on the way.",
    button = { text = "Coming soon", bg = PAL.disabled, fg = PAL.disabledInk },
    hint = "not yet available",
  })

  -- footer
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(self.bcg, bcgX, bcgY, 0, bcgScale, bcgScale)
  col(PAL.detail)
  love.graphics.setFont(self.warningFont)
  love.graphics.printf(TRUST_WARNING, (width - warningWidth) / 2, warningY, warningWidth, "center")
  love.graphics.setColor(1, 1, 1, 1)
end

local function inside(r, x, y)
  return r and x >= r.x and x <= r.x + r.width and y >= r.y and y <= r.y + r.height
end

function RomImporter:mousepressed(x, y, button)
  if button ~= 1 then return end
  if inside(self.bcgButton, x, y) then
    love.system.openURL(COMMUNITY_URL)
    return
  end
  if self.state == "working" or self.state == "complete" then return end
  if self.state == "ready" then
    if inside(self.reimportRect, x, y) then self:reimport()
    elseif inside(self.redButton, x, y) then self:play() end
    return
  end
  if inside(self.redButton, x, y) then self:choose() end
end

function RomImporter:keypressed(key)
  if self.state == "working" or self.state == "complete" then return end
  if key == "return" or key == "space" or key == "kpenter" then
    if self.state == "ready" then self:play() else self:choose() end
  end
end

return RomImporter
