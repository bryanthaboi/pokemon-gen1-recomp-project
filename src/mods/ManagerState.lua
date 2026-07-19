-- Mod manager v2 (18-mod-manager-ux.md): one stack state routing a fixed
-- set of screens -- list (MODS/PROF/ERRS tabs), detail, options,
-- permissions, errors, apply -- over mapped input, so gamepad and touch
-- drive it like any other menu.  Toggles resolve their dependency closure
-- before they land, edits stage until one apply/restart, and safe mode is
-- read from Runtime.safeMode (19 owns the detection).
local Font = require("src.render.Font")
local Runtime = require("src.mods.Runtime")
local Semver = require("src.mods.Semver")
local Version = require("src.core.Version")
local Theme = require("src.ui.Theme")
local OptionRows = require("src.ui.OptionRows")

local ManagerState = {}
ManagerState.__index = ManagerState
ManagerState.isOpaque = true
-- stamped here as well as by Screens.push so the F10 toggle in
-- Game:keypressed recognizes a directly-pushed instance
ManagerState.screenId = "ManagerState"

-- the charmap has no * ~ + < > glyphs, so the status gutter uses what it
-- does have: staged-awaiting-restart, disabled, errored, dep-unhealthy
local GLYPH = { staged = ".", disabled = "-", errored = "!", blocked = "?" }

local TABS = { "MODS", "PROFILES", "ERRORS" }
local TAB_LINE = { "[MODS] PROF ERRS", "MODS [PROF] ERRS", "MODS PROF [ERRS]" }

local LIST_TOP = 3   -- first content row (tile y)
local LIST_ROWS = 11 -- single-line rows in the scroll region

-- what the mod declared it does, shown before the player enables it
local PERMISSION_ROWS = {
  engine_internals = { glyph = "!", text = "PATCHES ENGINE CODE" },
  network = { glyph = "!", text = "USES THE NETWORK" },
  filesystem = { glyph = "!", text = "READS/WRITES FILES" },
}

local OPTION_TYPES = { toggle = true, choice = true, number = true, text = true }

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

local function clampIndex(i, n)
  if i < 1 then return n end
  if i > n then return 1 end
  return i
end

-- enabled at boot is the loader's verdict, not the user's flag: setEnabled
-- flips manifest.enabled but never state, so the difference is exactly the
-- staged-since-boot set and survives closing the manager
local function bootEnabled(m)
  return m.state ~= "disabled"
end

-- ------- pure toggle resolution
-- The closure a requested flip drags along (18 "enable/disable flow").
-- mods is id -> status manifest; enabledSet is the current desired set.
-- Module-level so tests table-drive it without a game.

