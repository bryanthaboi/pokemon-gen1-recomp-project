-- No-mod parity gate for every hook in the catalog (21-testing-and-ci
-- "parity gate for every extension point", constraint 2).
--
-- The claim under test is the one the whole mod API rests on: a hook with
-- nothing wrapped around it returns exactly what the vanilla function
-- returned, having called it exactly once.  This walks the live catalog
-- (tests/modkit/catalog scans the source for Runtime.call sites), so a
-- hook added tomorrow is gated tomorrow without editing a list here.

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local Catalog = T.catalog
local Runtime = require("src.mods.Runtime")
local Hooks = require("src.mods.Hooks")

local hooks = Catalog.hooks()
T.check(#hooks > 0, "the hook catalog is non-empty")

-- a value of each shape a hook actually carries, so "unchanged" is tested
-- against tables and multiple returns, not just a number
local SENTINEL = { tag = "vanilla-result" }

-- 1. the null object: this is the state of the process before any loader
-- exists, and every headless tool and test runs in it
for _, name in ipairs(hooks) do
  local calls = 0
  local got = Runtime.call(name, function(a, b)
    calls = calls + 1
    return a + b
  end, 2, 3)
  T.eq(got, 5, "null hooks pass through: " .. name)
  T.eq(calls, 1, "null hooks run vanilla exactly once: " .. name)
end

-- 2. a live but unsubscribed bus: the state after a mod-free boot, where
-- Loader:load has installed real Events/Hooks that nobody wrapped
local bus = Hooks.new()
local savedEvents, savedHooks = Runtime.events, Runtime.hooks
Runtime.hooks = bus

for _, name in ipairs(hooks) do
  local calls = 0
  local got = Runtime.call(name, function(value)
    calls = calls + 1
    return value
  end, SENTINEL)
  T.check(rawequal(got, SENTINEL), "empty chain returns the identical table: " .. name)
  T.eq(calls, 1, "empty chain runs vanilla exactly once: " .. name)
  T.eq(bus.chains[name], nil, "empty chain allocates nothing for: " .. name)
end

-- multiple returns survive an empty chain (the trailing-nil case is how a
-- "return value, reason" hook silently loses its reason)
for _, name in ipairs(hooks) do
  local a, b, c = Runtime.call(name, function() return 1, nil, "three" end)
  T.check(a == 1 and b == nil and c == "three",
    "empty chain preserves multiple returns: " .. name)
end

-- varargs in, varargs through
local n = select("#", Runtime.call(hooks[1], function(...) return ... end, 1, nil, 3))
T.eq(n, 3, "empty chain preserves argument count including nil holes")

-- an error from vanilla propagates unwrapped rather than being swallowed
-- or re-raised as a hook failure
T.raises(function()
  Runtime.call(hooks[1], function() error("vanilla exploded", 0) end)
end, "vanilla exploded", "empty chain propagates a vanilla error verbatim")

-- 3. wants-guard parity: nothing is subscribed, so every hot path that
-- guards on wantsHook must skip its ctx construction
for _, name in ipairs(hooks) do
  T.eq(Runtime.wantsHook(name), false, "wantsHook is false with no chain: " .. name)
end

Runtime.events, Runtime.hooks = savedEvents, savedHooks

T.finish("gate_hooks")
