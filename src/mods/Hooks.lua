local Logger = require("src.core.Logger")

local Hooks = {}
Hooks.__index = Hooks
local unpack = table.unpack or unpack

local function pack(...) return { n = select("#", ...), ... } end

-- errors raised below the chain (the vanilla function itself) must not be
-- attributed to a mod link or retried; they ride out wrapped under this key
-- so every guard re-raises instead of skipping
local PASS = {}

function Hooks.new()
  return setmetatable({ chains = {} }, Hooks)
end

-- owner is the wrapping mod id; failures are attributed to it
function Hooks:wrap(name, callback, priority, owner)
  assert(type(name) == "string" and name ~= "", "hook name is required")
  assert(type(callback) == "function", "hook callback must be a function")
  local chain = self.chains[name] or {}
  self.chains[name] = chain
  local entry = { callback = callback, priority = priority or 0, owner = owner }
  chain[#chain + 1] = entry
  table.sort(chain, function(a, b) return a.priority > b.priority end)
  return function()
    for i, candidate in ipairs(chain) do
      if candidate == entry then table.remove(chain, i) break end
    end
  end
end

-- each link runs under pcall: a throwing wrapper is logged and skipped and
-- the chain continues with the current arguments, so a broken mod degrades
-- to "not installed for this call" instead of breaking the pipeline.
-- vanilla must run at most once per call -- it has side effects -- so a link
-- that throws after its next() returned keeps the downstream results (its
-- post-processing is discarded) rather than re-walking the chain, and a link
-- that swallowed a vanilla error then threw propagates instead of retrying
function Hooks:call(name, vanilla, ...)
  local chain = self.chains[name]
  if not chain or #chain == 0 then return vanilla(...) end
  local args = pack(...)
  local ranVanilla = false
  local function run(index)
    if index > #chain then
      ranVanilla = true
      local res = pack(pcall(vanilla, unpack(args, 1, args.n)))
      if res[1] then return unpack(res, 2, res.n) end
      error({ [PASS] = res[2] }, 0)
    end
    local entry = chain[index]
    local downstream
    local function nextFn(...)
      if select("#", ...) == 0 then
        downstream = pack(run(index + 1))
      else
        local saved = args
        args = pack(...)
        downstream = pack(run(index + 1))
        args = saved
      end
      return unpack(downstream, 1, downstream.n)
    end
    local res = pack(pcall(entry.callback, nextFn, unpack(args, 1, args.n)))
    if res[1] then return unpack(res, 2, res.n) end
    local err = res[2]
    if type(err) == "table" and err[PASS] ~= nil then error(err, 0) end
    if downstream ~= nil then
      Logger.warn("[%s] hook %s failed after next: %s -- downstream result kept",
        tostring(entry.owner or "?"), name, tostring(err))
      return unpack(downstream, 1, downstream.n)
    end
    if ranVanilla then
      Logger.warn("[%s] hook %s failed: %s -- vanilla already ran, not retried",
        tostring(entry.owner or "?"), name, tostring(err))
      error({ [PASS] = err }, 0)
    end
    Logger.warn("[%s] hook %s failed: %s -- link skipped",
      tostring(entry.owner or "?"), name, tostring(err))
    return run(index + 1)
  end
  local res = pack(pcall(run, 1))
  if res[1] then return unpack(res, 2, res.n) end
  local err = res[2]
  if type(err) == "table" and err[PASS] ~= nil then error(err[PASS], 0) end
  error(err, 0)
end

-- drops every wrap a mod made; used by entry-chunk rollback
function Hooks:removeOwner(owner)
  if owner == nil then return end
  for name, chain in pairs(self.chains) do
    for i = #chain, 1, -1 do
      if chain[i].owner == owner then table.remove(chain, i) end
    end
    if #chain == 0 then self.chains[name] = nil end
  end
end

-- deprecated no-op: wrapping stays legal for the life of the process
function Hooks:seal() end

return Hooks
