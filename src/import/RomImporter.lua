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

-- "Split-screen ROM selector" first-run palette (matches FirstRun.dc.html from
-- the Claude Design project): a dark neon arcade panel, one column per game.
-- Red is live; Blue and Yellow are lit placeholders until those games are
-- supported.  Values are 0-255 RGB; alpha is applied per draw.
local PAL = {
  -- radial background gradient (bright navy at top-centre -> near black)
  bgTop       = { 22, 34, 74 },   -- #16224a
  bgBot       = { 7, 11, 29 },    -- #070b1d
  -- neon accents, one per cartridge
  red         = { 255, 60, 72 },  -- rgb(255,60,72)
  blue        = { 70, 150, 255 }, -- rgb(70,150,255)
  gold        = { 255, 203, 5 },  -- rgb(255,203,5)
  -- card interiors (the dark colour the accent tint fades into)
  cardRed     = { 20, 12, 26 },   -- #140c1a
  cardBlue    = { 12, 18, 40 },   -- #0c1228
  cardGold    = { 30, 22, 8 },    -- #1e1608
  -- text
  heading     = { 255, 255, 255 },
  detail      = { 198, 208, 230 }, -- #c6d0e6
  warning     = { 159, 176, 208 }, -- #9fb0d0
  link        = { 127, 208, 255 }, -- #7fd0ff, the bois.icu link
  linkHover   = { 191, 234, 255 }, -- #bfeaff, brighter on hover
  white       = { 255, 255, 255 },
  -- "Play" button (green gradient) + its ink
  playTop     = { 62, 224, 138 }, -- #3ee08a
  playBot     = { 22, 163, 90 },  -- #16a35a
  playInk     = { 6, 32, 18 },    -- #062012
  -- "Choose ROM" button (red gradient)
  chooseTop   = { 255, 83, 97 },  -- #ff5361
  chooseBot   = { 214, 31, 44 },  -- #d61f2c
  -- disabled "Coming soon" button
  disabled    = { 120, 132, 158 },
  disabledInk = { 149, 161, 189 }, -- #95a1bd
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

-- set the current draw colour from a PAL triple (0-255), with optional alpha 0-1
local function col(c, a)
  love.graphics.setColor(c[1] / 255, c[2] / 255, c[3] / 255, a or 1)
end

-- Faux-bold: the launcher's UI font ships no bold face, so 800-weight text
-- (headings, buttons) is thickened with a second sub-pixel pass.
local function printfB(text, x, y, w, align)
  love.graphics.printf(text, x, y, w, align)
  love.graphics.printf(text, x + 0.6, y, w, align)
end
local function printB(text, x, y)
  love.graphics.print(text, x, y)
  love.graphics.print(text, x + 0.6, y)
end

-- One reusable unit quad, recoloured per call, for every vertical gradient
-- fill (LOVE has no gradient primitive and a per-frame newMesh would churn
-- the GPU).  Callers set the blend mode; this only touches colour + geometry.
local gradMesh
local function setGrad(cTop, cBot, aTop, aBot)
  if not gradMesh then gradMesh = love.graphics.newMesh(4, "fan", "dynamic") end
  gradMesh:setVertices({
    { 0, 0, 0, 0, cTop[1] / 255, cTop[2] / 255, cTop[3] / 255, aTop },
    { 1, 0, 1, 0, cTop[1] / 255, cTop[2] / 255, cTop[3] / 255, aTop },
    { 1, 1, 1, 1, cBot[1] / 255, cBot[2] / 255, cBot[3] / 255, aBot },
    { 0, 1, 0, 1, cBot[1] / 255, cBot[2] / 255, cBot[3] / 255, aBot },
  })
end
local function fillGrad(x, y, w, h, cTop, cBot, aTop, aBot)
  setGrad(cTop, cBot, aTop, aBot)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(gradMesh, x, y, 0, w, h)
end
-- vertical gradient clipped to a rounded rectangle (via the stencil buffer)
local function fillGradRounded(x, y, w, h, r, cTop, cBot, aTop, aBot)
  love.graphics.stencil(function()
    love.graphics.rectangle("fill", x, y, w, h, r, r)
  end, "replace", 1)
  love.graphics.setStencilTest("greater", 0)
  fillGrad(x, y, w, h, cTop, cBot, aTop, aBot)
  love.graphics.setStencilTest()
end

-- Soft additive neon halo around a rounded rect.  LOVE has no blur, so stack
-- progressively larger, fainter translucent rounded rects.
local function neonGlow(x, y, w, h, r, c, strength)
  strength = math.max(0, strength)
  if strength == 0 then return end
  love.graphics.setBlendMode("add")
  local layers = 7
  for i = 1, layers do
    local g = i * 2.4
    love.graphics.setColor(c[1] / 255, c[2] / 255, c[3] / 255,
      strength * 0.05 * (1 - (i - 1) / layers))
    love.graphics.rectangle("fill", x - g, y - g, w + 2 * g, h + 2 * g, r + g, r + g)
  end
  love.graphics.setBlendMode("alpha")
end

-- A white shine band that sweeps across an active button, clipped to its
-- rounded shape.  phase is 0..1 (left of the button -> right of it).
local shineMesh
local function buttonShine(x, y, w, h, r, phase)
  if not shineMesh then
    -- triangle strip: three columns (transparent, white, transparent)
    shineMesh = love.graphics.newMesh({
      { 0,   0, 0,   0, 1, 1, 1, 0 },
      { 0,   1, 0,   1, 1, 1, 1, 0 },
      { 0.5, 0, 0.5, 0, 1, 1, 1, 0.5 },
      { 0.5, 1, 0.5, 1, 1, 1, 1, 0.5 },
      { 1,   0, 1,   0, 1, 1, 1, 0 },
      { 1,   1, 1,   1, 1, 1, 1, 0 },
    }, "strip", "static")
  end
  local bandW = w * 0.6
  local bx = x - bandW + phase * (w + bandW)
  love.graphics.stencil(function()
    love.graphics.rectangle("fill", x, y, w, h, r, r)
  end, "replace", 1)
  love.graphics.setStencilTest("greater", 0)
  love.graphics.setBlendMode("add")
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(shineMesh, bx, y, 0, bandW, h)
  love.graphics.setBlendMode("alpha")
  love.graphics.setStencilTest()
end

function RomImporter:draw()
  local width, height = love.graphics.getDimensions()
  local third = width / 3
  local s = clamp(height / 768, 0.7, 1.6)
  local pulse = self.pulse

  -- Hover state (desktop only -- touch has no cursor).  anyHover and ptIn are
  -- captured by drawCard and the footer below; the cursor is set at the end.
  local mx, my = love.mouse.getPosition()
  local hoverEnabled = not self.android
  local anyHover = false
  local function ptIn(r)
    return r and mx >= r.x and mx <= r.x + r.width and my >= r.y and my <= r.y + r.height
  end

  -- Fonts + size-dependent scenery, rebuilt only when the window size changes.
  local fontKey = ("%dx%d"):format(width, height)
  if self.fontKey ~= fontKey then
    self.fontKey = fontKey
    local function f(px) return love.graphics.newFont(math.max(8, math.floor(px + 0.5))) end
    self.headFont    = f(19 * s)
    self.detailFont  = f(14 * s)
    self.buttonFont  = f(19 * s)
    self.hintFont    = f(13 * s)
    self.warningFont = f(11 * s)

    -- Background: a radial gradient (bright navy at top-centre -> near black).
    -- A triangle fan from the top-centre gives the radial falloff; the screen
    -- is cleared to the outer colour first so the corners it does not reach
    -- match seamlessly.
    do
      local cx, cy = width / 2, 0
      local rx, ry = width * 1.3, height * 1.08
      local n = 72
      local verts = { { cx, cy, 0, 0,
        PAL.bgTop[1] / 255, PAL.bgTop[2] / 255, PAL.bgTop[3] / 255, 1 } }
      for i = 0, n do
        local a = (i / n) * math.pi * 2
        verts[#verts + 1] = { cx + math.cos(a) * rx, cy + math.sin(a) * ry, 0, 0,
          PAL.bgBot[1] / 255, PAL.bgBot[2] / 255, PAL.bgBot[3] / 255, 1 }
      end
      self.bgMesh = love.graphics.newMesh(verts, "fan", "static")
    end

    -- CRT vignette: a gentle edge darkening, centred slightly above the middle.
    do
      local cx, cy = width / 2, height * 0.45
      local rx, ry = width * 0.78, height * 0.78
      local n = 72
      local verts = { { cx, cy, 0, 0, 0, 0, 0, 0 } }
      for i = 0, n do
        local a = (i / n) * math.pi * 2
        verts[#verts + 1] =
          { cx + math.cos(a) * rx, cy + math.sin(a) * ry, 0, 0, 0, 0, 0, 0.32 }
      end
      self.vignetteMesh = love.graphics.newMesh(verts, "fan", "static")
    end

    -- CRT scanlines: a 1px dark line every 3px, baked into a tiny tile and
    -- drawn once with a repeat-wrapped quad (one draw call, correct alpha).
    if not self.scanlineImage then
      local id = love.image.newImageData(1, 3)
      id:setPixel(0, 0, 0, 0, 0, 0.08)
      id:setPixel(0, 1, 0, 0, 0, 0)
      id:setPixel(0, 2, 0, 0, 0, 0)
      self.scanlineImage = love.graphics.newImage(id)
      self.scanlineImage:setWrap("repeat", "repeat")
      self.scanlineImage:setFilter("nearest", "nearest")
    end
    self.scanlineQuad = love.graphics.newQuad(0, 0, width, height, 1, 3)
  end

  -- Invert shader: the Boi's Club Games mark is dark ink; on this dark panel it
  -- is rendered white (the design's filter:invert(1)).  Built lazily so a
  -- headless require never needs a GL context.
  self.invertShader = self.invertShader or love.graphics.newShader([[
    vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
      vec4 p = Texel(tex, tc);
      return vec4((vec3(1.0) - p.rgb) * color.rgb, p.a * color.a);
    }
  ]])

  -- Shine shader: the same white sweep the active buttons get, but clipped to
  -- the logo's own shape (a soft band brightens the pixels it crosses; fully
  -- transparent pixels stay transparent).
  self.shineShader = self.shineShader or love.graphics.newShader([[
    extern number shinePos;
    extern number shineW;
    vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
      vec4 p = Texel(tex, tc);
      float band = smoothstep(shineW, 0.0, abs(tc.x - shinePos));
      return vec4(p.rgb + band * 0.55, p.a) * color;
    }
  ]])

  -- background
  col(PAL.bgBot)
  love.graphics.rectangle("fill", 0, 0, width, height)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(self.bgMesh)

  -- neon tri-segment top bar (Red | Blue | Yellow) with a soft downward bloom
  local barH = math.max(10, 16 * s)
  local segs = {
    { PAL.red,  0,         third },
    { PAL.blue, third,     third },
    { PAL.gold, 2 * third, width - 2 * third },
  }
  love.graphics.setBlendMode("add")
  for _, seg in ipairs(segs) do
    fillGrad(seg[2], 0, seg[3], barH * 3.2, seg[1], seg[1], 0.30, 0.0)
  end
  love.graphics.setBlendMode("alpha")
  for _, seg in ipairs(segs) do
    col(seg[1]); love.graphics.rectangle("fill", seg[2], 0, seg[3], barH)
  end

  -- Footer (Boi's Club Games logo + trust warning), measured first so the
  -- columns know where they must stop.  Drawn near the end.
  local warningWidth = math.min(width - 32, 620)
  local _, warningLines = self.warningFont:getWrap(TRUST_WARNING, warningWidth)
  local warningH = #warningLines * self.warningFont:getHeight()
  local warningY = height - warningH - 10
  local bcgW, bcgH = self.bcg:getDimensions()
  local bcgScale = math.min(math.min(width - 48, 200) / bcgW, height * 0.07 / bcgH)
  local bcgDW, bcgDH = bcgW * bcgScale, bcgH * bcgScale
  local bcgX, bcgY = (width - bcgDW) / 2, warningY - bcgDH - 8
  self.bcgButton = { x = bcgX, y = bcgY, width = bcgDW, height = bcgDH }
  local footerTop = bcgY - 12

  -- Logo metrics (drawn later with a bob so the cards never shift; layout uses
  -- the resting position).
  local logoW, logoH = self.logo:getDimensions()
  local logoScale = math.min(math.min(width - 40, 440 * s) / logoW, height * 0.20 / logoH)
  local logoDW, logoDH = logoW * logoScale, logoH * logoScale
  local logoY = barH + 20 * s

  -- shared card metrics so the three columns line up exactly
  local padX      = 20 * s
  local padTop    = 22 * s
  local padBot    = 24 * s
  local cardW     = math.min(third - 24 * s, 300 * s)
  local buttonH   = 50 * s
  local gapHead   = 8 * s
  local gapDetail = 18 * s
  local gapButton = 10 * s
  local hintH     = self.hintFont:getHeight()

  -- natural height a card needs for its (wrapped) heading + detail
  local function contentH(spec)
    local innerW = cardW - 2 * padX
    local _, hl = self.headFont:getWrap(spec.heading, innerW)
    local _, dl = self.detailFont:getWrap(spec.detail, innerW)
    local headH = math.max(1, #hl) * self.headFont:getHeight()
    local detH  = math.max(1, #dl) * self.detailFont:getHeight()
    return padTop + headH + gapHead + detH + gapDetail
      + buttonH + gapButton + hintH + padBot
  end

  -- Red column: live, driven by the import state machine.
  local redHint = self.android and "or copy the .gb via USB" or "or drop the .gb file here"
  local redSpec = {
    accent = PAL.red, interior = PAL.cardRed,
    alpha = 1, glowScale = 1, period = 2.6,
  }
  if self.state == "ready" then
    redSpec.heading = "Red ROM ready"
    redSpec.detail  = "Your ROM is verified. Press Play to start."
    redSpec.button  = { kind = "play", text = "Play Red" }
    redSpec.link    = { name = self.romName }
  elseif self.state == "working" or self.state == "complete" then
    redSpec.heading  = self.status
    redSpec.detail   = self.detail
    redSpec.progress = self.progress or 0
  elseif self.state == "error" then
    redSpec.heading = "That ROM could not be imported"
    redSpec.detail  = self.detail
    redSpec.button  = { kind = "choose", text = "Choose ROM" }
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
    redSpec.button = { kind = "choose", text = "Choose ROM" }
    redSpec.hint   = redHint
  end

  -- Blue and Yellow columns: lit placeholders until those games are supported.
  local blueSpec = {
    accent = PAL.blue, interior = PAL.cardBlue,
    alpha = 0.92, glowScale = 0.5, period = 3.4,
    heading = "Choose or drop a Blue ROM", detail = "Blue support is on the way.",
    button = { kind = "disabled", text = "Coming soon" }, hint = "not yet available",
  }
  local yellowSpec = {
    accent = PAL.gold, interior = PAL.cardGold,
    alpha = 0.92, glowScale = 0.5, period = 3.8,
    heading = "Choose or drop a Yellow ROM", detail = "Yellow support is on the way.",
    button = { kind = "disabled", text = "Coming soon" }, hint = "not yet available",
  }

  local cardH = math.max(contentH(redSpec), contentH(blueSpec), contentH(yellowSpec))
  local regionTop = logoY + logoDH + 14 * s
  local top = regionTop + math.max(0, (footerTop - regionTop - cardH) / 2)

  -- Draw one neon cartridge card and return its button/link hit rects.
  local function drawCard(colX, spec, ty)
    local cx = colX + third / 2
    local x = cx - cardW / 2
    local y = ty
    local a = spec.alpha or 1
    local r = 16 * s

    -- pulsing neon halo
    local g = 0.5 + 0.5 * math.sin(pulse * 2 * math.pi / spec.period)
    neonGlow(x, y, cardW, cardH, r, spec.accent, (0.35 + 0.55 * g) * (spec.glowScale or 1))

    -- card body: accent tint at the top fading into a dark interior, + border
    fillGradRounded(x, y, cardW, cardH, r, spec.accent, spec.interior, 0.16 * a, 0.55 * a)
    love.graphics.setLineWidth(math.max(1, 1.5 * s))
    col(spec.accent, 0.6 * a)
    love.graphics.rectangle("line", x, y, cardW, cardH, r, r)

    local contentY = y + padTop

    -- heading
    love.graphics.setFont(self.headFont)
    col(PAL.heading, a)
    printfB(spec.heading, x + padX, contentY, cardW - 2 * padX, "center")
    local _, hl = self.headFont:getWrap(spec.heading, cardW - 2 * padX)
    contentY = contentY + math.max(1, #hl) * self.headFont:getHeight() + gapHead

    -- detail
    love.graphics.setFont(self.detailFont)
    col(PAL.detail, a)
    love.graphics.printf(spec.detail, x + padX, contentY, cardW - 2 * padX, "center")
    local _, dl = self.detailFont:getWrap(spec.detail, cardW - 2 * padX)
    contentY = contentY + math.max(1, #dl) * self.detailFont:getHeight() + gapDetail

    -- button, or a neon progress bar while extracting
    local bx, bw, by = x + padX, cardW - 2 * padX, contentY
    local buttonRect
    if spec.progress ~= nil then
      local h2 = math.max(8, 10 * s)
      local track = by + (buttonH - h2) / 2
      col(PAL.bgBot, 0.85)
      love.graphics.rectangle("fill", bx, track, bw, h2, h2 / 2, h2 / 2)
      local pw = bw * clamp(spec.progress, 0, 1)
      if pw > h2 then
        neonGlow(bx, track, pw, h2, h2 / 2, spec.accent, 0.6)
        col(spec.accent, a)
        love.graphics.rectangle("fill", bx, track, pw, h2, h2 / 2, h2 / 2)
      end
    elseif spec.button then
      local br = 12 * s
      local kind = spec.button.kind
      buttonRect = { x = bx, y = by, width = bw, height = buttonH }
      if kind == "disabled" then
        col(PAL.disabled, 0.4 * a)
        love.graphics.rectangle("fill", bx, by, bw, buttonH, br, br)
        love.graphics.setLineWidth(1)
        col(spec.accent, 0.3 * a)
        love.graphics.rectangle("line", bx, by, bw, buttonH, br, br)
        love.graphics.setFont(self.buttonFont)
        col(PAL.disabledInk, a)
        printfB(spec.button.text, bx, by + (buttonH - self.buttonFont:getHeight()) / 2, bw, "center")
        buttonRect = nil -- placeholder columns are inert
      else
        local cTop, cBot, ink
        if kind == "play" then cTop, cBot, ink = PAL.playTop, PAL.playBot, PAL.playInk
        else cTop, cBot, ink = PAL.chooseTop, PAL.chooseBot, PAL.white end
        local hot = hoverEnabled and ptIn(buttonRect)
        if hot then anyHover = true end
        neonGlow(bx, by, bw, buttonH, br, cTop, (0.7 + 0.25 * g) * (hot and 1.7 or 1))
        fillGradRounded(bx, by, bw, buttonH, br, cTop, cBot, 1, 1)
        if hot then
          -- brighten the face on hover
          love.graphics.setBlendMode("add")
          love.graphics.setColor(1, 1, 1, 0.12)
          love.graphics.rectangle("fill", bx, by, bw, buttonH, br, br)
          love.graphics.setBlendMode("alpha")
        end
        buttonShine(bx, by, bw, buttonH, br, (pulse % 2.8) / 2.8)
        love.graphics.setFont(self.buttonFont)
        if kind == "play" then
          -- filled play triangle + label, centred as a group
          local label = spec.button.text
          local tw = self.buttonFont:getWidth(label)
          local tri = self.buttonFont:getHeight() * 0.55
          local groupW = tri + 12 * s + tw
          local gx = bx + (bw - groupW) / 2
          local gy = by + buttonH / 2
          col(ink)
          love.graphics.polygon("fill", gx, gy - tri / 2, gx, gy + tri / 2, gx + tri * 0.9, gy)
          printB(label, gx + tri + 12 * s, by + (buttonH - self.buttonFont:getHeight()) / 2)
        else
          col(ink)
          printfB(spec.button.text, bx, by + (buttonH - self.buttonFont:getHeight()) / 2, bw, "center")
        end
      end
    end
    contentY = by + buttonH + gapButton

    -- subline: a hint, or the "<rom>  ·  re-import" link
    love.graphics.setFont(self.hintFont)
    local linkRect
    if spec.link then
      local prefix = spec.link.name .. "   ·   "
      local link = "re-import"
      local pw = self.hintFont:getWidth(prefix)
      local lw = self.hintFont:getWidth(link)
      local startX = cx - (pw + lw) / 2
      col(PAL.detail, a)
      love.graphics.print(prefix, startX, contentY)
      love.graphics.print(link, startX + pw, contentY)
      love.graphics.setLineWidth(1)
      love.graphics.line(startX + pw, contentY + hintH, startX + pw + lw, contentY + hintH)
      linkRect = { x = startX + pw, y = contentY, width = lw, height = hintH + 3 }
    elseif spec.hint then
      col(PAL.detail, a)
      love.graphics.printf(spec.hint, x + padX, contentY, cardW - 2 * padX, "center")
    end

    return buttonRect, linkRect
  end

  self.redButton, self.reimportRect = drawCard(0, redSpec, top)
  drawCard(third, blueSpec, top)
  drawCard(2 * third, yellowSpec, top)

  -- logo, centred over the split, with a gentle bob + gold glow
  local bob = math.sin(pulse * (2 * math.pi / 4)) * 6 * s
  local lx, ly = (width - logoDW) / 2, logoY + bob
  love.graphics.setBlendMode("add")
  love.graphics.setColor(1, 0.85, 0.2, 0.16 + 0.12 * (0.5 + 0.5 * math.sin(pulse * 1.6)))
  love.graphics.draw(self.logo, (width - logoDW * 1.05) / 2, ly - logoDH * 0.025, 0,
    logoScale * 1.05, logoScale * 1.05)
  love.graphics.setBlendMode("alpha")
  -- main logo, with the same sweeping shine the active buttons get
  local shineW = 0.16
  self.shineShader:send("shinePos", -shineW + ((pulse % 2.8) / 2.8) * (1 + 2 * shineW))
  self.shineShader:send("shineW", shineW)
  love.graphics.setShader(self.shineShader)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(self.logo, lx, ly, 0, logoScale, logoScale)
  love.graphics.setShader()

  -- footer: BCG mark (inverted to white, glowing brighter on hover) + warning
  local bcgHot = hoverEnabled and ptIn(self.bcgButton)
  if bcgHot then anyHover = true end
  love.graphics.setShader(self.invertShader)
  love.graphics.setBlendMode("add")
  love.graphics.setColor(1, 1, 1, bcgHot and 0.5 or 0.22)
  love.graphics.draw(self.bcg, bcgX - bcgDW * 0.02, bcgY - bcgDH * 0.02, 0,
    bcgScale * 1.04, bcgScale * 1.04)
  love.graphics.setBlendMode("alpha")
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(self.bcg, bcgX, bcgY, 0, bcgScale, bcgScale)
  love.graphics.setShader()

  -- trust warning; the bois.icu URL inside it is a real hover link
  love.graphics.setFont(self.warningFont)
  col(PAL.warning)
  love.graphics.printf(TRUST_WARNING, (width - warningWidth) / 2, warningY, warningWidth, "center")
  self.linkUrlRect = nil
  do
    local wrapX = (width - warningWidth) / 2
    local lh = self.warningFont:getHeight()
    local _, lines = self.warningFont:getWrap(TRUST_WARNING, warningWidth)
    for i, line in ipairs(lines) do
      local sidx = line:find(COMMUNITY_URL, 1, true)
      if sidx then
        -- the URL sits on a centred wrapped line: find its exact x-offset so the
        -- coloured link overdraws the plain-warning glyphs already printed there
        local before = line:sub(1, sidx - 1)
        local lineW = self.warningFont:getWidth(line)
        local ux = wrapX + (warningWidth - lineW) / 2 + self.warningFont:getWidth(before)
        local uy = warningY + (i - 1) * lh
        local uw = self.warningFont:getWidth(COMMUNITY_URL)
        self.linkUrlRect = { x = ux, y = uy, width = uw, height = lh }
        local linkHot = hoverEnabled and ptIn(self.linkUrlRect)
        if linkHot then anyHover = true end
        col(linkHot and PAL.linkHover or PAL.link)
        love.graphics.print(COMMUNITY_URL, ux, uy)
        love.graphics.setLineWidth(1)
        love.graphics.line(ux, uy + lh - 1, ux + uw, uy + lh - 1)
        break
      end
    end
  end

  -- CRT scanlines + vignette, over everything
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(self.scanlineImage, self.scanlineQuad, 0, 0)
  love.graphics.draw(self.vignetteMesh)
  love.graphics.setColor(1, 1, 1, 1)

  -- pointer cursor over any interactive element (desktop only)
  if hoverEnabled and love.mouse.isCursorSupported and love.mouse.isCursorSupported() then
    if anyHover then
      self.handCursor = self.handCursor or love.mouse.getSystemCursor("hand")
      love.mouse.setCursor(self.handCursor)
    else
      self.arrowCursor = self.arrowCursor or love.mouse.getSystemCursor("arrow")
      love.mouse.setCursor(self.arrowCursor)
    end
  end
end

local function inside(r, x, y)
  return r and x >= r.x and x <= r.x + r.width and y >= r.y and y <= r.y + r.height
end

function RomImporter:mousepressed(x, y, button)
  if button ~= 1 then return end
  if inside(self.bcgButton, x, y) or inside(self.linkUrlRect, x, y) then
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