function ManagerState.resolveToggle(mods, id, want, enabledSet)
  local r = { apply = {}, alsoEnable = {}, alsoDisable = {},
              conflicts = {}, missing = {}, badVersion = {} }
  local function enabledAfter(mid)
    if r.apply[mid] ~= nil then return r.apply[mid] end
    return enabledSet[mid] and true or false
  end
  local function enableWalk(mid, root)
    if r.apply[mid] then return end
    r.apply[mid] = true
    if not root then r.alsoEnable[#r.alsoEnable + 1] = mid end
    local m = mods[mid]
    if not m then return end
    if m.game_version and not Semver.satisfies(Version.engine, m.game_version) then
      r.badVersion[#r.badVersion + 1] =
        { id = mid, need = m.game_version, got = Version.engine, engine = true }
    end
    for _, spec in ipairs(m.dependencySpecs or {}) do
      local dep = mods[spec.id]
      if not dep then
        r.missing[#r.missing + 1] = spec.id
      elseif spec.range and not Semver.satisfies(dep.version, spec.range) then
        r.badVersion[#r.badVersion + 1] =
          { id = spec.id, need = spec.range, got = dep.version }
      elseif not enabledAfter(spec.id) then
        enableWalk(spec.id, false)
      end
    end
  end
  local function disableWalk(mid, root)
    if r.apply[mid] == false then return end
    r.apply[mid] = false
    if not root then r.alsoDisable[#r.alsoDisable + 1] = mid end
    -- reverse hard deps: whoever needs mid has to switch off with it
    for otherId, other in pairs(mods) do
      if enabledAfter(otherId) then
        for _, spec in ipairs(other.dependencySpecs or {}) do
          if spec.id == mid then
            disableWalk(otherId, false)
            break
          end
        end
      end
    end
  end
  if want then enableWalk(id, true) else disableWalk(id, true) end
  if want then
    -- a conflict blocks whichever side declared it
    for mid in pairs(r.apply) do
      local m = mods[mid]
      for _, spec in ipairs((m and m.conflictSpecs) or {}) do
        local other = mods[spec.id]
        if other and spec.id ~= mid and enabledAfter(spec.id)
            and (not spec.range or Semver.satisfies(other.version, spec.range)) then
          r.conflicts[#r.conflicts + 1] = spec.id
        end
      end
      for otherId, other in pairs(mods) do
        if otherId ~= mid and enabledAfter(otherId) then
          for _, spec in ipairs(other.conflictSpecs or {}) do
            if spec.id == mid and (not spec.range
                or not m or Semver.satisfies(m.version, spec.range)) then
              r.conflicts[#r.conflicts + 1] = otherId
            end
          end
        end
      end
    end
  end
  return r
end

-- ------- lifecycle

function ManagerState.new(game)
  return setmetatable({
    game = game,
    screen = "list",
    tab = 1,
    cursor = 1,
    scroll = 1,
    backStack = {},
    descScroll = 1,
    restartPending = false,
  }, ManagerState)
end

function ManagerState:enter()
  self:refresh()
  if Runtime.safeMode then
    self.banner = "SAFE MODE - ALL MODS OFF"
  end
  self:snapCursor()
end

function ManagerState:refresh()
  local loader = self.game.mods
  self.status = (loader and loader.status and loader:status())
    or self.game.modStatus or { available = {}, errors = {} }
  self.byId = {}
  for _, m in ipairs(self.status.available or {}) do
    self.byId[m.id] = m
  end
  if self.currentMod then
    self.currentMod = self.byId[self.currentMod.id]
  end
  self.restartPending = #self:stagedList() > 0
  -- a live set that drifted off the named profile reverts to ad-hoc
  local opts = self:optionsTable()
  if opts.activeProfile then
    local p = self:findProfile(opts.activeProfile)
    if not p or not self:matchesProfile(p) then
      opts.activeProfile = nil
    end
  end
end

function ManagerState:optionsTable()
  local save = self.game.save
  return (save and save.options) or {}
end

function ManagerState:manifestMap()
  return self.byId or {}
end

function ManagerState:enabledSet()
  local set = {}
  for _, m in ipairs(self.status.available or {}) do
    if m.enabled then set[m.id] = true end
  end
  return set
end

function ManagerState:isStaged(m)
  return (m.enabled and true or false) ~= bootEnabled(m)
end

function ManagerState:stagedList()
  local out = {}
  for _, m in ipairs(self.status.available or {}) do
    if self:isStaged(m) then out[#out + 1] = m end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

function ManagerState:glyphFor(m)
  if self:isStaged(m) then return GLYPH.staged end
  if not m.enabled then return GLYPH.disabled end
  if m.state == "blocked_dependency" then return GLYPH.blocked end
  if m.error then return GLYPH.errored end
  return " "
end

-- ------- row models
-- Every screen is one flat row list the shared cursor walks; headers are
-- skipped by the cursor and drawn dim.

function ManagerState:modRows()
  local rows = {}
  local byCategory, categories = {}, {}
  for _, m in ipairs(self.status.available or {}) do
    local cat = m.category or "OTHER"
    if not byCategory[cat] then
      byCategory[cat] = {}
      categories[#categories + 1] = cat
    end
    table.insert(byCategory[cat], m)
  end
  table.sort(categories)
  for _, cat in ipairs(categories) do
    rows[#rows + 1] = { header = true, label = cat }
    for _, m in ipairs(byCategory[cat]) do
      rows[#rows + 1] = { mod = m, label = m.name or m.id,
                          glyph = self:glyphFor(m) }
    end
  end
  if #rows == 0 then
    rows[1] = { header = true, label = "NO MODS INSTALLED" }
  end
  return rows
end

function ManagerState:profileRows()
  local rows = {}
  local opts = self:optionsTable()
  for _, p in ipairs(opts.modProfiles or {}) do
    rows[#rows + 1] = { profile = p, label = p.name,
      glyph = opts.activeProfile == p.name and GLYPH.errored or " " }
  end
  rows[#rows + 1] = { saveAs = true, label = "SAVE CURRENT AS.." }
  rows[#rows + 1] = { adhoc = true,
    label = opts.activeProfile and "[AD-HOC]" or "[AD-HOC] (LIVE)" }
  return rows
end

function ManagerState:errorLines(mod)
  local lines = {}
  if mod and mod.error then
    for _, line in ipairs(wrap("FAILED: " .. mod.error, 16)) do
      lines[#lines + 1] = line
    end
  end
  for _, err in ipairs(self.status.errors or {}) do
    for _, line in ipairs(wrap(err, 16)) do
      lines[#lines + 1] = line
    end
  end
  if #lines == 0 then lines[1] = "NO ERRORS" end
  return lines
end

function ManagerState:errorRows(mod)
  local rows = {}
  for _, line in ipairs(self:errorLines(mod)) do
    rows[#rows + 1] = { label = line, inert = true }
  end
  return rows
end

function ManagerState:detailRows(m)
  local rows = {}
  rows[#rows + 1] = { label = m.enabled and "DISABLE" or "ENABLE",
    action = function() self:beginToggle(m) end }
  if self:schemaFor(m) then
    rows[#rows + 1] = { label = "OPTIONS..",
      action = function() self:openOptions(m) end }
  end
  if m.permissions and #m.permissions > 0 then
    rows[#rows + 1] = { label = "PERMISSIONS..",
      action = function() self:goTo("permissions") end }
  end
  if m.error then
    rows[#rows + 1] = { label = "VIEW ERROR..",
      action = function() self:goTo("errors") end }
  end
  rows[#rows + 1] = { label = "BACK", action = function() self:goBack() end }
  return rows
end

function ManagerState:applyRows()
  local rows = {}
  rows[#rows + 1] = { label = "APPLY & RESTART", action = function()
    self:openConfirm({ "RESTART NOW?" }, function() self:restartGame() end)
  end }
  rows[#rows + 1] = { label = "DISCARD CHANGES", action = function()
    self:discardChanges()
  end }
  rows[#rows + 1] = { label = "BACK", action = function() self:goBack() end }
  return rows
end

function ManagerState:permissionRows(m)
  local rows = {}
  for _, name in ipairs(m.permissions or {}) do
    local info = PERMISSION_ROWS[name]
    rows[#rows + 1] = { inert = true,
      glyph = info and info.glyph or "?",
      label = info and info.text or name }
  end
  if #rows == 0 then
    rows[1] = { inert = true, label = "DATA & API ONLY" }
  end
  return rows
end

function ManagerState:rowsForScreen()
  if self.screen == "list" then
    if self.tab == 1 then return self:modRows() end
    if self.tab == 2 then return self:profileRows() end
    return self:errorRows(nil)
  elseif self.screen == "detail" then
    return self.currentMod and self:detailRows(self.currentMod) or {}
  elseif self.screen == "errors" then
    return self:errorRows(self.currentMod)
  elseif self.screen == "permissions" then
    return self.currentMod and self:permissionRows(self.currentMod) or {}
  elseif self.screen == "apply" then
    return self:applyRows()
  end
  return {}
end

-- ------- navigation

function ManagerState:goTo(screen)
  self.backStack[#self.backStack + 1] =
    { screen = self.screen, cursor = self.cursor, scroll = self.scroll }
  self.screen = screen
  self.cursor = 1
  self.scroll = screen == "options" and 0 or 1
  self.descScroll = 1
  self:snapCursor()
end

function ManagerState:goBack()
  local prev = table.remove(self.backStack)
  if prev then
    self.screen = prev.screen
    self.cursor = prev.cursor
    self.scroll = prev.scroll
    self:refresh()
  else
    self.game.stack:pop()
  end
end

function ManagerState:snapCursor()
  local rows = self:rowsForScreen()
  local row = rows[self.cursor]
  if row and not row.header then return end
  for i, candidate in ipairs(rows) do
    if not candidate.header then
      self.cursor = i
      return
    end
  end
  self.cursor = 1
end

function ManagerState:moveCursor(dir)
  local rows = self:rowsForScreen()
  local n = #rows
  if n == 0 then return end
  local i = self.cursor
  for _ = 1, n do
    i = clampIndex(i + dir, n)
    if not rows[i].header then
      self.cursor = i
      break
    end
  end
  -- keep the cursor inside the scroll window
  if self.cursor < self.scroll then
    self.scroll = self.cursor
  elseif self.cursor > self.scroll + LIST_ROWS - 1 then
    self.scroll = self.cursor - LIST_ROWS + 1
  end
end

function ManagerState:adjustOrTab(dir)
  if self.screen == "list" then
    self.tab = clampIndex(self.tab + dir, #TABS)
    self.cursor, self.scroll = 1, 1
    self:snapCursor()
  elseif self.screen == "detail" then
    self.descScroll = math.max(1, self.descScroll + dir)
  else
    for _ = 1, LIST_ROWS do self:moveCursor(dir) end
  end
end

function ManagerState:focusedRow()
  return self:rowsForScreen()[self.cursor]
end

function ManagerState:confirmSound()
  if self.game.data then
    require("src.core.Sound").play(self.game.data, "Press_AB")
  end
end

function ManagerState:notify(text)
  self.notice = text
  self.noticeTimer = 90
end

function ManagerState:activate()
  local row = self:focusedRow()
  if not row or row.header or row.inert then return end
  self:confirmSound()
  if row.action then
    row.action()
  elseif row.mod then
    self.currentMod = row.mod
    self:goTo("detail")
  elseif row.profile then
    self:applyProfile(row.profile)
  elseif row.saveAs then
    self:saveCurrentAs()
  elseif row.adhoc then
    self:optionsTable().activeProfile = nil
    self:notify("AD-HOC SET ACTIVE")
  end
end

function ManagerState:pressStart()
  if self.screen == "list" and self.tab == 2 then
    local row = self:focusedRow()
    if row and row.profile then
      self:openConfirm({ "DELETE " .. row.profile.name .. "?" }, function()
        self:deleteProfile(row.profile)
      end)
      return
    end
  end
  if self.screen == "apply" then return end
  if self.restartPending or Runtime.safeMode then
    self:goTo("apply")
  else
    self:notify("NO CHANGES")
  end
end

function ManagerState:quickToggle()
  if self.screen == "list" and self.tab == 1 then
    local row = self:focusedRow()
    if row and row.mod then self:beginToggle(row.mod) end
  elseif self.screen == "list" and self.tab == 2 then
    local row = self:focusedRow()
    if row and row.profile then self:renameProfile(row.profile) end
  elseif self.screen == "detail" and self.currentMod then
    self:beginToggle(self.currentMod)
  end
end

function ManagerState:update()
  if self.notice then
    self.noticeTimer = (self.noticeTimer or 0) - 1
    if self.noticeTimer <= 0 then self.notice = nil end
  end
  local input = self.game.input
  if self.overlay then return self:updateOverlay(input) end
  if self.screen == "options" then return self:updateOptions(input) end
  if input:wasPressed("up") then self:moveCursor(-1)
  elseif input:wasPressed("down") then self:moveCursor(1)
  elseif input:wasPressed("left") then self:adjustOrTab(-1)
  elseif input:wasPressed("right") then self:adjustOrTab(1)
  elseif input:wasPressed("a") then self:activate()
  elseif input:wasPressed("b") then self:goBack()
  elseif input:wasPressed("start") then self:pressStart()
  elseif input:wasPressed("select") then self:quickToggle()
  end
end

-- ------- overlays

function ManagerState:openBlocked(r)
  local lines = {}
  for _, depId in ipairs(r.missing) do
    lines[#lines + 1] = "NEEDS " .. depId
    lines[#lines + 1] = "NOT INSTALLED"
  end
  for _, otherId in ipairs(r.conflicts) do
    local other = self.byId[otherId]
    lines[#lines + 1] = "CONFLICTS WITH"
    lines[#lines + 1] = (other and other.name or otherId)
    lines[#lines + 1] = "DISABLE IT FIRST"
  end
  for _, bad in ipairs(r.badVersion) do
    if bad.engine then
      lines[#lines + 1] = "NEEDS ENGINE " .. bad.need
      lines[#lines + 1] = "HAVE " .. bad.got
    else
      lines[#lines + 1] = "NEEDS " .. bad.id .. " " .. bad.need
    end
  end
  self.overlay = { kind = "ok", lines = lines }
end

function ManagerState:openCascade(r, m, want)
  local lines = {}
  if want then
    local names = {}
    for _, depId in ipairs(r.alsoEnable) do
      local dep = self.byId[depId]
      names[#names + 1] = dep and dep.name or depId
    end
    lines[#lines + 1] = "ALSO ENABLE"
    lines[#lines + 1] = table.concat(names, ", ") .. "?"
  else
    local dep = self.byId[r.alsoDisable[1]]
    lines[#lines + 1] = (dep and dep.name or r.alsoDisable[1]) .. " NEEDS THIS."
    lines[#lines + 1] = #r.alsoDisable > 1 and "DISABLE ALL?" or "DISABLE BOTH?"
  end
  self.overlay = { kind = "confirm", lines = lines, index = 1,
    onYes = function() self:commitToggle(r.apply) end }
end

function ManagerState:openConfirm(lines, onYes)
  self.overlay = { kind = "confirm", lines = lines, index = 1, onYes = onYes }
end

function ManagerState:updateOverlay(input)
  local overlay = self.overlay
  if overlay.kind == "ok" then
    if input:wasPressed("a") or input:wasPressed("b") then
      self.overlay = nil
    end
    return
  end
  if input:wasPressed("up") or input:wasPressed("down") then
    overlay.index = overlay.index == 1 and 2 or 1
  elseif input:wasPressed("a") then
    self:confirmSound()
    self.overlay = nil
    if overlay.index == 1 and overlay.onYes then overlay.onYes() end
  elseif input:wasPressed("b") then
    self.overlay = nil
  end
end

-- ------- the enable/disable flow

function ManagerState:beginToggle(m)
  if not m then return end
  local want = not m.enabled
  local loader = self.game.mods
  local r
  if loader and loader.resolveToggle then
    r = loader:resolveToggle(m.id, want, self:enabledSet())
  else
    r = ManagerState.resolveToggle(self:manifestMap(), m.id, want,
                                   self:enabledSet())
  end
  if #r.missing > 0 or #r.conflicts > 0 or #r.badVersion > 0 then
    self:openBlocked(r)
  elseif #r.alsoEnable > 0 or #r.alsoDisable > 0 then
    self:openCascade(r, m, want)
  else
    self:commitToggle(r.apply)
  end
end

function ManagerState:commitToggle(apply)
  local loader = self.game.mods
  local opts = self:optionsTable()
  for id, en in pairs(apply) do
    if loader and loader.setEnabled then loader:setEnabled(id, en) end
    -- mirror into the live options so a later writeOptions cannot revert
    -- what setEnabled just persisted
    opts.mods = opts.mods or {}
    opts.mods[id] = en
  end
  if loader and loader.status then self.game.modStatus = loader:status() end
  self:refresh()
end

function ManagerState:discardChanges()
  local loader = self.game.mods
  local opts = self:optionsTable()
  for _, m in ipairs(self:stagedList()) do
    local en = bootEnabled(m)
    if loader and loader.setEnabled then loader:setEnabled(m.id, en) end
    opts.mods = opts.mods or {}
    opts.mods[m.id] = en
  end
  if loader and loader.status then self.game.modStatus = loader:status() end
  self:refresh()
  self:notify("CHANGES DISCARDED")
end

function ManagerState:restartGame()
  if self.game.restartWithMods then
    self.game:restartWithMods()
  elseif love.event and love.event.quit then
    love.event.quit("restart")
  end
end

-- ------- profiles (named enable-sets, not the manifest profile field)

function ManagerState:findProfile(name)
  for _, p in ipairs(self:optionsTable().modProfiles or {}) do
    if p.name == name then return p end
  end
  return nil
end

function ManagerState:matchesProfile(p)
  for _, m in ipairs(self.status.available or {}) do
    local want = p.enabled[m.id] ~= false
    if (m.enabled and true or false) ~= want then return false end
  end
  return true
end

function ManagerState:persistOptions()
  if self.game.writeOptions then self.game:writeOptions() end
end

function ManagerState:applyProfile(p)
  local mods = self:manifestMap()
  local set = self:enabledSet()
  local combined = {}
  for _, m in ipairs(self.status.available or {}) do
    local want = p.enabled[m.id] ~= false
    local cur = set[m.id] and true or false
    if cur ~= want then
      local r = ManagerState.resolveToggle(mods, m.id, want, set)
      if #r.missing > 0 or #r.conflicts > 0 or #r.badVersion > 0 then
        self:openBlocked(r)
        return
      end
      for id, en in pairs(r.apply) do
        combined[id] = en
        set[id] = en or nil
      end
    end
  end
  self:commitToggle(combined)
  self:optionsTable().activeProfile = p.name
  self:persistOptions()
  self:notify("PROFILE STAGED")
end

function ManagerState:saveCurrentAs()
  local NamingScreen = require("src.ui.NamingScreen")
  self.game.stack:push(NamingScreen.new(self.game, {
    title = "PROFILE NAME?",
    maxLen = 10,
    onDone = function(name)
      local opts = self:optionsTable()
      opts.modProfiles = opts.modProfiles or {}
      local enabled = {}
      for _, m in ipairs(self.status.available or {}) do
        enabled[m.id] = m.enabled and true or false
      end
      local existing = self:findProfile(name)
      if existing then
        existing.enabled = enabled
      else
        opts.modProfiles[#opts.modProfiles + 1] =
          { name = name, enabled = enabled }
      end
      opts.activeProfile = name
      self:persistOptions()
      self:refresh()
    end,
  }))
end

function ManagerState:renameProfile(p)
  local NamingScreen = require("src.ui.NamingScreen")
  self.game.stack:push(NamingScreen.new(self.game, {
    title = "RENAME?",
    maxLen = 10,
    default = p.name,
    onDone = function(name)
      local opts = self:optionsTable()
      if opts.activeProfile == p.name then opts.activeProfile = name end
      p.name = name
      self:persistOptions()
    end,
  }))
end

function ManagerState:deleteProfile(p)
  local opts = self:optionsTable()
  local profiles = opts.modProfiles or {}
  for i, candidate in ipairs(profiles) do
    if candidate == p then
      table.remove(profiles, i)
      break
    end
  end
  if opts.activeProfile == p.name then opts.activeProfile = nil end
  self:persistOptions()
  self:snapCursor()
end

-- ------- per-mod options (auto-UI from options_schema)

-- the loader captured schemas when mod.options:define ran; a mod that only
-- shipped the manifest options_schema file gets it loaded here on demand
function ManagerState:schemaFor(m)
  local loader = self.game.mods
  if not loader then return nil end
  local schema = loader.optionSchemas and loader.optionSchemas[m.id]
  if schema == nil and m.options_schema and m.path
      and loader.fs and loader.fs.load then
    local chunk = loader.fs.load(m.path .. "/" .. m.options_schema)
    if chunk then
      local ok, rows = pcall(chunk)
      if ok and type(rows) == "table" then
        schema = rows
        if loader.optionSchemas then loader.optionSchemas[m.id] = schema end
      end
    end
  end
  return schema
end

function ManagerState:optionValue(modId, row)
  local loader = self.game.mods
  local stored = loader and loader.modOptions and loader.modOptions[modId]
  local v = stored and stored[row.key]
  if v == nil then v = row.default end
  return v
end

function ManagerState:setOption(modId, key, value)
  local save = self.game.save
  if save and save.options then
    save.options.modOptions = save.options.modOptions or {}
    local t = save.options.modOptions
    t[modId] = t[modId] or {}
    t[modId][key] = value
  end
  local loader = self.game.mods
  if loader then
    loader.modOptions = loader.modOptions or {}
    loader.modOptions[modId] = loader.modOptions[modId] or {}
    loader.modOptions[modId][key] = value
  end
  self:persistOptions()
  if loader and loader.events then
    loader.events:emit("mod.options_changed",
      { mod = modId, key = key, value = value })
  end
end

function ManagerState:buildOptionRows(m, schema)
  local rows = {}
  local modId = m.id
  for _, row in ipairs(schema) do
    if type(row) ~= "table" or type(row.key) ~= "string" or row.key == ""
        or not OPTION_TYPES[row.type] then
      -- malformed rows are skipped, reported where the errors screen reads
      Runtime.reportError(modId, "options row skipped: "
        .. tostring(type(row) == "table" and (row.key or row.type) or row))
    elseif row.type == "toggle" then
      rows[#rows + 1] = { id = row.key, label = row.label or row.key,
        value = function()
          return self:optionValue(modId, row) and "ON" or "OFF"
        end,
        step = function()
          self:setOption(modId, row.key, not self:optionValue(modId, row))
          return true
        end }
    elseif row.type == "choice" then
      rows[#rows + 1] = { id = row.key, label = row.label or row.key,
        value = function()
          local cur = self:optionValue(modId, row)
          for _, choice in ipairs(row.choices or {}) do
            if choice[2] == cur then return choice[1] end
          end
          local first = (row.choices or {})[1]
          return first and first[1] or "----"
        end,
        step = function(_, dir)
          local choices = row.choices or {}
          if #choices == 0 then return false end
          local cur = self:optionValue(modId, row)
          local index = 1
          for i, choice in ipairs(choices) do
            if choice[2] == cur then index = i break end
          end
          index = clampIndex(index + dir, #choices)
          self:setOption(modId, row.key, choices[index][2])
          return true
        end }
    elseif row.type == "number" then
      local function clamp(v)
        if row.min then v = math.max(row.min, v) end
        if row.max then v = math.min(row.max, v) end
        return v
      end
      rows[#rows + 1] = { id = row.key, label = row.label or row.key,
        value = function()
          return tostring(self:optionValue(modId, row) or 0)
        end,
        step = function(_, dir)
          local cur = tonumber(self:optionValue(modId, row)) or 0
          self:setOption(modId, row.key, clamp(cur + dir * (row.step or 1)))
          return true
        end,
        activate = function()
          local QuantityBox = require("src.ui.QuantityBox")
          self.game.stack:push(QuantityBox.new(self.game, {
            max = row.max or 99,
            start = math.max(1, tonumber(self:optionValue(modId, row)) or 1),
            onDone = function(qty)
              if qty then self:setOption(modId, row.key, clamp(qty)) end
            end,
          }))
        end }
    elseif row.type == "text" then
      rows[#rows + 1] = { id = row.key, label = row.label or row.key,
        value = function()
          return tostring(self:optionValue(modId, row) or "")
        end,
        activate = function()
          local NamingScreen = require("src.ui.NamingScreen")
          self.game.stack:push(NamingScreen.new(self.game, {
            title = (row.label or row.key) .. "?",
            maxLen = row.maxLen or 7,
            default = self:optionValue(modId, row),
            onDone = function(name)
              self:setOption(modId, row.key, name)
            end,
          }))
        end }
    end
  end
  rows[#rows + 1] = { id = "__reset", label = "RESET DEFAULTS",
    value = function() return "" end,
    activate = function()
      for _, row in ipairs(schema) do
        if type(row) == "table" and type(row.key) == "string"
            and OPTION_TYPES[row.type] then
          self:setOption(modId, row.key, row.default)
        end
      end
      self:notify("DEFAULTS RESTORED")
    end }
  return rows
end

function ManagerState:openOptions(m)
  local schema = self:schemaFor(m)
  if not schema then
    self:notify("NO OPTIONS")
    return
  end
  self.optionRows = self:buildOptionRows(m, schema)
  self:goTo("options")
end

function ManagerState:updateOptions(input)
  local rows = self.optionRows or {}
  local n = #rows
  if input:wasPressed("b") then
    self:goBack()
    return
  end
  if n == 0 then return end
  if input:wasPressed("up") then
    self.cursor = clampIndex(self.cursor - 1, n)
  elseif input:wasPressed("down") then
    self.cursor = clampIndex(self.cursor + 1, n)
  elseif input:wasPressed("left") or input:wasPressed("right")
      or input:wasPressed("a") then
    local dir = input:wasPressed("left") and -1 or 1
    local row = rows[self.cursor]
    if row.activate and input:wasPressed("a") then
      self:confirmSound()
      row.activate()
    elseif row.step then
      row.step(self.game, dir)
    end
  end
  self.scroll = OptionRows.clampScroll(self.cursor, self.scroll or 0, n, nil)
end

-- ------- drawing

local function drawTruncated(text, x, y, cols)
  text = tostring(text or "")
  if #text > cols then text = text:sub(1, cols) end
  Font.draw(text, x, y)
end

function ManagerState:drawRows(rows)
  local last = math.min(#rows, self.scroll + LIST_ROWS - 1)
  local y = LIST_TOP
  for i = self.scroll, last do
    local row = rows[i]
    if row.header then
      drawTruncated(row.label, 16, y * 8, 17)
    else
      if row.glyph and row.glyph ~= " " then
        Font.draw(row.glyph, 16, y * 8)
      end
      drawTruncated(row.label, 32, y * 8, 15)
      if i == self.cursor then
        Font.drawCode(Theme.cursor, 8, y * 8)
      end
    end
    y = y + 1
  end
  if #rows > last then
    Font.drawCode(Theme.moreArrow, 18 * 8, (LIST_TOP + LIST_ROWS) * 8)
  end
end

function ManagerState:drawFooter(line1, line2)
  if self.notice then
    Font.draw(self.notice, 16, 15 * 8)
    return
  end
  if line1 then Font.draw(line1, 16, 15 * 8) end
  if line2 then Font.draw(line2, 16, 16 * 8) end
end

function ManagerState:drawList()
  Font.draw(TAB_LINE[self.tab], 16, 2 * 8)
  self:drawRows(self:rowsForScreen())
  if self.tab == 1 then
    self:drawFooter("A:OPEN SEL:TOGGLE", "START:APPLY B:EXIT")
  elseif self.tab == 2 then
    self:drawFooter("A:APPLY SEL:RENAME", "START:DELETE")
  else
    self:drawFooter("UP/DOWN:SCROLL")
  end
end

function ManagerState:drawDetail()
  local m = self.currentMod
  if not m then return end
  local title = wrap(m.name or m.id, 14)
  drawTruncated(title[1] .. " " .. (m.version or ""), 16, 2 * 8, 17)
  local statusLine = m.enabled and "ENABLED" or "DISABLED"
  if m.state == "blocked_dependency" then
    statusLine = statusLine .. " ?"
  elseif m.error then
    statusLine = statusLine .. " !"
  end
  if self:isStaged(m) then statusLine = statusLine .. " (STAGED)" end
  drawTruncated(statusLine, 16, 3 * 8, 17)
  drawTruncated((m.category or "OTHER") .. " / " .. (m.profile or "content"),
                16, 4 * 8, 17)
  local lines = wrap(m.error and ("FAILED: " .. m.error) or m.description, 16)
  local visible = 5
  for i = 1, visible do
    local line = lines[self.descScroll + i - 1]
    if not line then break end
    Font.draw(line, 16, (5 + i) * 8)
  end
  if self.descScroll + visible <= #lines then
    Font.drawCode(Theme.moreArrow, 17 * 8, 10 * 8)
  end
  local rows = self:rowsForScreen()
  local y = 11
  for i, row in ipairs(rows) do
    drawTruncated(row.label, 32, y * 8, 15)
    if i == self.cursor then Font.drawCode(Theme.cursor, 24, y * 8) end
    y = y + 1
  end
  self:drawFooter("A:CHOOSE B:BACK")
end

function ManagerState:drawPermissions()
  drawTruncated("PERMISSIONS", 16, 2 * 8, 17)
  self:drawRows(self:rowsForScreen())
  self:drawFooter("DECLARED BY AUTHOR,", "NOT ENFORCED")
end

function ManagerState:drawErrors()
  drawTruncated("ERRORS", 16, 2 * 8, 17)
  self:drawRows(self:rowsForScreen())
  self:drawFooter("UP/DOWN:SCROLL B:BACK")
end

function ManagerState:drawApply()
  drawTruncated("PENDING CHANGES", 16, 2 * 8, 17)
  local staged = self:stagedList()
  local y = LIST_TOP
  local shown = math.min(#staged, 7)
  for i = 1, shown do
    local m = staged[i]
    local verb = m.enabled and "ON " or "OFF "
    drawTruncated(verb .. (m.name or m.id), 16, y * 8, 17)
    y = y + 1
  end
  if #staged == 0 then
    Font.draw(Runtime.safeMode and "SAFE MODE" or "NO CHANGES", 16, y * 8)
    y = y + 1
  end
  local rows = self:rowsForScreen()
  local base = 12
  for i, row in ipairs(rows) do
    drawTruncated(row.label, 32, (base + i - 1) * 8, 15)
    if i == self.cursor then Font.drawCode(Theme.cursor, 24, (base + i - 1) * 8) end
  end
  self:drawFooter("A:CHOOSE B:BACK")
end

function ManagerState:drawOverlay()
  local overlay = self.overlay
  local lines = {}
  for _, raw in ipairs(overlay.lines) do
    for _, line in ipairs(wrap(raw, 14)) do lines[#lines + 1] = line end
  end
  local th = math.max(6, #lines + (overlay.kind == "confirm" and 5 or 3))
  local ty = math.max(1, math.floor((18 - th) / 2))
  love.graphics.setColor(0, 0, 0, 1)
  love.graphics.rectangle("fill", 2 * 8, ty * 8, 16 * 8, th * 8)
  love.graphics.setColor(1, 1, 1, 1)
  Font.drawBox(2, ty, 16, th)
  for i, line in ipairs(lines) do
    drawTruncated(line, 4 * 8, (ty + i) * 8, 14)
  end
  if overlay.kind == "confirm" then
    local yesY = ty + #lines + 1
    Font.draw("YES", 5 * 8, yesY * 8)
    Font.draw("NO", 5 * 8, (yesY + 1) * 8)
    Font.drawCode(Theme.cursor, 4 * 8,
                  (overlay.index == 1 and yesY or yesY + 1) * 8)
  else
    Font.draw("A:OK", 5 * 8, (ty + #lines + 1) * 8)
  end
end

function ManagerState:draw()
  if self.screen == "options" then
    OptionRows.draw(self.game, self.optionRows or {}, self.cursor,
                    self.scroll or 0)
    love.graphics.setColor(0, 0, 0, 1)
    Font.draw(self.notice or "B:DONE (NO RESTART)", 8, 136)
    love.graphics.setColor(1, 1, 1, 1)
    if self.overlay then self:drawOverlay() end
    return
  end
  love.graphics.setColor(0, 0, 0, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 144)
  love.graphics.setColor(1, 1, 1, 1)
  Font.drawBox(0, 0, 20, 18)
  Font.draw(self.banner or "MOD MANAGER", 16, 8)
  if self.screen == "list" then
    self:drawList()
  elseif self.screen == "detail" then
    self:drawDetail()
  elseif self.screen == "permissions" then
    self:drawPermissions()
  elseif self.screen == "errors" then
    self:drawErrors()
  elseif self.screen == "apply" then
    self:drawApply()
  end
  if self.overlay then self:drawOverlay() end
end

return ManagerState
