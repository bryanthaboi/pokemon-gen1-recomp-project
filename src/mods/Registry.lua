-- Ordered, namespaced registries used by the native mod API.
-- Mods register definitions here; the loader merges them into the live data
-- only after every enabled mod has initialized successfully.
local Registry = {}
Registry.__index = Registry

function Registry.new(name)
  return setmetatable({ name = name, values = {}, owners = {} }, Registry)
end

function Registry:register(id, value, owner, replace)
  assert(type(id) == "string" and id ~= "", self.name .. " id is required")
  assert(value ~= nil, self.name .. " value is required for " .. id)
  if self.values[id] ~= nil and not replace then
    error(("%s already registered: %s"):format(self.name, id))
  end
  self.values[id] = value
  self.owners[id] = owner
  return value
end

function Registry:override(id, value, owner)
  return self:register(id, value, owner, true)
end

function Registry:get(id)
  return self.values[id]
end

function Registry:has(id)
  return self.values[id] ~= nil
end

function Registry:items()
  return self.values
end

return Registry
