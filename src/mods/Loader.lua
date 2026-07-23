local Json = require("src.link.Json")
local Logger = require("src.core.Logger")
local SaveData = require("src.core.SaveData")
local Data = require("src.core.Data")
local Version = require("src.core.Version")
local Assets = require("src.render.Assets")
local ModUI = require("src.ui.ModUI")
local AssetTransform = require("src.mods.AssetTransform")
local Manifest = require("src.mods.Manifest")
local Merge = require("src.mods.Merge")
local Registry = require("src.mods.Registry")
local Schemas = require("src.mods.Schemas")
local Semver = require("src.mods.Semver")
local Events = require("src.mods.Events")
local Hooks = require("src.mods.Hooks")
local Runtime = require("src.mods.Runtime")

local Loader = {}
Loader.__index = Loader

local MOD_STATE_FILE = "mod_state.lua" -- legacy migration only

-- walk a dotted target path without creating anything; the base view a
-- registry folds against must never perturb Data on a mod-free boot
local function resolvePath(root, path)
  local node = root
  for key in path:gmatch("[^%.]+") do
    if type(node) ~= "table" then return nil end
    node = node[key]
  end
  return node
end

local function readManifest(fs, root)
  local raw, err = fs.read(root .. "/manifest.json")
  if not raw then return nil, err end
  local data, decodeErr = Json.decode(raw)
  if not data then return nil, decodeErr end
  local ok, manifest = pcall(Manifest.validate, data, root)
  if not ok then return nil, manifest end
  return manifest
end

