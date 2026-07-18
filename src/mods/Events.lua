local Events = {}
Events.__index = Events

function Events.new()
  return setmetatable({ listeners = {}, sealed = false }, Events)
end

function Events:on(name, callback, priority)
  assert(not self.sealed, "mod events are sealed")
  assert(type(name) == "string" and name ~= "", "event name is required")
  assert(type(callback) == "function", "event callback must be a function")
  local list = self.listeners[name] or {}
  self.listeners[name] = list
  local entry = { callback = callback, priority = priority or 0 }
  list[#list + 1] = entry
  table.sort(list, function(a, b) return a.priority > b.priority end)
  return function()
    for i, candidate in ipairs(list) do
      if candidate == entry then table.remove(list, i) break end
    end
  end
end

function Events:emit(name, payload)
  local list = self.listeners[name] or {}
  for _, entry in ipairs(list) do
    entry.callback(payload)
  end
end

function Events:seal()
  self.sealed = true
end

return Events
