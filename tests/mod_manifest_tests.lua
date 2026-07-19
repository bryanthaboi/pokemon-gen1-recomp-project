-- Manifest v2 and lifecycle v2 over an injected in-memory filesystem:
-- semver ranges, game_version enforcement, conflict refusal, disabled and
-- version-mismatched dependencies, cycle isolation, inter-mod exports/find,
-- the rest of the v2 mod object, and the dev-mode permissions tripwire.
package.path = "./?.lua;./?/init.lua;" .. package.path
-- run_tests installs the stub before chaining this file; standalone runs get
-- their own so mod.assets:image has a graphics context either way
love = love or require("tests.love_stub")

local Loader = require("src.mods.Loader")
local Manifest = require("src.mods.Manifest")
local Semver = require("src.mods.Semver")
local Runtime = require("src.mods.Runtime")
local Version = require("src.core.Version")
local Logger = require("src.core.Logger")

local savedEvents, savedHooks = Runtime.events, Runtime.hooks

local S = require("tests.harness").suite("mod manifest v2")
local check = S.check

local function logged(fragmentA, fragmentB)
  for _, line in ipairs(Logger.history) do
    if line:find(fragmentA, 1, true)
        and (not fragmentB or line:find(fragmentB, 1, true)) then
      return true
    end
  end
  return false
end

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