-- the ordering contract every phase walks in: priority ascending, ties by id
local function orderedIds(mods, filter)
  local ids = {}
  for id, mod in pairs(mods) do
    if not filter or filter(mod) then ids[#ids + 1] = id end
  end
  table.sort(ids, function(a, b)
    local pa, pb = mods[a].manifest.priority, mods[b].manifest.priority
    if pa == pb then return a < b end
    return pa < pb
  end)
  return ids
end

-- ------- dev-mode permissions tripwire
-- Attribution only: the shim delegates unconditionally and blocks nothing.
-- Installed once per process and only when the loader runs in dev mode, so a
-- player build has zero interposition.

local devShim = { installed = false, permissions = {}, warned = {}, depth = 0 }

-- the src.* modules the mod surface points authors at: another mod's
-- exports carry a version string that wants range-checking before use, and
-- ChipAsm is the authoring path for chip music and sfx
local SUPPORTED_REQUIRES = {
  ["src.mods.Semver"] = true,
  ["src.audio.ChipAsm"] = true,
}

local function scanRequire(name)
  local modId = Runtime.currentMod
  if not modId or type(name) ~= "string" then return end
  local granted = devShim.permissions[modId] or {}
  local function warnOnce(permission)
    local key = modId .. "|" .. permission .. "|" .. name
    if devShim.warned[key] then return end
    devShim.warned[key] = true
    Logger.warn("[%s] undeclared %s require: %s", modId, permission, name)
  end
  -- link modules are the one place a mod can reach the wire, so network is
  -- the permission that governs them
  if name:match("^src%.link%.") then
    if not granted.network then warnOnce("network") end
  elseif name:match("^src%.") and not SUPPORTED_REQUIRES[name]
      and not granted.engine_internals then
    warnOnce("engine_internals")
  end
end

-- the genuine require, captured before the shim can replace it
local rawRequire = require

-- a module the loader pulls in late on the mod's behalf.  The mod asked for
-- a facade, not for this module nor for whatever it drags in, so the whole
-- load runs at shim depth and neither level is attributed to the mod.
local function engineRequire(name)
  devShim.depth = devShim.depth + 1
  local ok, module = pcall(rawRequire, name)
  devShim.depth = devShim.depth - 1
  if not ok then return nil end
  return module
end

function Loader:_installDevShim()
  for id, mod in pairs(self.mods) do
    devShim.permissions[id] = mod.manifest.permissionSet
  end
  if devShim.installed then return end
  devShim.installed = true
  local delegate = require
  _G.require = function(name, ...)
    -- only the mod's own call is the mod's doing; whatever that module
    -- requires in turn is the engine wiring itself up
    if devShim.depth == 0 then scanRequire(name) end
    devShim.depth = devShim.depth + 1
    local ok, result = pcall(delegate, name, ...)
    devShim.depth = devShim.depth - 1
    if not ok then error(result, 0) end
    return result
  end
end

-- opts.fs injects a filesystem (read/getInfo/load/getDirectoryItems, plus
-- write where enable-state should persist) so the loader runs headless under
-- plain Lua; the default is love.filesystem.  opts.dev forces the dev-mode
-- tripwire on for tests that cannot set the environment.
function Loader.new(opts)
  local dev = opts and opts.dev
  if dev == nil then
    dev = os.getenv("POKEPORT_DEV") == "1" or _G.POKEPORT_DEV_MODE == true
  end
  local self = setmetatable({
    mods = {}, loaded = {}, errors = {}, initialized = false,
    events = Events.new(), hooks = Hooks.new(), content = {}, assets = {},
    exports = {}, migrations = {}, order = {},
    modSave = {}, modOptions = {}, optionSchemas = {}, imageCache = {},
    fs = (opts and opts.fs) or (love and love.filesystem),
    dev = dev,
  }, Loader)
  assert(self.fs, "Loader.new requires opts.fs when love is unavailable")
  for name, spec in pairs(Schemas.REGISTRIES) do
    self.content[name] = Registry.new(name, spec)
  end
  self.disabled = {}
  return self
end

function Loader:_loadState()
  self.disabled = {}
  local options = SaveData.loadOptions(self.fs)
  for id, enabled in pairs(options.mods or {}) do
    if enabled == false then self.disabled[id] = true end
  end
  -- mod.options reads through this; M11 owns writing it back
  self.modOptions = options.modOptions or {}
  -- Migrate the original prototype manager's separate state file into the
  -- normal persistent options file once.  New Game never resets options.
  if next(options.mods or {}) == nil and self.fs.getInfo
      and self.fs.getInfo(MOD_STATE_FILE) then
    local chunk = self.fs.load(MOD_STATE_FILE)
    local ok, state = chunk and pcall(chunk)
    if ok and type(state) == "table" then
      for id, disabled in pairs(state) do
        if disabled then
          options.mods[id] = false
          self.disabled[id] = true
        end
      end
      if self.fs.write then SaveData.saveOptions(options, self.fs) end
    end
  end
end

function Loader:_saveState()
  -- a read-only injected fs keeps enable toggles in-memory only
  if not self.fs.write then return end
  local options = SaveData.loadOptions(self.fs)
  options.mods = options.mods or {}
  for id in pairs(self.mods) do
    options.mods[id] = not self.disabled[id]
  end
  SaveData.saveOptions(options, self.fs)
end

function Loader:setEnabled(id, enabled)
  if not self.mods[id] then return false end
  self.disabled[id] = not enabled
  self.mods[id].enabled = enabled
  self:_saveState()
  return true
end

function Loader:_discover()
  if not self.fs.getDirectoryItems then return end
  local roots = { "mods" }
  for _, root in ipairs(roots) do
    if self.fs.getInfo(root) then
      for _, name in ipairs(self.fs.getDirectoryItems(root)) do
        local path = root .. "/" .. name
        local info = self.fs.getInfo(path)
        if info and info.type == "directory" then
          local manifest, err = readManifest(self.fs, path)
          if manifest then
            if self.mods[manifest.id] then
              self.errors[#self.errors + 1] =
                ("%s: duplicate mod id (ignored %s)"):format(manifest.id, path)
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

-- ------- validate and resolve

-- a failed mod keeps the user's enable flag (the manager still shows it as
-- enabled-but-broken) and is treated as absent by every later phase
function Loader:_fail(mod, state, reason)
  if mod.failed then return end
  mod.failed, mod.state, mod.failure = true, state, reason
  self.errors[#self.errors + 1] = mod.manifest.id .. ": " .. reason
  Logger.error("mod %s failed: %s", mod.manifest.id, reason)
end

local function isActive(mod)
  return mod.enabled and not mod.failed
end

function Loader:_exists(path)
  if not self.fs.getInfo then return true end
  return self.fs.getInfo(path) ~= nil
end

-- static per-manifest checks that need the filesystem or the engine version.
-- Enabled mods only: a mod the user switched off is not a boot problem
function Loader:_validate()
  for _, id in ipairs(orderedIds(self.mods, isActive)) do
    local mod = self.mods[id]
    local manifest = mod.manifest
    local reason
    if not self:_exists(mod.path .. "/" .. manifest.entry) then
      reason = "entry file missing: " .. manifest.entry
    elseif manifest.options_schema
        and not self:_exists(mod.path .. "/" .. manifest.options_schema) then
      reason = "options_schema file missing: " .. manifest.options_schema
    elseif manifest.assets_transforms
        and not self:_exists(mod.path .. "/" .. manifest.assets_transforms) then
      reason = "assets_transforms file missing: " .. manifest.assets_transforms
    elseif manifest.game_version then
      local ok, err = Semver.satisfies(Version.engine, manifest.game_version)
      if not ok then
        reason = ("needs game version %s, engine is %s")
          :format(manifest.game_version, Version.engine)
        if err then reason = reason .. " (" .. err .. ")" end
      end
    end
    if reason then self:_fail(mod, "invalid", reason) end
  end
end

-- hard dependencies must exist, be enabled, have survived, and satisfy their
-- range; run to a fixpoint so failures propagate to dependents transitively
function Loader:_enforceDependencies()
  local changed = true
  while changed do
    changed = false
    for _, id in ipairs(orderedIds(self.mods, isActive)) do
      local mod = self.mods[id]
      for _, spec in ipairs(mod.manifest.dependencySpecs) do
        local dep = self.mods[spec.id]
        local reason
        if not dep then
          reason = "missing dependency: " .. spec.id
        elseif not dep.enabled then
          reason = ("dependency %s is disabled"):format(spec.id)
        elseif dep.failed then
          reason = ("dependency %s failed to load"):format(spec.id)
        elseif spec.range
            and not Semver.satisfies(dep.manifest.version, spec.range) then
          reason = ("needs %s@%s, found %s")
            :format(spec.id, spec.range, dep.manifest.version)
        end
        if reason then
          self:_fail(mod, "blocked_dependency", reason)
          changed = true
          break
        end
      end
    end
  end
end

-- Tarjan SCC over the hard-dependency graph: only a cycle's own members
-- fail, so an unrelated mod beside a cycle still loads
function Loader:_failCycles()
  local mods = self.mods
  local counter, stack, onStack, index, low = 0, {}, {}, {}, {}
  local cycles = {}
  local function connect(id)
    counter = counter + 1
    index[id], low[id] = counter, counter
    stack[#stack + 1] = id
    onStack[id] = true
    local selfEdge = false
    for _, spec in ipairs(mods[id].manifest.dependencySpecs) do
      local dep = mods[spec.id]
      if spec.id == id then selfEdge = true end
      if dep and isActive(dep) and spec.id ~= id then
        if not index[spec.id] then
          connect(spec.id)
          if low[spec.id] < low[id] then low[id] = low[spec.id] end
        elseif onStack[spec.id] and index[spec.id] < low[id] then
          low[id] = index[spec.id]
        end
      end
    end
    if low[id] == index[id] then
      local component = {}
      repeat
        local top = table.remove(stack)
        onStack[top] = false
        component[#component + 1] = top
      until top == id
      if #component > 1 or selfEdge then cycles[#cycles + 1] = component end
    end
  end
  for _, id in ipairs(orderedIds(mods, isActive)) do
    if not index[id] then connect(id) end
  end
  for _, component in ipairs(cycles) do
    table.sort(component)
    local trace = table.concat(component, " -> ") .. " -> " .. component[1]
    for _, id in ipairs(component) do
      self:_fail(mods[id], "blocked_dependency", "circular dependency: " .. trace)
    end
  end
end

-- the declaring mod loses: it asserted the incompatibility, and judging every
-- claim against one snapshot makes a mutual pair fail together
function Loader:_enforceConflicts()
  local doomed = {}
  for _, id in ipairs(orderedIds(self.mods, isActive)) do
    local mod = self.mods[id]
    for _, spec in ipairs(mod.manifest.conflictSpecs) do
      local other = self.mods[spec.id]
      if other and isActive(other)
          and (not spec.range
            or Semver.satisfies(other.manifest.version, spec.range)) then
        doomed[#doomed + 1] = { mod = mod,
          reason = ("conflicts with %s %s"):format(spec.id, other.manifest.version) }
        break
      end
    end
  end
  for _, entry in ipairs(doomed) do
    self:_fail(entry.mod, "conflict", entry.reason)
  end
end

-- Kahn over the surviving graph with the ready set kept in (priority, id)
-- order, so dependencies come first and the rest matches the v1 contract
function Loader:_order()
  local pending, indegree, dependents = {}, {}, {}
  for _, id in ipairs(orderedIds(self.mods, isActive)) do
    pending[id], indegree[id] = true, 0
  end
  for id in pairs(pending) do
    local manifest = self.mods[id].manifest
    local function edge(depId)
      if not pending[depId] or depId == id then return end
      dependents[depId] = dependents[depId] or {}
      dependents[depId][#dependents[depId] + 1] = id
      indegree[id] = indegree[id] + 1
    end
    for _, spec in ipairs(manifest.dependencySpecs) do edge(spec.id) end
    -- optional dependencies order without requiring anything
    for _, spec in ipairs(manifest.optionalSpecs) do edge(spec.id) end
  end
  local ordered = {}
  local function nextId()
    local best
    for id in pairs(pending) do
      if indegree[id] == 0 then
        if not best then
          best = id
        else
          local pa, pb = self.mods[id].manifest.priority,
            self.mods[best].manifest.priority
          if pa < pb or (pa == pb and id < best) then best = id end
        end
      end
    end
    if best then return best end
    -- optional dependencies can close a loop the hard-dependency cycle check
    -- deliberately ignores; break it at the lowest-ordered id rather than
    -- silently dropping the mods
    local leftovers = {}
    for id in pairs(pending) do leftovers[#leftovers + 1] = id end
    if #leftovers == 0 then return nil end
    table.sort(leftovers)
    Logger.warn("optional dependency loop broken at %s", leftovers[1])
    return leftovers[1]
  end
  while true do
    local id = nextId()
    if not id then break end
    pending[id], indegree[id] = nil, nil
    ordered[#ordered + 1] = self.mods[id]
    for _, dependent in ipairs(dependents[id] or {}) do
      if indegree[dependent] then indegree[dependent] = indegree[dependent] - 1 end
    end
  end
  return ordered
end

-- merge order is a property of the target paths, never of pairs(): a
-- whole-table registry ("audio") has to land before the granular ones nested
-- under it ("audio.sfx"), or its subtable swap discards every id they already
-- wrote into the object it replaces.  A strict prefix always has fewer
-- segments, so shallowest-first buys that; the name breaks ties so the same
-- content always merges the same way.
function Loader:_mergeOrder()
  local names, depth = {}, {}
  for name, registry in pairs(self.content) do
    names[#names + 1] = name
    local segments = 0
    for _ in (registry.spec.target or ""):gmatch("[^%.]+") do
      segments = segments + 1
    end
    depth[name] = segments
  end
  table.sort(names, function(a, b)
    if depth[a] ~= depth[b] then return depth[a] < depth[b] end
    return a < b
  end)
  return names
end

function Loader:_resolve()
  self:_enforceDependencies()
  self:_failCycles()
  self:_enforceDependencies()
  self:_enforceConflicts()
  self:_enforceDependencies()
  return self:_order()
end

-- per-registry accessor bound to one mod: schema violations are load
-- errors for api 2 mods and attributed warnings for api 1 (compat), and a
-- deprecated name warns once per mod on first use
function Loader:_contentApi(mod, registry, deprecation)
  local loader = self
  local modId = mod.manifest.id
  local apiLevel = mod.manifest.api or 1
  local warned = false
  local function note()
    if deprecation and not warned then
      warned = true
      Logger.warn("[%s] %s", modId, deprecation)
    end
  end
  local function validate(mode, id, value)
    local ok, err = Schemas.check(registry.spec, registry.name, id, value, mode)
    if ok then return end
    if apiLevel >= 2 then error(err, 0) end
    Logger.warn("[%s] %s", modId, err)
  end
  return {
    register = function(_, id, value)
      note()
      validate("register", id, value)
      loader:_journal(registry.name)
      return registry:register(id, value, modId)
    end,
    override = function(_, id, value)
      note()
      validate("override", id, value)
      loader:_journal(registry.name)
      return registry:override(id, value, modId)
    end,
    patch = function(_, id, partial)
      note()
      validate("patch", id, partial)
      loader:_journal(registry.name)
      return registry:patch(id, partial, modId)
    end,
    remove = function(_, id)
      note()
      loader:_journal(registry.name)
      return registry:remove(id, modId)
    end,
    get = function(_, id)
      note()
      return registry:get(id)
    end,
    each = function()
      note()
      return registry:each()
    end,
  }
end

-- mod.commands is sugar over the commands registry; the engine's own verbs
-- are registered there too, so replacing one has to say override
function Loader:_registerCommand(modId, verb, fn)
  assert(type(verb) == "string" and verb ~= "", "command verb is required")
  assert(type(fn) == "function", "command handler must be a function")
  self:_journal("commands")
  return self.content.commands:register(verb, fn, modId)
end

function Loader:_api(mod)
  local loader = self
  local modId = mod.manifest.id
  local api = {
    id = modId,
    version = mod.manifest.version,
    path = mod.path,
    -- a deep copy: what a mod does to its own view never reaches the loader
    manifest = Merge.deepCopy(mod.manifest),
    content = {},
    exports = {},
    DELETE = Registry.DELETE,
    events = {
      on = function(_, name, callback, priority)
        return loader.events:on(name, callback, priority, modId)
      end,
      once = function(_, name, callback, priority)
        return loader.events:once(name, callback, priority, modId)
      end,
      -- mods broadcast under their own prefix only, so no mod can forge an
      -- engine event; exports stay the call-style channel
      emit = function(_, name, payload)
        local prefix = "mod." .. modId .. "."
        if type(name) ~= "string" or name:sub(1, #prefix) ~= prefix then
          error(("[%s] mods may only emit %s* events"):format(modId, prefix), 0)
        end
        return loader.events:emit(name, payload)
      end,
    },
    hooks = { wrap = function(_, name, callback, priority)
      return loader.hooks:wrap(name, callback, priority, modId)
    end },
    -- the widget toolkit facade (12 4.5) is one shared surface, not
    -- per-mod state; each widget inside it loads on first touch
    ui = ModUI,
    -- namespaced per mod; M11 backs these with save.modData /
    -- options.modOptions, the shape mods compile against is already final
    save = {
      get = function(_, key, default)
        local bucket = loader.modSave[modId]
        local value = bucket and bucket[key]
        if value == nil then return default end
        return value
      end,
      set = function(_, key, value)
        local bucket = loader.modSave[modId]
        if not bucket then
          bucket = {}
          loader.modSave[modId] = bucket
        end
        bucket[key] = value
      end,
    },
    options = {
      define = function(_, schema)
        assert(type(schema) == "table", "options schema must be a table of rows")
        for _, row in ipairs(schema) do
          assert(type(row) == "table" and type(row.key) == "string" and row.key ~= "",
            "each options row needs a string key")
        end
        loader.optionSchemas[modId] = schema
        return schema
      end,
      get = function(_, key)
        local stored = loader.modOptions[modId]
        if stored ~= nil and stored[key] ~= nil then return stored[key] end
        for _, row in ipairs(loader.optionSchemas[modId] or {}) do
          if row.key == key then return row.default end
        end
        return nil
      end,
    },
    commands = { register = function(_, verb, fn)
      return loader:_registerCommand(modId, verb, fn)
    end },
    -- M11 runs these against save.meta; recording them is what M2 owes
    migrations = { add = function(_, since, fn)
      assert(type(since) == "string" and since ~= "",
        "migrations need the version they upgrade from")
      assert(type(fn) == "function", "migration must be a function")
      local list = loader.migrations[modId]
      if not list then
        list = {}
        loader.migrations[modId] = list
      end
      list[#list + 1] = { since = since, apply = fn }
      return fn
    end },
    log = {
      info = function(_, fmt, ...) Logger.info("[%s] " .. fmt, modId, ...) end,
      warn = function(_, fmt, ...) Logger.warn("[%s] " .. fmt, modId, ...) end,
      error = function(_, fmt, ...) Logger.error("[%s] " .. fmt, modId, ...) end,
    },
  }
  self.exports[modId] = api.exports
  -- a handle, not the mod object: {id, version, exports} or nil when the
  -- other mod is absent, disabled, failed, or has not run yet.  Tolerates
  -- mod:find(id) as well as the documented mod.find(id).
  api.find = function(first, second)
    local otherId = second == nil and first or second
    local other = loader.mods[otherId]
    if not other or not isActive(other) then return nil end
    local exports = loader.exports[otherId]
    if exports == nil then return nil end
    return { id = otherId, version = other.manifest.version, exports = exports }
  end
  for name, registry in pairs(self.content) do
    local deprecation = registry.spec.deprecated
      and ("the %s registry is deprecated; use %s")
        :format(name, registry.spec.deprecated.useInstead)
    api.content[name] = self:_contentApi(mod, registry, deprecation)
  end
  for alias, canonical in pairs(Schemas.ALIASES) do
    api.content[alias] = self:_contentApi(mod, self.content[canonical],
      ("the %s registry is deprecated; use %s"):format(alias, canonical))
  end
  -- assets keeps the v1 alias to the content accessors and adds the file
  -- helpers on top, so mod.assets.pokemon and mod.assets:image both resolve
  api.assets = setmetatable({
    path = function(_, relative) return mod.path .. "/" .. relative end,
    image = function(_, relative)
      local full = mod.path .. "/" .. relative
      local cached = loader.imageCache[full]
      if cached then return cached end
      assert(love and love.graphics,
        ("[%s] mod.assets:image needs a graphics context"):format(modId))
      local image = love.graphics.newImage(full)
      loader.imageCache[full] = image
      return image
    end,
  }, { __index = api.content })
  function api:read(relative)
    local path = self.path .. "/" .. relative
    return loader.fs.read(path)
  end
  -- mod.world materializes on first touch, like the image helper above: a
  -- headless load must not drag the world stack in, and the Game the facade
  -- acts on is still being wired when the entry chunk runs
  local world
  setmetatable(api, { __index = function(_, key)
    if key ~= "world" then return nil end
    if world then return world end
    local game = loader:_game()
    local module = game and engineRequire("src.world.WorldAPI")
    if not module then return nil end
    world = module.new(game, modId)
    return world
  end })
  return api
end

-- the live Game.  An injected reference wins so a headless caller can hand
-- over a stub; otherwise the boot singleton, whose stack and overworld fill
-- in after this loader returns -- holding the table keeps the facade live.
function Loader:_game()
  return self.game or engineRequire("src.core.Game")
end

function Loader:_loadMod(mod)
  local path = mod.path .. "/" .. mod.manifest.entry
  local chunk, err = self.fs.load(path)
  if not chunk then error(err or ("unable to load " .. path)) end
  local api = self:_api(mod)
  local result = chunk(api)
  if type(result) == "function" then result(api) end
  -- a mod that replaced the table wholesale (mod.exports = {...}) still
  -- publishes what its dependents will see
  self.exports[mod.manifest.id] = api.exports
end

-- remember which registries a mod touched so a failing entry chunk can be
-- undone with one owner-wide op purge per registry
function Loader:_journal(name)
  local journal = self.journal
  if journal then journal[name] = true end
end

-- a failing mod leaves zero residue: its ops are dropped before the merge
-- loop ever runs, and every subscription, export, command, option schema and
-- migration it took goes with them.  The journal only exists around an
-- entry chunk; a later failure (script validation) purges every registry.
function Loader:_rollback(modId)
  for name in pairs(self.journal or self.content) do
    self.content[name]:rollback(modId)
  end
  self.events:removeOwner(modId)
  self.hooks:removeOwner(modId)
  self.exports[modId] = nil
  self.optionSchemas[modId] = nil
  self.migrations[modId] = nil
  self.modSave[modId] = nil
end

-- a mod that explicitly swears it stays link-compatible while writing into a
-- link-relevant registry gets one attributed warning; the default for a
-- content profile is not a claim, so only a written affects_link is judged.
-- The fingerprint itself is derived from merged data either way (M12)
function Loader:_checkLinkClaims(mod)
  if mod.manifest.raw.affects_link ~= false then return end
  for name, registry in pairs(self.content) do
    if Manifest.LINK_REGISTRIES[name] then
      for _, list in pairs(registry.ops) do
        for _, entry in ipairs(list) do
          if entry.owner == mod.manifest.id then
            Logger.warn("[%s] declares affects_link = false but writes to %s",
              mod.manifest.id, name)
            return
          end
        end
      end
    end
  end
end

-- ------- script validation (09 §4.9)

-- Every row list reachable from a map_scripts contribution is checked
-- against the merged command set once all entry chunks have run, before the
-- merge writes the chains home.  Findings fail an api 2 owner outright --
-- the mod is purged like an entry-chunk error -- while api 1 and engine
-- owners keep the v1 runtime skip and get attributed warnings.
function Loader:_validateScripts()
  local registry = self.content.map_scripts
  if not registry or next(registry.ops) == nil then return end
  local MapScripts = engineRequire("src.script.MapScripts")
  if not MapScripts then return end
  local commands = self.content.commands
  local function lookup(verb) return commands:get(verb) ~= nil end
  local failed = false
  for mapId in pairs(registry.ops) do
    local chain = registry:chain(mapId)
    local owners = registry:chainOwners(mapId)
    for i = 1, #chain do
      local findings = MapScripts.validateContribution(chain[i], lookup)
      if #findings > 0 then
        local owner = owners[i]
        local mod = owner and self.mods[owner]
        local reason = ("map_scripts %s: %s"):format(mapId,
          table.concat(findings, "; "))
        if mod and (mod.manifest.api or 1) >= 2 then
          self:_fail(mod, "failed", reason)
          failed = true
        else
          Logger.warn("[%s] %s", tostring(owner or Schemas.ENGINE), reason)
        end
      end
    end
  end
  if not failed then return end
  -- purge the failed mods and whatever dependency enforcement takes with
  -- them, exactly as an entry-chunk failure would have
  self:_enforceDependencies()
  for i = #self.loaded, 1, -1 do
    local mod = self.loaded[i]
    if mod.failed then
      self:_rollback(mod.manifest.id)
      table.remove(self.loaded, i)
    end
  end
  for i = #self.order, 1, -1 do
    local mod = self.mods[self.order[i]]
    if mod and mod.failed then table.remove(self.order, i) end
  end
end

-- ------- audio provenance
-- An audio def only fails when its cue fires, long after the load phase has
-- handed its report to the manager, so the merge leaves behind who wrote
-- each def for Music/Sound to name in the failure (13.3).  Engine records
-- stay unstamped on purpose: they resolve to "base", which Runtime.reportError
-- keeps out of the manager's error feed because no mod can be blamed for them.

local AUDIO_OWNERS = {
  music = "songs", sfx = "sfx", cries = "cries", map_songs = "mapSongs",
}

local function stampAudioOwners(data, name, registry)
  local key = AUDIO_OWNERS[name]
  if not key then return end
  local owners = Data.ensure(data, "audio._owners")
  local map = owners[key] or {}
  for id in pairs(registry.ops) do
    local owner = registry.owners[id]
    -- a tombstoned id has no def left to attribute, and a resurrected one
    -- belongs to whoever wrote it last
    if owner == nil or owner == Schemas.ENGINE or registry:get(id) == nil then
      map[id] = nil
    else
      map[id] = owner
    end
  end
  owners[key] = map
end

function Loader:load(data)
  self.baseData = data
  -- every registry folds against the pristine view of its Data target;
  -- resolution is lazy so optional namespaces may appear later
  for _, registry in pairs(self.content) do
    local target = registry.spec.target
    if target then
      registry.base = function()
        return data and resolvePath(data, target)
      end
    end
  end
  -- vanilla content is registrations too, and they land before discovery so
  -- a mod's register collides with the engine's and has to say override
  require("src.mods.Builtins").install(self.content, data)
  self:_loadState()
  self:_discover()
  for id, mod in pairs(self.mods) do
    mod.enabled = not self.disabled[id]
    mod.state = mod.enabled and "pending" or "disabled"
  end
  -- engine call sites reach these buses -- and this error feed, for failures
  -- that only surface at play time -- through Runtime from here on
  Runtime.install(self.events, self.hooks, self.errors)
  self:_validate()
  local ordered = self:_resolve()
  if self.dev then self:_installDevShim() end
  for _, mod in ipairs(ordered) do
    -- a mod ahead of this one may have failed and taken its dependents with
    -- it, so the order list is filtered as it is walked
    if isActive(mod) then
      local modId = mod.manifest.id
      self.journal = {}
      -- the dev tripwire attributes requires to whoever is running
      Runtime.currentMod = modId
      local success, err = pcall(self._loadMod, self, mod)
      Runtime.currentMod = nil
      if not success then self:_rollback(modId) end
      self.journal = nil
      if success then
        mod.state = "loaded"
        self.loaded[#self.loaded + 1] = mod
        self.order[#self.order + 1] = modId
        self:_checkLinkClaims(mod)
        Logger.info("loaded mod %s %s", modId, mod.manifest.version)
      else
        self:_fail(mod, "failed", tostring(err))
        self:_enforceDependencies()
      end
    end
  end
  -- the commands registry is final once every entry chunk has run, so
  -- each map_scripts contribution's rows can be judged before they merge
  self:_validateScripts()
  -- merge: fold every touched id from its pristine base value and write it
  -- home, creating the Data namespace when the base modules never shipped
  -- one.  A registry nobody wrote to -- engine included -- is skipped, so
  -- the namespaces that appear are exactly the ones with content behind them.
  for _, name in ipairs(self:_mergeOrder()) do
    local registry = self.content[name]
    local spec = registry.spec
    if data and spec.target and next(registry.ops) ~= nil then
      local target = Data.ensure(data, spec.target)
      if spec.write then
        -- ids that do not map one-to-one onto target keys (type_chart's
        -- ordered rows, battle_anims' per-kind subtables) place themselves
        spec.write(target, registry)
      elseif spec.semantics == "compose" then
        for id in pairs(registry.ops) do
          local chain = registry:chain(id)
          if #chain == 0 then
            -- an emptied chain still has to say which kind of empty it is:
            -- a tombstone keeps the (empty) chain so the consumer drops its
            -- own base contribution too, while a chain nobody wrote to
            -- leaves the id untouched and base dispatches as it always did
            if registry:chainReplacesBase(id) then
              target[id] = { replacesBase = true }
            else
              target[id] = nil
            end
          else
            -- owner records ride the chain under a named key ipairs
            -- skips, so the consumer can attribute each contribution
            -- (map_scripts builds runner sources from these)
            local owners = registry:chainOwners(id)
            for i = 1, #chain do
              local owner = owners[i]
              local mod = owner and self.mods[owner]
              owners[i] = { modId = mod and owner or nil,
                            strict = mod and (mod.manifest.api or 1) >= 2 or nil }
            end
            chain.owners = owners
            -- an override chain is a total conversion: the consumer must
            -- leave its own base contribution out (09 4.4)
            chain.replacesBase = registry:chainReplacesBase(id) or nil
            target[id] = chain
          end
        end
      else
        local tombstones = {}
        for id in pairs(registry.ops) do
          local value = registry:get(id)
          if value == nil then
            tombstones[#tombstones + 1] = id
          else
            target[id] = value
          end
        end
        -- tombstones survive the fold as an explicit delete pass so
        -- consumers see the id as absent, not as a stale record
        for _, id in ipairs(tombstones) do target[id] = nil end
      end
      stampAudioOwners(data, name, registry)
    end
  end
  -- dangling f.id references are attributed to the id's last writer;
  -- api 1 mods keep the warning-only compat path
  if data then
    for _, problem in ipairs(Schemas.crossValidate(self, data)) do
      local ownerMod = problem.owner and self.mods[problem.owner]
      local apiLevel = ownerMod and (ownerMod.manifest.api or 1) or 1
      local message = tostring(problem.owner or "?") .. ": " .. problem.message
      if apiLevel >= 2 then
        self.errors[#self.errors + 1] = message
        Logger.error("%s", message)
      else
        Logger.warn("%s", message)
      end
    end
  end
  -- content freezes at the merge boundary; the event/hook buses stay open
  -- so mods may subscribe at any point for the life of the process
  for _, registry in pairs(self.content) do
    registry:freeze()
  end
  -- the load set is final here, so every surviving mod's recipe builds its
  -- derived art before the resolver is first asked to serve it; stamped, so
  -- a boot that changed nothing pays only the stat
  AssetTransform.run(self)
  -- and the same final load set becomes the asset search path, so an
  -- overrides/ file or a transform's output shadows the generated cache
  -- from the next image load on.  No mods means an empty search path,
  -- which resolves every path to itself (14 §asset resolution).
  Assets.installLoader(self)
  self.events:emit("mods.loaded", { loader = self, data = data })
  self.initialized = true
  return #self.errors == 0
end

-- the manager reads api, profile, permissions, per-mod state and the load
-- order from here; enabled stays the user's flag so a failed mod still
-- renders as enabled-but-broken instead of silently switching itself off
function Loader:status()
  local available, loaded = {}, {}
  for _, mod in pairs(self.mods) do
    local manifest = {}
    for key, value in pairs(mod.manifest) do manifest[key] = value end
    manifest.enabled = mod.enabled ~= false
    manifest.state = mod.state or (manifest.enabled and "loaded" or "disabled")
    manifest.error = mod.failure
    available[#available + 1] = manifest
    if manifest.state == "loaded" then loaded[#loaded + 1] = manifest end
  end
  table.sort(available, function(a, b) return a.id < b.id end)
  table.sort(loaded, function(a, b) return a.id < b.id end)
  return { available = available, loaded = loaded, errors = self.errors,
    order = self.order }
end

return Loader
