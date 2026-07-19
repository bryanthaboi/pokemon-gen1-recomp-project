-- The live extension-point catalog: every registry, every event name the
-- engine emits, every hook name it calls.
--
-- Registries come from Schemas.REGISTRIES.  Events and hooks are read back
-- out of the source rather than from a hand-kept list, because a hand-kept
-- list is exactly the thing that drifts -- adding a Runtime.emit and
-- forgetting the catalog entry is how a seam ships untested.  The
-- parity-gate meta-test (tests/engine/gate_meta_coverage.lua) walks these
-- three sets, so a new seam is in the coverage requirement the moment its
-- call site exists.

local Schemas = require("src.mods.Schemas")

local Catalog = {}

local function luaFilesUnder(dir)
  local files = {}
  -- -L follows symlinks: a checkout that symlinks src/ (worktrees, the
  -- ROM-free CI probe) would otherwise scan nothing and hand every gate an
  -- empty catalog to pass vacuously against
  local pipe = io.popen("find -L " .. dir .. " -name '*.lua' -type f 2>/dev/null")
  if not pipe then return files end
  for line in pipe:lines() do
    if line ~= "" then files[#files + 1] = line end
  end
  pipe:close()
  table.sort(files)
  return files
end

local function scan(dirs, patterns)
  local found = {}
  for _, dir in ipairs(dirs) do
    for _, path in ipairs(luaFilesUnder(dir)) do
      local handle = io.open(path, "r")
      if handle then
        local body = handle:read("*a")
        handle:close()
        for _, pattern in ipairs(patterns) do
          for name in body:gmatch(pattern) do
            local list = found[name] or {}
            found[name] = list
            list[#list + 1] = path
          end
        end
      end
    end
  end
  return found
end

local function sortedKeys(map)
  local keys = {}
  for key in pairs(map) do keys[#keys + 1] = key end
  table.sort(keys)
  return keys
end

local registries, events, hooks, eventSites, hookSites

function Catalog.registries()
  if not registries then registries = sortedKeys(Schemas.REGISTRIES) end
  return registries
end

-- Runtime.emit is the engine's channel; a bare bus:emit inside src counts
-- too (the loader emits mods.loaded straight off its own bus)
function Catalog.events()
  if not events then
    eventSites = scan({ "src" }, {
      'Runtime%.emit%("([%w%._]+)"',
      'events:emit%("([%w%._]+)"',
    })
    events = sortedKeys(eventSites)
  end
  return events
end

function Catalog.hooks()
  if not hooks then
    hookSites = scan({ "src" }, {
      'Runtime%.call%("([%w%._]+)"',
      'hooks:call%("([%w%._]+)"',
    })
    hooks = sortedKeys(hookSites)
  end
  return hooks
end

function Catalog.eventSites(name)
  Catalog.events()
  return eventSites[name] or {}
end

function Catalog.hookSites(name)
  Catalog.hooks()
  return hookSites[name] or {}
end

-- mods may only emit under "mod.<id>."; those are not engine seams and
-- carry no coverage requirement
function Catalog.isModEvent(name)
  return name:sub(1, 4) == "mod."
end

return Catalog
