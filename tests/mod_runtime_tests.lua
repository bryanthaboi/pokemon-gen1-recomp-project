package.path = "./?.lua;./?/init.lua;" .. package.path

local Registry = require("src.mods.Registry")
local Events = require("src.mods.Events")
local Hooks = require("src.mods.Hooks")
local Manifest = require("src.mods.Manifest")

local function check(value, message)
  assert(value, message)
end

local registry = Registry.new("pokemon")
registry:register("A", { value = 1 }, "test")
registry:override("A", { value = 2 }, "test")
check(registry:get("A").value == 2, "registry override")

local events = Events.new()
local calls = {}
events:on("test", function() calls[#calls + 1] = "low" end, 0)
events:on("test", function() calls[#calls + 1] = "high" end, 10)
events:emit("test")
check(calls[1] == "high" and calls[2] == "low", "event priority")

local hooks = Hooks.new()
hooks:wrap("double", function(next, value)
  return next(value) * 2
end, 0)
hooks:wrap("double", function(next, value)
  return next(value + 1)
end, 10)
check(hooks:call("double", function(value) return value end, 3) == 8,
  "hook chain ordering and next")

local manifest = Manifest.validate({
  id = "test_mod", name = "Test Mod", version = "1.0.0", entry = "main.lua"
}, "mods/test_mod")
check(manifest.id == "test_mod" and manifest.path == "mods/test_mod",
  "manifest validation")

print("ok   native mod runtime")
