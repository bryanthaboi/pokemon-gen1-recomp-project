-- Headless mod-loader tests over an injected in-memory filesystem:
-- discovery, dependency order, merge, rollback, unseal, emit isolation,
-- the no-love run, and the no-mod lifecycle parity (mods.loaded /
-- game.ready fire once).
package.path = "./?.lua;./?/init.lua;" .. package.path

local Loader = require("src.mods.Loader")
local Events = require("src.mods.Events")
local Runtime = require("src.mods.Runtime")
local Logger = require("src.core.Logger")

local savedEvents, savedHooks = Runtime.events, Runtime.hooks

local S = require("tests.harness").suite("headless mod loader")
local check = S.check

local function logged(fragmentA, fragmentB)
  for _, line in ipairs(Logger.history) do
    if line:find(fragmentA, 1, true) and line:find(fragmentB, 1, true) then
      return true
    end
  end
  return false
end

-- the fs surface the loader needs, backed by a flat path->content table
local function memfs(files)
  return {
    read = function(path) return files[path] end,
    getInfo = function(path)
      if files[path] then return { type = "file" } end
      local prefix = path .. "/"
      for key in pairs(files) do
        if key:sub(1, #prefix) == prefix then return { type = "directory" } end
      end
      return nil
    end,
    load = function(path)
      if not files[path] then return nil, "no file: " .. path end
      return load(files[path], path)
    end,
    getDirectoryItems = function(path)
      local seen, items = {}, {}
      local prefix = path .. "/"
      for key in pairs(files) do
        if key:sub(1, #prefix) == prefix then
          local child = key:sub(#prefix + 1):match("^[^/]+")
          if child and not seen[child] then
            seen[child] = true
            items[#items + 1] = child
          end
        end
      end
      table.sort(items)
      return items
    end,
  }
end

local function manifestJson(id, deps)
  return ([[{"id":"%s","name":"%s","version":"1.0.0","entry":"main.lua","dependencies":%s}]])
    :format(id, id, deps or "[]")
end

-- ------- no love global: the loader runs on opts.fs alone.
-- run_tests installs a stub love before chaining this file, so the global
-- is stashed and nilled to prove nothing on the load path reaches for it.
local savedLove = love
love = nil
local headlessOk, headlessErr = pcall(function()
  local headlessFiles = {
    -- a stale entry for an uninstalled mod must survive the round-trip
    ["options.lua"] = "return { mods = { ghost = false } }",
    ["mods/solo/manifest.json"] = manifestJson("solo"),
    ["mods/solo/main.lua"] = [[
return function(mod)
  mod.content.pokemon:register("SOLOMON", { name = "SOLOMON" })
end
]],
  }
  local headlessFs = memfs(headlessFiles)
  headlessFs.write = function(path, content)
    headlessFiles[path] = content
    return true
  end
  local headlessData = { pokemon = {} }
  local headlessLoader = Loader.new({ fs = headlessFs })
  check(headlessLoader:load(headlessData) == true,
    "load runs with no love global")
  check(headlessData.pokemon.SOLOMON ~= nil,
    "no-love load merges registered content")
  check(headlessLoader:setEnabled("solo", false) == true,
    "enable toggle works with no love global")
  check(headlessFiles["options.lua"]:find("solo = false", 1, true) ~= nil,
    "enable state persists through the injected fs")
  check(headlessFiles["options.lua"]:find("ghost = false", 1, true) ~= nil,
    "existing options entries survive the state write")
end)
love = savedLove
if not headlessOk then error(headlessErr) end

love = love or require("tests.love_stub")

-- ------- discovery, dependency order, merge
-- "addon" sorts before "base" so only the dependency edge can order them
_G.MOD_TEST_ORDER = {}
local files = {
  ["mods/addon/manifest.json"] = manifestJson("addon", '["base"]'),
  ["mods/addon/main.lua"] = [[
return function(mod)
  _G.MOD_TEST_ORDER[#_G.MOD_TEST_ORDER + 1] = "addon"
  mod.content.pokemon:override("MODMON", { name = "ADDONMON" })
end
]],
  ["mods/base/manifest.json"] = manifestJson("base"),
  ["mods/base/main.lua"] = [[
return function(mod)
  _G.MOD_TEST_ORDER[#_G.MOD_TEST_ORDER + 1] = "base"
  mod.content.pokemon:register("MODMON", { name = "BASEMON" })
  mod.content.music:register("MOD_SONG", { file = "song.ogg" })
end
]],
}
local data = { pokemon = { PIKA = { name = "PIKA" } }, audio = {} }
local loader = Loader.new({ fs = memfs(files) })
check(loader:load(data) == true, "headless load succeeds with injected fs")
check(loader.mods.addon ~= nil and loader.mods.base ~= nil,
  "discovery finds both mods")
check(_G.MOD_TEST_ORDER[1] == "base" and _G.MOD_TEST_ORDER[2] == "addon",
  "topo-sort runs the dependency before its dependent")
check(data.pokemon.MODMON ~= nil and data.pokemon.MODMON.name == "ADDONMON",
  "registered content merges into data")
check(data.pokemon.PIKA.name == "PIKA", "base records untouched by the merge")
check(data.audio.songs ~= nil and data.audio.songs.MOD_SONG ~= nil,
  "music registrations merge into data.audio.songs")

-- content froze at the merge boundary; the buses stayed open
check(not pcall(function() loader.content.pokemon:register("LATE", {}) end),
  "content registries freeze after the merge loop")
local heard = 0
loader.events:on("post.boot", function() heard = heard + 1 end, 0, "test")
loader.events:emit("post.boot")
check(heard == 1, "runtime subscription after load succeeds (unsealed)")

-- ------- rollback: a failing entry chunk leaves zero residue
local rollbackFiles = {
  ["mods/base/manifest.json"] = manifestJson("base"),
  ["mods/base/main.lua"] = [[
return function(mod)
  mod.content.pokemon:register("SHARED", { name = "BASE" })
end
]],
  ["mods/crasher/manifest.json"] = manifestJson("crasher", '["base"]'),
  ["mods/crasher/main.lua"] = [[
return function(mod)
  mod.content.pokemon:register("CRASHMON", { name = "CRASH" })
  mod.content.pokemon:override("SHARED", { name = "CRASHED" })
  mod.events:on("mods.loaded", function() end)
  mod.hooks:wrap("battle.damage", function(next, ...) return next(...) end)
  error("crasher entry failed")
end
]],
  ["mods/survivor/manifest.json"] = manifestJson("survivor"),
  ["mods/survivor/main.lua"] = [[
return function(mod)
  mod.content.items:register("SURVIVOR_ITEM", { price = 5 })
end
]],
}
local rollbackData = { pokemon = {}, items = {} }
local rollbackLoader = Loader.new({ fs = memfs(rollbackFiles) })
check(rollbackLoader:load(rollbackData) == false, "load reports the failing mod")
check(rollbackData.pokemon.SHARED ~= nil
  and rollbackData.pokemon.SHARED.name == "BASE",
  "failed override rolled back to the earlier mod's value")
check(rollbackData.pokemon.CRASHMON == nil,
  "failed registration never reaches merged data")
check(rollbackLoader.content.pokemon.ops.CRASHMON == nil
  and rollbackLoader.content.pokemon.owners.CRASHMON == nil,
  "failed registration leaves no registry residue")
check(rollbackLoader.content.pokemon.owners.SHARED == "base",
  "registry owner restored on rollback")
check(rollbackLoader.events.listeners["mods.loaded"] == nil,
  "failed mod's event subscription removed")
check(rollbackLoader.hooks.chains["battle.damage"] == nil,
  "failed mod's hook wrap removed")
check(rollbackData.items.SURVIVOR_ITEM ~= nil,
  "unrelated mod still loads after a failure")

-- ------- safe emit: a throwing listener never breaks the emitting path
local isoFiles = {
  ["mods/noisy/manifest.json"] = manifestJson("noisy"),
  ["mods/noisy/main.lua"] = [[
return function(mod)
  mod.events:on("mods.loaded", function() error("noisy listener blew up") end)
end
]],
}
local isoLoader = Loader.new({ fs = memfs(isoFiles) })
check(isoLoader:load({ pokemon = {} }) == true,
  "a throwing listener does not fail the load")
check(logged("[noisy]", "mods.loaded"),
  "listener failure attributed to the subscribing mod")

-- ------- no-mod parity: an empty mods dir merges nothing, adds nothing
local pristine = { pokemon = { A = { hp = 1 } }, moves = {} }
local emptyLoader = Loader.new({ fs = memfs({}) })
local loadedCount = 0
emptyLoader.events:on("mods.loaded", function() loadedCount = loadedCount + 1 end,
  0, "test")
check(emptyLoader:load(pristine) == true, "empty load succeeds")
check(loadedCount == 1, "mods.loaded fires exactly once with mods absent")
check(pristine.pokemon.A.hp == 1 and next(pristine.moves) == nil,
  "no-mod load leaves data untouched")
-- the engine's own registrations create their namespaces on every boot;
-- nothing else may appear
local engineRoots = require("src.mods.Builtins").namespaceRoots()
for key in pairs(pristine) do
  check(key == "pokemon" or key == "moves" or engineRoots[key],
    "no-mod load adds only engine namespaces (saw " .. key .. ")")
end

-- ------- full boot: game.ready and mods.loaded fire exactly once each.
-- Events.emit is patched at the metatable so both buses are counted.
local counts = {}
local realEmit = Events.emit
Events.emit = function(self, name, payload)
  counts[name] = (counts[name] or 0) + 1
  return realEmit(self, name, payload)
end
local Game = require("src.core.Game")
Game:load()
Events.emit = realEmit
check(counts["mods.loaded"] == 1, "boot emits mods.loaded exactly once")
check(counts["game.ready"] == 1, "boot emits game.ready exactly once")

-- leave shared singletons the way we found them for later chained tests
local StateStack = require("src.core.StateStack")
while StateStack:top() do StateStack:pop() end
require("src.core.Music").stop()
Runtime.install(savedEvents, savedHooks)
_G.MOD_TEST_ORDER = nil

S.finish()
