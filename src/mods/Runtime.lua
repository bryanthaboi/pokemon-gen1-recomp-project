-- Process-wide access to the mod event/hook buses.  Engine files require
-- this instead of threading the Game object through call sites; Loader:load
-- installs the live buses.  Until then the null objects below make every
-- emit/call site a safe pass-through, so headless code paths and tools that
-- never run a loader need no guards.

local Runtime = {}

local NullEvents = {}
function NullEvents:emit() end
function NullEvents:removeOwner() end

local NullHooks = {}
function NullHooks:call(name, vanilla, ...) return vanilla(...) end
function NullHooks:removeOwner() end

Runtime.events = NullEvents
Runtime.hooks = NullHooks

-- the live loader's error list, lent out by install.  Failures that only
-- surface long after the load phase -- a mod's audio def that first fails
-- when its cue fires -- have to land in the same feed the mod manager
-- reads, and nil here means nobody is collecting.
Runtime.errors = nil

-- id of the mod whose code is currently running, set by the loader around
-- every mod-authored frame; nil on engine paths, which is how the dev-mode
-- permissions tripwire knows there is nobody to attribute to
Runtime.currentMod = nil

function Runtime.install(events, hooks, errors)
  Runtime.events, Runtime.hooks = events, hooks
  Runtime.errors = errors
end

-- attribute a runtime failure to the mod that owns the offending record.
-- "base" is the engine's own owner id: a vanilla record that fails is a
-- console line, not something the manager can ask the player to disable.
function Runtime.reportError(modId, message)
  local errors = Runtime.errors
  if not errors or not modId or modId == "base" then return end
  errors[#errors + 1] = tostring(modId) .. ": " .. tostring(message)
end

function Runtime.emit(name, payload)
  Runtime.events:emit(name, payload)
end

function Runtime.call(name, vanilla, ...)
  return Runtime.hooks:call(name, vanilla, ...)
end

-- fast guards so hot call sites can skip payload/ctx construction when
-- nothing is subscribed (the null objects have no listeners/chains tables)
function Runtime.wants(name)
  local listeners = Runtime.events.listeners
  return listeners ~= nil and listeners[name] ~= nil
end

function Runtime.wantsHook(name)
  local chains = Runtime.hooks.chains
  return chains ~= nil and chains[name] ~= nil
end

return Runtime