-- fields is a table of extra manifest json fragments, e.g. {api = "2"}
local function manifestJson(id, extra)
  local parts = {
    ('"id":"%s"'):format(id), ('"name":"%s"'):format(id),
    '"version":"1.0.0"', '"entry":"main.lua"',
  }
  for key, value in pairs(extra or {}) do
    parts[#parts + 1] = ('"%s":%s'):format(key, value)
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local NOOP = "return function(mod) end\n"

local function statusById(loader)
  local byId = {}
  for _, entry in ipairs(loader:status().available) do byId[entry.id] = entry end
  return byId
end

-- ------- semver
check(Semver.satisfies("1.0.0", ">=1.0 <2.0"), "range: 1.0.0 in >=1.0 <2.0")
check(not Semver.satisfies("2.0.0", ">=1.0 <2.0"), "range: 2.0.0 out of >=1.0 <2.0")
check(Semver.satisfies("1.4.7", "^1.4"), "caret accepts a later patch")
check(not Semver.satisfies("2.0.0", "^1.4"), "caret stops at the next major")
check(Semver.satisfies("0.2.9", "^0.2") and not Semver.satisfies("0.3.0", "^0.2"),
  "caret pins the leftmost non-zero component")
check(Semver.satisfies("2.1.0", "^1.4 || ^2.0"), "|| offers alternatives")
check(Semver.compare("1.0.0-beta", "1.0.0") == -1, "a pre-release sorts first")
check(Semver.compare("1.10.0", "1.9.0") == 1, "components compare numerically")
local ok, err = Semver.satisfies("banana", ">=1.0")
check(ok == false and err ~= nil, "an unparsable version reports a reason")
local rangeOk, rangeErr = Semver.validRange(">>1.0")
check(rangeOk == false and rangeErr ~= nil, "a malformed range reports a reason")
check(Semver.parse("1").minor == 0 and Semver.parse("1.2").patch == 0,
  "absent version components default to 0")

-- ------- manifest v2 fields
local full = Manifest.validate({
  id = "full", name = "Full", version = "1.0.0", entry = "main.lua",
  api = 2, profile = "overhaul", permissions = { "network" },
  dependencies = { "colorlib@^1.2" }, conflicts = { "always_noon" },
  options_schema = "options.lua", assets_transforms = "transforms.lua",
}, "mods/full")
check(full.api == 2 and full.profile == "overhaul", "api and profile parse")
check(full.affects_link == true, "overhaul defaults to affecting link play")
check(full.permissionSet.network == true, "permissions normalize to a set")
check(full.dependencySpecs[1].id == "colorlib"
  and full.dependencySpecs[1].range == "^1.2", "dependency pins parse as id@range")
check(full.conflictSpecs[1].id == "always_noon" and full.conflictSpecs[1].range == nil,
  "a bare conflict entry has no range")
check(full.options_schema == "options.lua"
  and full.assets_transforms == "transforms.lua", "declared files are kept")

local v1 = Manifest.validate({
  id = "v1", name = "V1", version = "1.0.0", entry = "main.lua",
}, "mods/v1")
check(v1.api == 1, "an absent api means 1")
check(v1.profile == "content" and v1.affects_link == false,
  "a content profile is the default and does not claim link relevance")
check(#v1.permissions == 0 and next(v1.permissionSet) == nil,
  "no permissions declared means none granted")

check(not pcall(Manifest.validate, {
  id = "future", name = "Future", version = "1.0.0", entry = "main.lua",
  api = Version.modApi + 1,
}, "mods/future"), "an api newer than the engine fails validation")
check(not pcall(Manifest.validate, {
  id = "badprofile", name = "Bad", version = "1.0.0", entry = "main.lua",
  api = 2, profile = "nonsense",
}, "mods/badprofile"), "an unknown profile fails for api 2")
local coerced = Manifest.validate({
  id = "oldprofile", name = "Old", version = "1.0.0", entry = "main.lua",
  profile = "nonsense",
}, "mods/oldprofile")
check(coerced.profile == "content", "an unknown profile coerces for api 1")
check(logged("[oldprofile]", "unknown profile"), "the coercion is attributed")
check(not pcall(Manifest.validate, {
  id = "badperm", name = "Bad", version = "1.0.0", entry = "main.lua",
  api = 2, permissions = { "root" },
}, "mods/badperm"), "an unknown permission fails for api 2")
check(pcall(Manifest.validate, {
  id = "oldperm", name = "Old", version = "1.0.0", entry = "main.lua",
  permissions = { "root" },
}, "mods/oldperm"), "an unknown permission only warns for api 1")
check(not pcall(Manifest.validate, {
  id = "badrange", name = "Bad", version = "1.0.0", entry = "main.lua",
  game_version = ">>1.0",
}, "mods/badrange"), "a malformed game_version fails validation")
check(not pcall(Manifest.validate, {
  id = "baddep", name = "Bad", version = "1.0.0", entry = "main.lua",
  dependencies = { "other@nonsense" },
}, "mods/baddep"), "a malformed dependency range fails validation")

-- ------- game_version against the engine
local versionLoader = Loader.new({ fs = memfs({
  ["mods/future/manifest.json"] = manifestJson("future", { game_version = '">=2.0"' }),
  ["mods/future/main.lua"] = "return function(mod) mod.content.items:register('NOPE', {}) end",
  ["mods/current/manifest.json"] = manifestJson("current", { game_version = '">=1.0 <2.0"' }),
  ["mods/current/main.lua"] = NOOP,
}) })
local versionData = { items = {} }
check(versionLoader:load(versionData) == false, "a game_version miss fails the load")
local versionStatus = statusById(versionLoader)
check(versionStatus.future.state == "invalid",
  "the mod that outranges the engine is refused")
check(versionStatus.future.error:find(Version.engine, 1, true) ~= nil,
  "the refusal names the engine version")
check(versionData.items.NOPE == nil, "a refused mod never runs its entry chunk")
check(versionStatus.current.state == "loaded",
  "a satisfied game_version range still loads")

local shelvedLoader = Loader.new({ fs = memfs({
  ["mods/future/manifest.json"] = manifestJson("future", { game_version = '">=2.0"' }),
  ["mods/future/main.lua"] = NOOP,
  ["options.lua"] = "return { mods = { future = false } }",
}) })
check(shelvedLoader:load({}) == true,
  "a switched-off mod that could not load is not a boot problem")
check(statusById(shelvedLoader).future.state == "disabled",
  "a switched-off mod reports as disabled, not as invalid")

-- ------- conflicts refuse to co-enable
local conflictLoader = Loader.new({ fs = memfs({
  ["mods/noon/manifest.json"] = manifestJson("noon", { conflicts = '["dusk"]' }),
  ["mods/noon/main.lua"] = NOOP,
  ["mods/dusk/manifest.json"] = manifestJson("dusk", { conflicts = '["noon"]' }),
  ["mods/dusk/main.lua"] = NOOP,
  ["mods/bystander/manifest.json"] = manifestJson("bystander"),
  ["mods/bystander/main.lua"] = NOOP,
}) })
check(conflictLoader:load({}) == false, "mutual conflicts fail the load")
local conflictStatus = statusById(conflictLoader)
check(conflictStatus.noon.state == "conflict" and conflictStatus.dusk.state == "conflict",
  "two mods declaring each other both refuse to co-enable")
check(conflictStatus.noon.error:find("conflicts with dusk", 1, true) ~= nil,
  "the conflict message names the other mod")
check(conflictStatus.bystander.state == "loaded", "an unrelated mod still loads")

local onesidedLoader = Loader.new({ fs = memfs({
  ["mods/picky/manifest.json"] = manifestJson("picky", { conflicts = '["plain@^1.0"]' }),
  ["mods/picky/main.lua"] = NOOP,
  ["mods/plain/manifest.json"] = manifestJson("plain"),
  ["mods/plain/main.lua"] = NOOP,
}) })
onesidedLoader:load({})
local onesidedStatus = statusById(onesidedLoader)
check(onesidedStatus.picky.state == "conflict" and onesidedStatus.plain.state == "loaded",
  "the declaring mod loses a one-sided conflict")

-- ------- dependency enabled-ness, version ranges, and missing deps
local depFiles = {
  ["mods/lib/manifest.json"] = manifestJson("lib"),
  ["mods/lib/main.lua"] = NOOP,
  ["mods/user/manifest.json"] = manifestJson("user", { dependencies = '["lib"]' }),
  ["mods/user/main.lua"] = "return function(mod) mod.content.items:register('DEP_ITEM', {}) end",
  ["options.lua"] = "return { mods = { lib = false } }",
}
local depData = { items = {} }
local depLoader = Loader.new({ fs = memfs(depFiles) })
check(depLoader:load(depData) == false, "a disabled dependency fails the load")
local depStatus = statusById(depLoader)
check(depStatus.user.state == "blocked_dependency"
  and depStatus.user.error:find("dependency lib is disabled", 1, true) ~= nil,
  "a mod whose hard dependency is disabled fails with a manager-visible error")
check(depData.items.DEP_ITEM == nil, "the blocked mod never registered anything")

local rangeLoader = Loader.new({ fs = memfs({
  ["mods/lib/manifest.json"] = manifestJson("lib"),
  ["mods/lib/main.lua"] = NOOP,
  ["mods/user/manifest.json"] = manifestJson("user", { dependencies = '["lib@^2.0"]' }),
  ["mods/user/main.lua"] = NOOP,
}) })
rangeLoader:load({})
check(statusById(rangeLoader).user.error:find("needs lib@^2.0, found 1.0.0", 1, true) ~= nil,
  "a version-mismatched dependency names the range and the version found")

local missingLoader = Loader.new({ fs = memfs({
  ["mods/user/manifest.json"] = manifestJson("user", { dependencies = '["ghost"]' }),
  ["mods/user/main.lua"] = NOOP,
}) })
missingLoader:load({})
check(statusById(missingLoader).user.error:find("missing dependency: ghost", 1, true) ~= nil,
  "a missing dependency is named")

-- a mod whose dependency crashes must not run on top of a rolled-back mod
local transitiveLoader = Loader.new({ fs = memfs({
  ["mods/broken/manifest.json"] = manifestJson("broken"),
  ["mods/broken/main.lua"] = "return function(mod) error('entry blew up') end",
  ["mods/onbroken/manifest.json"] = manifestJson("onbroken", { dependencies = '["broken"]' }),
  ["mods/onbroken/main.lua"] = "return function(mod) mod.content.items:register('LATE', {}) end",
}) })
local transitiveData = { items = {} }
transitiveLoader:load(transitiveData)
local transitiveStatus = statusById(transitiveLoader)
check(transitiveStatus.broken.state == "failed", "a throwing entry chunk fails its mod")
check(transitiveStatus.onbroken.state == "blocked_dependency"
  and transitiveStatus.onbroken.error:find("failed to load", 1, true) ~= nil,
  "a dependent of a crashed mod is stopped before it runs")
check(transitiveData.items.LATE == nil, "the dependent registered nothing")

-- ------- a cycle disables only its own members
local cycleLoader = Loader.new({ fs = memfs({
  ["mods/alpha/manifest.json"] = manifestJson("alpha", { dependencies = '["beta"]' }),
  ["mods/alpha/main.lua"] = NOOP,
  ["mods/beta/manifest.json"] = manifestJson("beta", { dependencies = '["alpha"]' }),
  ["mods/beta/main.lua"] = NOOP,
  ["mods/innocent/manifest.json"] = manifestJson("innocent"),
  ["mods/innocent/main.lua"] = "return function(mod) mod.content.items:register('FINE', {}) end",
}) })
local cycleData = { items = {} }
check(cycleLoader:load(cycleData) == false, "a cycle is reported, not raised")
local cycleStatus = statusById(cycleLoader)
check(cycleStatus.alpha.state == "blocked_dependency"
  and cycleStatus.beta.state == "blocked_dependency",
  "both cycle members are disabled")
check(cycleStatus.alpha.error:find("circular dependency", 1, true) ~= nil,
  "the cycle members are told why")
check(cycleStatus.innocent.state == "loaded" and cycleData.items.FINE ~= nil,
  "a mod beside the cycle loads normally")

-- ------- inter-mod exports and find
_G.MOD_FIND_RESULTS = {}
local exportLoader = Loader.new({ fs = memfs({
  ["mods/colorlib/manifest.json"] = manifestJson("colorlib"),
  ["mods/colorlib/main.lua"] = [[
return function(mod)
  mod.exports = { tint = function(name) return "tinted:" .. name end }
end
]],
  ["mods/radio/manifest.json"] = manifestJson("radio"),
  ["mods/radio/main.lua"] = NOOP,
  ["mods/daynight/manifest.json"] = manifestJson("daynight", {
    dependencies = '["colorlib@^1.0"]', optional_dependencies = '["radio","absent_radio"]',
  }),
  ["mods/daynight/main.lua"] = [[
return function(mod)
  local results = _G.MOD_FIND_RESULTS
  local color = mod.find("colorlib")
  results.depVersion = color.version
  results.tint = color.exports.tint("dusk")
  results.optional = mod.find("radio") ~= nil
  results.absent = mod.find("absent_radio")
  results.disabled = mod.find("shelved")
  results.method = mod:find("colorlib") ~= nil
end
]],
  ["mods/shelved/manifest.json"] = manifestJson("shelved"),
  ["mods/shelved/main.lua"] = NOOP,
  ["options.lua"] = "return { mods = { shelved = false } }",
}) })
check(exportLoader:load({}) == true, "the export fixture loads clean")
local found = _G.MOD_FIND_RESULTS
check(found.tint == "tinted:dusk", "find returns the other mod's live export table")
check(found.depVersion == "1.0.0", "the handle carries the other mod's version")
check(found.optional == true, "an enabled optional dependency is findable")
check(found.absent == nil, "find returns nil for a mod that is not installed")
check(found.disabled == nil, "find returns nil for a disabled mod")
check(found.method == true, "mod:find is tolerated alongside mod.find")
check(exportLoader.order[1] == "colorlib",
  "a hard dependency executes before its dependent")
_G.MOD_FIND_RESULTS = nil

-- ------- the rest of the v2 mod object
_G.MOD_OBJECT_PROBE = {}
local objectLoader = Loader.new({ fs = memfs({
  ["mods/probe/manifest.json"] = manifestJson("probe", {
    api = "2", description = '"probing"', priority = "3",
  }),
  ["mods/probe/data.txt"] = "hello from the mod dir",
  ["mods/probe/main.lua"] = [[
return function(mod)
  local probe = _G.MOD_OBJECT_PROBE
  probe.id, probe.version, probe.path = mod.id, mod.version, mod.path
  probe.manifestApi = mod.manifest.api
  mod.manifest.api = 99
  probe.read = mod:read("data.txt")
  probe.assetPath = mod.assets:path("sprites/x.png")
  probe.aliasedRegistry = mod.assets.pokemon ~= nil
  probe.image = mod.assets:image("sprites/x.png")
  probe.imageCached = mod.assets:image("sprites/x.png") == probe.image

  mod.options:define({ { key = "dusk_hour", type = "number", default = 18 } })
  probe.optionDefault = mod.options:get("dusk_hour")
  probe.optionStored = mod.options:get("volume")
  probe.saveDefault = mod.save:get("clock_hour", 12)
  mod.save:set("clock_hour", 6)
  probe.saveRoundTrip = mod.save:get("clock_hour", 12)

  mod.commands:register("do_thing", function() return "done" end)
  mod.migrations:add("1.0.0", function() end)

  local fired = 0
  mod.events:once("mod.probe.ping", function() fired = fired + 1 end)
  mod.events:on("mod.probe.ping", function() probe.stillHeard = true end)
  mod.events:emit("mod.probe.ping", {})
  mod.events:emit("mod.probe.ping", {})
  probe.onceCount = fired
  probe.forgery = select(2, pcall(function() mod.events:emit("battle.started", {}) end))
end
]],
  ["options.lua"] = "return { modOptions = { probe = { volume = 4 } } }",
}) })
check(objectLoader:load({ pokemon = {} }) == true, "the mod object fixture loads clean")
local probe = _G.MOD_OBJECT_PROBE
check(probe.id == "probe" and probe.version == "1.0.0" and probe.path == "mods/probe",
  "identity fields are present")
check(probe.manifestApi == 2 and objectLoader.mods.probe.manifest.api == 2,
  "mod.manifest is a copy: writing to it cannot reach the loader")
check(probe.read == "hello from the mod dir", "mod:read still reads the mod dir")
check(probe.assetPath == "mods/probe/sprites/x.png", "assets:path builds a virtual path")
check(probe.aliasedRegistry == true, "assets keeps the v1 alias to the registries")
check(probe.image ~= nil and probe.imageCached == true,
  "assets:image loads from the mod dir and caches per path")
check(probe.optionDefault == 18, "options:get falls back to the declared default")
check(probe.optionStored == 4, "options:get prefers the stored value")
check(objectLoader.optionSchemas.probe[1].key == "dusk_hour",
  "the options schema is recorded for the manager")
check(probe.saveDefault == 12 and probe.saveRoundTrip == 6,
  "save:get honours the default and reads back what set wrote")
-- the sugar writes straight into the commands registry now that M4 has
-- declared it, so the verb is owned there rather than in the holding table
check(objectLoader.content.commands:get("do_thing") ~= nil
  and objectLoader.content.commands.owners.do_thing == "probe",
  "commands:register records the verb against its mod")
check(objectLoader.migrations.probe[1].since == "1.0.0", "migrations are recorded")
check(probe.onceCount == 1 and probe.stillHeard == true,
  "events:once fires once and does not skip the listener behind it")
check(tostring(probe.forgery):find("may only emit", 1, true) ~= nil,
  "a mod cannot emit outside its own event namespace")
_G.MOD_OBJECT_PROBE = nil

-- a failing entry chunk takes its exports, commands and migrations with it
local residueLoader = Loader.new({ fs = memfs({
  ["mods/messy/manifest.json"] = manifestJson("messy"),
  ["mods/messy/main.lua"] = [[
return function(mod)
  mod.exports = { hello = true }
  mod.commands:register("messy_verb", function() end)
  mod.migrations:add("1.0.0", function() end)
  error("messy failed late")
end
]],
}) })
residueLoader:load({})
check(residueLoader.exports.messy == nil, "a failed mod publishes no exports")
check(residueLoader.content.commands:get("messy_verb") == nil,
  "a failed mod leaves no command")
check(residueLoader.migrations.messy == nil, "a failed mod leaves no migration")

-- ------- dev-mode permissions tripwire
local devFiles = {
  ["mods/nosy/manifest.json"] = manifestJson("nosy"),
  ["mods/nosy/main.lua"] = [[
return function(mod)
  pcall(require, "src.battle.BattleState")
end
]],
  ["mods/declared/manifest.json"] = manifestJson("declared", {
    api = "2", permissions = '["engine_internals"]',
  }),
  ["mods/declared/main.lua"] = [[
return function(mod)
  pcall(require, "src.battle.BattleState")
end
]],
}
local devLoader = Loader.new({ fs = memfs(devFiles), dev = true })
local historyMark = #Logger.history
check(devLoader:load({}) == true, "the dev fixture loads clean")
local sawUndeclared, sawDeclared = false, false
for index = historyMark + 1, #Logger.history do
  local line = Logger.history[index]
  if line:find("[nosy]", 1, true)
    and line:find("undeclared engine_internals require: src.battle.BattleState", 1, true) then
    sawUndeclared = true
  end
  if line:find("[declared]", 1, true) and line:find("undeclared", 1, true) then
    sawDeclared = true
  end
end
check(sawUndeclared,
  "an undeclared private engine require is attributed to the mod that made it")
check(not sawDeclared, "a mod that declared engine_internals is not warned about")
check(Runtime.currentMod == nil, "no mod frame is left open after the load")

-- engine requires outside a mod frame stay silent
local engineMark = #Logger.history
require("src.core.Data")
for index = engineMark + 1, #Logger.history do
  check(not Logger.history[index]:find("undeclared", 1, true),
    "an engine require outside a mod frame is not warned about")
end

-- ------- parity: with no mod nothing new appears and nothing is refused
local pristine = { pokemon = { A = { hp = 1 } }, items = {} }
local emptyLoader = Loader.new({ fs = memfs({}) })
check(emptyLoader:load(pristine) == true, "an empty mods dir still loads clean")
check(#emptyLoader:status().errors == 0, "no mods means no diagnostics")
check(#emptyLoader.order == 0, "no mods means an empty load order")
check(pristine.pokemon.A.hp == 1 and next(pristine.items) == nil,
  "no-mod load leaves data untouched")

Runtime.install(savedEvents, savedHooks)

S.finish()
