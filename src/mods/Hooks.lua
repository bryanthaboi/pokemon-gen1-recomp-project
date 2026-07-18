local Hooks = {}
Hooks.__index = Hooks
local unpack = table.unpack or unpack

function Hooks.new()
  return setmetatable({ chains = {}, sealed = false }, Hooks)
end

function Hooks:wrap(name, callback, priority)
  assert(not self.sealed, "mod hooks are sealed")
  assert(type(name) == "string" and name ~= "", "hook name is required")
  assert(type(callback) == "function", "hook callback must be a function")
  local chain = self.chains[name] or {}
  self.chains[name] = chain
  local entry = { callback = callback, priority = priority or 0 }
  chain[#chain + 1] = entry
  table.sort(chain, function(a, b) return a.priority > b.priority end)
  return function()
    for i, candidate in ipairs(chain) do
      if candidate == entry then table.remove(chain, i) break end
    end
  end
end

function Hooks:call(name, vanilla, ...)
  local chain = self.chains[name] or {}
  local args = { ... }
  local function run(index, current)
    if index > #chain then return current(unpack(args)) end
    return chain[index].callback(function(...)
      local nextArgs = { ... }
      if #nextArgs == 0 then return run(index + 1, current) end
      local old = args
      args = nextArgs
      local result = run(index + 1, current)
      args = old
      return result
    end, unpack(args))
  end
  return run(1, vanilla)
end

function Hooks:seal()
  self.sealed = true
end

return Hooks
