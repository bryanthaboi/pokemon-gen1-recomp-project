-- No-mod parity gate for every event in the catalog (21-testing-and-ci
-- "parity gate for every extension point", constraint 2).
--
-- An event is a broadcast, so its parity claim is weaker than a hook's but
-- just as load-bearing: with nobody subscribed, emit must do nothing,
-- allocate nothing, and above all not change the engine path that emitted
-- it.  The hot-path guard Runtime.wants must agree that nobody is
-- listening, or the guarded call sites build payloads for no reason.

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local Catalog = T.catalog
local Runtime = require("src.mods.Runtime")
local Events = require("src.mods.Events")

local events = Catalog.events()
T.check(#events > 0, "the event catalog is non-empty")

-- 1. the null object -- the pre-loader state every headless tool runs in
for _, name in ipairs(events) do
  local ok = pcall(Runtime.emit, name, { probe = true })
  T.check(ok, "null events swallow the emit: " .. name)
  T.eq(Runtime.wants(name), false, "null events report no listener: " .. name)
end

-- 2. a live but unsubscribed bus -- the mod-free boot
local bus = Events.new()
local savedEvents, savedHooks = Runtime.events, Runtime.hooks
Runtime.events = bus

for _, name in ipairs(events) do
  Runtime.emit(name, { probe = true })
  T.eq(bus.listeners[name], nil, "an unsubscribed emit allocates no list: " .. name)
  T.eq(Runtime.wants(name), false, "wants is false with no listener: " .. name)
end

-- 3. subscribe/unsubscribe returns delivery to the mod-free state, which
-- is what makes entry-chunk rollback and mod disable a true no-op.
-- Note the residue check is on the list contents, not the key: the
-- unsubscribe closure empties the list but leaves the (empty) table, and
-- Runtime.wants keys off the table's existence -- see followUps.
for _, name in ipairs(events) do
  local seen = 0
  local unsubscribe = bus:on(name, function() seen = seen + 1 end, 0, "gate")
  Runtime.emit(name, { probe = true })
  T.eq(seen, 1, "a listener receives its event: " .. name)
  unsubscribe()
  Runtime.emit(name, { probe = true })
  T.eq(seen, 1, "an unsubscribed listener stops receiving: " .. name)
  T.eq(#(bus.listeners[name] or {}), 0, "unsubscribe drains the listener list: " .. name)
end

-- removeOwner is the rollback path; it must clear as completely as the
-- per-listener closure does
for _, name in ipairs(events) do
  bus:on(name, function() end, 0, "rollback_mod")
end
bus:removeOwner("rollback_mod")
local residue = 0
for _ in pairs(bus.listeners) do residue = residue + 1 end
T.eq(residue, 0, "removeOwner returns the bus to the mod-free state")

-- a throwing listener is contained: the emitting engine path completes and
-- the error never reaches the call site
local reached = false
bus:on(events[1], function() error("listener exploded", 0) end, 0, "bad_mod")
bus:on(events[1], function() reached = true end, 0, "good_mod")
local ok = pcall(Runtime.emit, events[1], {})
T.check(ok, "a throwing listener does not propagate to the emitter")
T.check(reached, "a throwing listener does not stop its siblings")
bus:removeOwner("bad_mod")
bus:removeOwner("good_mod")

Runtime.events, Runtime.hooks = savedEvents, savedHooks

T.finish("gate_events")
