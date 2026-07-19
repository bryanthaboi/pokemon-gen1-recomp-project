package.path = "./?.lua;./?/init.lua;" .. package.path

local Registry = require("src.mods.Registry")
local Events = require("src.mods.Events")
local Hooks = require("src.mods.Hooks")
local Manifest = require("src.mods.Manifest")
local Logger = require("src.core.Logger")
local Version = require("src.core.Version")
local Runtime = require("src.mods.Runtime")

local S = require("tests.harness").suite("native mod runtime")
local check = S.check

local function logged(fragmentA, fragmentB)
  for _, line in ipairs(Logger.history) do
    if line:find(fragmentA, 1, true) and line:find(fragmentB, 1, true) then
      return true
    end
  end
  return false
end

local registry = Registry.new("pokemon")
registry:register("A", { value = 1 }, "test")
registry:override("A", { value = 2 }, "test")
check(registry:get("A").value == 2, "registry override")

-- frozen after the boot merge: writes error, reads keep working
registry:freeze()
check(not pcall(function() registry:register("B", { value = 3 }, "test") end),
  "frozen registry rejects registration")
check(not pcall(function() registry:override("A", { value = 9 }, "test") end),
  "frozen registry rejects override")
check(registry:get("A").value == 2, "frozen registry still readable")

