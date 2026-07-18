local Json = require("src.link.Json")
local Logger = require("src.core.Logger")
local SaveData = require("src.core.SaveData")
local Manifest = require("src.mods.Manifest")
local Registry = require("src.mods.Registry")
local Events = require("src.mods.Events")
local Hooks = require("src.mods.Hooks")

local Loader = {}
Loader.__index = Loader

local REGISTRY_NAMES = {
  "pokemon", "moves", "items", "maps", "tilesets", "encounters",
  "trainers", "sprites", "music", "audio", "text", "scripts", "ui",
}

local MOD_STATE_FILE = "mod_state.lua" -- legacy migration only

local function readManifest(root)
  local raw, err = love.filesystem.read(root .. "/manifest.json")
  if not raw then return nil, err end
  local data, decodeErr = Json.decode(raw)
  if not data then return nil, decodeErr end
  local ok, manifest = pcall(Manifest.validate, data, root)
  if not ok then return nil, manifest end
  return manifest
end

local function topoSort(mods)
  local ordered, visiting, visited = {}, {}, {}
  local function visit(id)
    if visited[id] then return end
    if visiting[id] then error("circular mod dependency involving " .. id) end
    local mod = mods[id]
    if not mod then error("missing required mod dependency: " .. id) end
    visiting[id] = true
    for _, dependency in ipairs(mod.manifest.dependencies) do visit(dependency) end
    visiting[id], visited[id] = nil, true
    ordered[#ordered + 1] = mod
  end
  local ids = {}
  for id in pairs(mods) do ids[#ids + 1] = id end
  table.sort(ids, function(a, b)
    local pa, pb = mods[a].manifest.priority, mods[b].manifest.priority
    if pa == pb then return a < b end
    return pa < pb
  end)
  for _, id in ipairs(ids) do visit(id) end
  return ordered
end

function Loader.new()
  local self = setmetatable({
    mods = {}, loaded = {}, errors = {}, initialized = false,
    events = Events.new(), hooks = Hooks.new(), content = {}, assets = {},
  }, Loader)
  for _, name in ipairs(REGISTRY_NAMES) do
    self.content[name] = Registry.new(name)
  end
  self.disabled = {}
  return self
end

function Loader:_loadState()
  self.disabled = {}
  local options = SaveData.loadOptions()
  for id, enabled in pairs(options.mods or {}) do
    if enabled == false then self.disabled[id] = true end
  end
  -- Migrate the original prototype manager's separate state file into the
  -- normal persistent options file once.  New Game never resets options.
  if next(options.mods or {}) == nil and love.filesystem.getInfo
      and love.filesystem.getInfo(MOD_STATE_FILE) then
    local chunk = love.filesystem.load(MOD_STATE_FILE)
    local ok, state = chunk and pcall(chunk)
    if ok and type(state) == "table" then
      for id, disabled in pairs(state) do
        if disabled then
          options.mods[id] = false
          self.disabled[id] = true
        end
      end
      SaveData.saveOptions(options)
    end
  end
end

function Loader:_saveState()
  local options = SaveData.loadOptions()
  options.mods = options.mods or {}
  for id in pairs(self.mods) do
    options.mods[id] = not self.disabled[id]
  end
  SaveData.saveOptions(options)
end

function Loader:setEnabled(id, enabled)
  if not self.mods[id] then return false end
  self.disabled[id] = not enabled
  self.mods[id].enabled = enabled
  self:_saveState()
  return true
end

function Loader:_discover()
  if not love.filesystem.getDirectoryItems then return end
  local roots = { "mods" }
  for _, root in ipairs(roots) do
    if love.filesystem.getInfo(root) then
      for _, name in ipairs(love.filesystem.getDirectoryItems(root)) do
        local path = root .. "/" .. name
        local info = love.filesystem.getInfo(path)
        if info and info.type == "directory" then
          local manifest, err = readManifest(path)
          if manifest then
            if self.mods[manifest.id] then
              self.errors[#self.errors + 1] = manifest.id .. ": duplicate mod id"
            else
              self.mods[manifest.id] = { manifest = manifest, path = path }
            end
          else
            Logger.warn("mod %s ignored: %s", path, tostring(err))
          end
        end
      end
    end
  end
end

function Loader:_api(mod)
  local loader = self
  local api = {
    id = mod.manifest.id,
    version = mod.manifest.version,
    path = mod.path,
    content = {},
    events = { on = function(_, name, callback, priority)
      return loader.events:on(name, callback, priority)
    end },
    hooks = { wrap = function(_, name, callback, priority)
      return loader.hooks:wrap(name, callback, priority)
    end },
    log = {
      info = function(_, fmt, ...) Logger.info("[%s] " .. fmt, mod.manifest.id, ...) end,
      warn = function(_, fmt, ...) Logger.warn("[%s] " .. fmt, mod.manifest.id, ...) end,
      error = function(_, fmt, ...) Logger.error("[%s] " .. fmt, mod.manifest.id, ...) end,
    },
  }
  for _, name in ipairs(REGISTRY_NAMES) do
    api.content[name] = {
      register = function(_, id, value)
        return loader.content[name]:register(id, value, mod.manifest.id)
      end,
      override = function(_, id, value)
        return loader.content[name]:override(id, value, mod.manifest.id)
      end,
      get = function(_, id)
        return loader.content[name]:get(id)
          or (loader.baseData and loader.baseData[name]
              and loader.baseData[name][id])
      end,
    }
  end
  api.assets = api.content
  function api:read(relative)
    local path = self.path .. "/" .. relative
    return love.filesystem.read(path)
  end
  return api
end

function Loader:_loadMod(mod)
  local path = mod.path .. "/" .. mod.manifest.entry
  local chunk, err = love.filesystem.load(path)
  if not chunk then error(err or ("unable to load " .. path)) end
  local api = self:_api(mod)
  local result = chunk(api)
  if type(result) == "function" then result(api) end
end

function Loader:load(data)
  self.baseData = data
  self:_loadState()
  self:_discover()
  local ok, ordered = pcall(topoSort, self.mods)
  if not ok then
    self.errors[#self.errors + 1] = ordered
    Logger.error("mod dependency resolution failed: %s", tostring(ordered))
    return false
  end
  for _, mod in ipairs(ordered) do
    mod.enabled = not self.disabled[mod.manifest.id]
    local success, err = true, nil
    if mod.enabled then
      success, err = pcall(self._loadMod, self, mod)
    end
    if success and mod.enabled then
      self.loaded[#self.loaded + 1] = mod
      Logger.info("loaded mod %s %s", mod.manifest.id, mod.manifest.version)
    else
      self.errors[#self.errors + 1] = mod.manifest.id .. ": " .. tostring(err)
      Logger.error("mod %s failed: %s", mod.manifest.id, tostring(err))
    end
  end
  -- Native content registrations override the imported base definitions.
  for name, registry in pairs(self.content) do
    local target = data and data[name]
    if name == "music" and data and data.audio then
      data.audio.songs = data.audio.songs or {}
      target = data.audio.songs
    end
    if type(target) == "table" then
      for id, value in pairs(registry.values) do target[id] = value end
    end
  end
  self.events:emit("mods.loaded", { loader = self, data = data })
  self.events:seal()
  self.hooks:seal()
  self.initialized = true
  return #self.errors == 0
end

function Loader:status()
  local available, loaded = {}, {}
  for _, mod in pairs(self.mods) do
    local manifest = {}
    for key, value in pairs(mod.manifest) do manifest[key] = value end
    manifest.enabled = mod.enabled ~= false
    available[#available + 1] = manifest
    if manifest.enabled then loaded[#loaded + 1] = manifest end
  end
  table.sort(available, function(a, b) return a.id < b.id end)
  table.sort(loaded, function(a, b) return a.id < b.id end)
  return { available = available, loaded = loaded, errors = self.errors }
end

return Loader
