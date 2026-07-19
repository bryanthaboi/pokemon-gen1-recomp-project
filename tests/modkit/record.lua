-- Recorders for the SDK harness (21-testing-and-ci "modkit test
-- harness").  A case asserts that a seam fired without standing up a live
-- battle or a real frame.
--
-- The event recorder shadows emit on the bus *instance*; Events methods
-- come off the shared metatable, so assigning the field masks it and
-- clearing it restores the original with nothing left behind.  Production
-- emit is untouched -- there is no recorder branch in the engine at all,
-- which is why this costs a mod-free boot exactly nothing.

local Record = {}

-- accepts a loader or a bare Events bus
local function busOf(target)
  if target and target.events and target.events.emit then return target.events end
  return target
end

function Record.events(target, opts)
  local bus = busOf(target)
  assert(bus and bus.emit, "record.events needs a loader or an Events bus")
  local only = opts and opts.only
  local capture = { events = {} }
  local original = bus.emit

  bus.emit = function(self, name, payload)
    if not only or only == name or (type(only) == "table" and only[name]) then
      capture.events[#capture.events + 1] = { name = name, payload = payload }
    end
    return original(self, name, payload)
  end

  -- nil restores the metatable lookup rather than pinning a copy of emit
  function capture:stop() bus.emit = nil end
  function capture:clear() capture.events = {} end

  function capture:names()
    local out = {}
    for i, entry in ipairs(capture.events) do out[i] = entry.name end
    return out
  end

  function capture:count(name)
    local n = 0
    for _, entry in ipairs(capture.events) do
      if entry.name == name then n = n + 1 end
    end
    return n
  end

  -- first payload emitted under `name`, the usual assertion target
  function capture:first(name)
    for _, entry in ipairs(capture.events) do
      if entry.name == name then return entry.payload end
    end
    return nil
  end

  function capture:saw(name) return capture:first(name) ~= nil or capture:count(name) > 0 end

  return capture
end

-- the sanctioned draw-capture pattern from tests/parity_gbcfx.lua, lifted
-- so sprite/tileset mods can assert on what reached the screen
function Record.draw()
  local original = love.graphics.draw
  local capture = { draws = {} }

  love.graphics.draw = function(image, ...)
    capture.draws[#capture.draws + 1] = { image = image, args = { ... } }
    if original then return original(image, ...) end
  end

  function capture:stop() love.graphics.draw = original end
  function capture:clear() capture.draws = {} end

  -- draws whose image came from `path`; the love stub keeps the path on
  -- the image it fabricates, so an asset override is observable
  function capture:fromPath(path)
    local out = {}
    for _, entry in ipairs(capture.draws) do
      local image = entry.image
      if type(image) == "table" and image.path == path then out[#out + 1] = entry end
    end
    return out
  end

  return capture
end

-- hook-chain recorder: proves an empty chain stayed empty, or that exactly
-- the expected mod links are wrapped around a name
function Record.hooks(target)
  local bus = (target and target.hooks) or target
  assert(bus and bus.chains, "record.hooks needs a loader or a Hooks bus")
  local capture = {}

  function capture:depth(name)
    local chain = bus.chains[name]
    return chain and #chain or 0
  end

  function capture:owners(name)
    local out = {}
    for _, entry in ipairs(bus.chains[name] or {}) do out[#out + 1] = entry.owner end
    return out
  end

  return capture
end

return Record