local events = Events.new()
local calls = {}
events:on("test", function() calls[#calls + 1] = "low" end, 0)
events:on("test", function() calls[#calls + 1] = "high" end, 10)
events:emit("test")
check(calls[1] == "high" and calls[2] == "low", "event priority")

-- seal is a deprecated no-op; subscription stays legal afterwards
events:seal()
local late = 0
events:on("late", function() late = late + 1 end)
events:emit("late")
check(late == 1, "subscription legal after seal")

-- a throwing listener is skipped and attributed; later listeners still run
local reached = 0
events:on("boom", function() error("listener exploded") end, 10, "bad_mod")
events:on("boom", function() reached = reached + 1 end, 0, "good_mod")
check(pcall(function() events:emit("boom") end), "emit survives a throwing listener")
check(reached == 1, "later listeners run after a failure")
check(logged("[bad_mod]", "boom"), "listener failure logged with mod id")

-- rollback support: removeOwner drops every subscription a mod made
events:removeOwner("good_mod")
events:emit("boom")
check(reached == 1, "removeOwner drops the listener")

local hooks = Hooks.new()
hooks:wrap("double", function(next, value)
  return next(value) * 2
end, 0)
hooks:wrap("double", function(next, value)
  return next(value + 1)
end, 10)
check(hooks:call("double", function(value) return value end, 3) == 8,
  "hook chain ordering and next")

-- a throwing link is skipped and the chain continues with the current args
local guarded = Hooks.new()
guarded:wrap("calc", function(next, value) return next(value + 1) end, 10, "outer")
guarded:wrap("calc", function() error("link exploded") end, 5, "broken")
guarded:wrap("calc", function(next, value) return next(value * 2) end, 0, "inner")
check(guarded:call("calc", function(value) return value end, 3) == 8,
  "failing hook link skipped, chain continues")
check(logged("[broken]", "calc"), "hook failure logged with mod id")

-- an error below the chain is the engine's, not a mod's: it propagates and
-- the vanilla function is never re-run
local vanillaRuns = 0
local okCall, err = pcall(function()
  return guarded:call("calc", function()
    vanillaRuns = vanillaRuns + 1
    error("vanilla failed")
  end, 1)
end)
check(not okCall and tostring(err):find("vanilla failed", 1, true) ~= nil,
  "vanilla error propagates through the chain")
check(vanillaRuns == 1, "vanilla runs exactly once when it fails")

-- a link that throws AFTER its next() returned must not re-walk the chain:
-- vanilla has side effects, so the downstream result is kept and the link's
-- post-processing is discarded
local lateFail = Hooks.new()
lateFail:wrap("calc", function(next, value) return next(value + 1) end, 10, "outer")
lateFail:wrap("calc", function(next, value)
  local r = next(value)
  error("post-next bug")
end, 5, "late")
local lateRuns = 0
local lateResult = lateFail:call("calc", function(value)
  lateRuns = lateRuns + 1
  return value * 2
end, 3)
check(lateRuns == 1, "vanilla runs exactly once when a link fails after next")
check(lateResult == 8, "post-next failure keeps the downstream result")
check(logged("[late]", "downstream result kept"), "post-next failure logged with mod id")

guarded:removeOwner("broken")
guarded:removeOwner("inner")
check(guarded:call("calc", function(value) return value end, 3) == 4,
  "removeOwner unwinds hook links")

check(pcall(function() hooks:seal() end), "hook seal is a deprecated no-op")

-- a listener retiring mid-dispatch must not shift the entries emit has yet
-- to reach; emit walks a copy so every subscriber still fires
local reentrant = Events.new()
local fired, drop = {}, nil
drop = reentrant:on("tick", function() fired[#fired + 1] = "a" drop() end, 10, "first")
reentrant:on("tick", function() fired[#fired + 1] = "b" end, 5, "second")
reentrant:on("tick", function() fired[#fired + 1] = "c" end, 1, "third")
reentrant:emit("tick")
check(table.concat(fired, ",") == "a,b,c",
  "unsubscribing mid-emit does not skip later listeners")

local onceCount = 0
reentrant:once("solo", function() onceCount = onceCount + 1 end, 0, "first")
reentrant:emit("solo")
reentrant:emit("solo")
check(onceCount == 1, "once fires exactly once across repeated emits")

local manifest = Manifest.validate({
  id = "test_mod", name = "Test Mod", version = "1.0.0", entry = "main.lua"
}, "mods/test_mod")
check(manifest.id == "test_mod" and manifest.path == "mods/test_mod",
  "manifest validation")

check(type(Version.engine) == "string"
  and Version.engine:match("^%d+%.%d+%.%d+$") ~= nil,
  "engine version is a semver triple")
check(Version.modApi == 2, "mod api version is 2")
check(Version.title("X") == "X v" .. Version.engine,
  "window title carries the engine version")

-- null-object runtime: emit/call are safe with no loader installed
local nullEvents, nullHooks = Runtime.events, Runtime.hooks
Runtime.emit("nobody.listens", { probe = true })
local a, b = Runtime.call("unwired.hook", function(x, y) return y, x end, 1, 2)
check(a == 2 and b == 1, "null-object hook call passes through to vanilla")
check(not Runtime.wants("anything") and not Runtime.wantsHook("anything"),
  "null-object buses report no subscribers")

local liveEvents, liveHooks = Events.new(), Hooks.new()
Runtime.install(liveEvents, liveHooks)
local got
liveEvents:on("runtime.probe", function(payload) got = payload end, 0, "test")
Runtime.emit("runtime.probe", { value = 7 })
check(got ~= nil and got.value == 7, "installed bus receives Runtime.emit")
check(Runtime.wants("runtime.probe"), "wants sees the live subscription")

-- the last unsubscribe clears wants, so a hot emit site stops building
-- payloads once nobody listens; a survivor keeps the key alive
local unsubHot = liveEvents:on("hot.emit", function() end, 0, "test")
check(Runtime.wants("hot.emit"), "wants sees the hot subscription")
unsubHot()
check(not Runtime.wants("hot.emit"), "wants clears after the last unsubscribe")
local dropFirst = liveEvents:on("hot.pair", function() end, 0, "test")
local dropSecond = liveEvents:on("hot.pair", function() end, 0, "test")
dropFirst()
check(Runtime.wants("hot.pair"), "wants stays while a listener remains")
dropSecond()
check(not Runtime.wants("hot.pair"), "and clears when the list empties")
-- a stale unsubscribe run again must not clobber a later subscription
local stale = liveEvents:on("hot.stale", function() end, 0, "test")
stale()
local staleHits = 0
liveEvents:on("hot.stale", function() staleHits = staleHits + 1 end, 0, "test")
stale()
check(Runtime.wants("hot.stale"), "a stale unsubscribe leaves the new list alone")
liveEvents:emit("hot.stale")
check(staleHits == 1, "and the new listener still fires")
Runtime.install(nullEvents, nullHooks)

-- POKEPORT_DATA_DIR points Data:load at another dataset root; the fixture
-- set is ROM-free, so this is what lets a runner boot with no data/generated
local ffi = require("ffi")
ffi.cdef([[
int setenv(const char *name, const char *value, int overwrite);
int unsetenv(const char *name);
]])
ffi.C.setenv("POKEPORT_DATA_DIR", "tests/fixture_data", 1)
local Data = require("src.core.Data")
local fixture = setmetatable({}, { __index = Data })
local okLoad, loadErr = pcall(Data.load, fixture)
ffi.C.unsetenv("POKEPORT_DATA_DIR")
check(okLoad, "Data:load honours POKEPORT_DATA_DIR (" .. tostring(loadErr) .. ")")
check(okLoad and fixture.pokemon ~= nil and fixture.pokemon.FIXMON_A ~= nil,
  "the override serves the fixture dataset")
check(okLoad and fixture.pokemon.PIDGEY == nil, "and not the generated one")
check(okLoad and fixture.constants.partyMax == 6,
  "fixture constants pass through seedDefaults")

S.finish()
