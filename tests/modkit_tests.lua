-- M13 developer tooling: the fixture dataset under the headless loader,
-- hot reload (teardown + re-merge + cache invalidation), the dev console
-- (repl, verbs, tracer), the quarantine report screen, and the modkit CLI
-- (scaffold / validate / lint).  Self-contained like the sibling mod
-- suites: own bootstrap, assert-based checks, error() on failure.
package.path = "./?.lua;./?/init.lua;" .. package.path

-- parity first: nothing before this suite may have dragged dev code in
assert(package.loaded["src.dev.HotReload"] == nil,
  "no src/dev module loads without the dev hotkeys")
assert(package.loaded["src.dev.Console"] == nil,
  "no console load without the dev hotkeys")

local Loader = require("src.mods.Loader")
local Runtime = require("src.mods.Runtime")
local Assets = require("src.render.Assets")
local fixture = require("tests.fixture_data")

local savedEvents, savedHooks = Runtime.events, Runtime.hooks
local savedErrors = Runtime.errors
local savedWants, savedWantsHook = Runtime.wants, Runtime.wantsHook

local S = require("tests.harness").suite("modkit")
local check = S.check

local function deepEqual(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do
    if not deepEqual(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

local function memfs(files)
  return {
    read = function(path) return files[path] end,
    write = function(path, body) files[path] = body return true end,
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
      return loadstring(files[path], path)
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

-- ------- carried handoff: the data-driven move repair floor

check(require("src.core.Data").constants.fallbackMove == "TACKLE",
  "CONSTANT_DEFAULTS seeds fallbackMove = TACKLE")

-- ------- fixture dataset: complete, ROM-free, loader-ready

local data = fixture.load()
for _, name in ipairs(fixture.MODULES) do
  check(type(data[name]) == "table", "fixture module present: " .. name)
end
check(data.pokemon.FIXMON_A.evolutions[1].species == "FIXMON_B",
  "fixture evolution chain")
check(data.maps.FIX_TOWN.width * data.maps.FIX_TOWN.height
    == #data.maps.FIX_TOWN.blocks, "fixture map blocks match dimensions")
for id, def in pairs(data.pokemon) do
  check(def.spriteFront:find("tests/fixture_data/", 1, true) == 1,
    "fixture sprite stays ROM-free: " .. id)
  local handle = io.open(def.spriteFront, "rb")
  check(handle ~= nil, "fixture sprite file exists: " .. def.spriteFront)
  handle:close()
end

-- the loader runs over the fixture with no love global and no ROM
local savedLove = love
love = nil
local fixtureOk, fixtureErr = pcall(function()
  local files = {
    ["mods/fix_mod/manifest.json"] =
      [[{"id":"fix_mod","name":"Fix","version":"1.0.0","entry":"main.lua","api":2}]],
    ["mods/fix_mod/main.lua"] = [[
return function(mod)
  mod.content.pokemon:patch("FIXMON_A", { baseStats = { speed = 99 } })
end
]],
  }
  local headless = Loader.new({ fs = memfs(files) })
  local freshData = fixture.load()
  check(headless:load(freshData) == true, "fixture loader run is clean")
  check(freshData.pokemon.FIXMON_A.baseStats.speed == 99,
    "fixture merge applies the patch")
  check(freshData.pokemon.FIXMON_A.baseStats.hp == 45,
    "fixture merge keeps unpatched fields")
end)
love = savedLove
if not fixtureOk then error(fixtureErr) end
love = love or require("tests.love_stub")

-- ------- hot reload: edit -> F5 -> live change, pristine base, caches flushed

local hotFiles = {
  ["mods/hot_mod/manifest.json"] =
    [[{"id":"hot_mod","name":"Hot","version":"1.0.0","entry":"main.lua","api":2}]],
  ["mods/hot_mod/main.lua"] = [[
return function(mod)
  mod.content.pokemon:patch("FIXMON_A", { baseStats = { speed = 99 } })
  mod.events:on("game.ready", function()
    _G.MODKIT_TEST_READY = (_G.MODKIT_TEST_READY or 0) + 1
  end)
end
]],
}
local hotFs = memfs(hotFiles)

-- a Data-shaped table whose reloadGenerated rebuilds from the fixture, the
-- same restore-to-pristine contract src/core/Data.lua implements for the
-- generated cache
local function freshHotData()
  local d = fixture.load()
  function d:reloadGenerated()
    local pristine = fixture.load()
    for key in pairs(self) do
      if key ~= "reloadGenerated" then self[key] = nil end
    end
    for key, value in pairs(pristine) do self[key] = value end
  end
  return d
end

_G.MODKIT_TEST_READY = 0
local hotData = freshHotData()
local game = { data = hotData, save = { modData = {} } }
local bootLoader = Loader.new({ fs = hotFs })
bootLoader.game = game
game.mods = bootLoader
check(bootLoader:load(hotData) == true, "hot-reload boot load is clean")
game.modStatus = bootLoader:status()
check(hotData.pokemon.FIXMON_A.baseStats.speed == 99, "boot merge applied")

-- content froze at boot; the reload path must still work because it swaps
-- in a fresh loader instead of writing into the frozen registries
local frozen = pcall(function()
  bootLoader.content.pokemon:patch("FIXMON_A", { baseStats = { hp = 1 } }, "x")
end)
check(frozen == false, "boot registries are frozen")

local flushed = 0
Assets.register(function() flushed = flushed + 1 end)

-- the edit: same mod file, new value
hotFiles["mods/hot_mod/main.lua"] = hotFiles["mods/hot_mod/main.lua"]
  :gsub("speed = 99", "speed = 123")

-- the audio caches ride the same bus (20 §2, audio rows): a cached sfx
-- source and the chip music state must not survive the flush
local Sound = require("src.core.Sound")
local ChipAudio = require("src.core.ChipAudio")
local savedAudio = love.audio
local sourcesMade = 0
love.audio = { newSource = function()
  sourcesMade = sourcesMade + 1
  local src = {}
  function src:play() self.playing = true end
  function src:stop() self.playing = false end
  function src:setVolume() end
  function src:isPlaying() return self.playing end
  return src
end }
local beepData = { audio = { sfx = { Fix_Beep = "assets/fix_beep.wav" } } }
Sound.play(beepData, "Fix_Beep")
Sound.play(beepData, "Fix_Beep")
check(sourcesMade == 1, "a played sfx source is cached")
-- invalidate reaches stopMusic through the module table, so a swap here
-- observes the bus call without touching ChipAudio internals
local savedStopMusic = ChipAudio.stopMusic
local musicStops = 0
ChipAudio.stopMusic = function() musicStops = musicStops + 1 end

local HotReload = require("src.dev.HotReload")
local reloaded, summary = HotReload.run(game, { fs = hotFs })
check(reloaded ~= bootLoader, "reload builds a fresh loader")
check(game.mods == reloaded, "game adopts the fresh loader")
check(hotData.pokemon.FIXMON_A.baseStats.speed == 123,
  "edited value is live after reload")
check(hotData.pokemon.FIXMON_A.baseStats.hp == 45,
  "unedited field survives reload")
check(deepEqual(hotData.pokemon.FIXMON_B, fixture.load().pokemon.FIXMON_B),
  "untouched base record is byte-identical after reload")
check(flushed >= 1, "reload flushed the registered caches")
check(summary:find("reloaded 1 mods", 1, true) ~= nil, "reload summary counts")
check(_G.MODKIT_TEST_READY >= 1, "game.ready re-reaches re-subscribed mods")
ChipAudio.stopMusic = savedStopMusic
check(musicStops >= 1, "reload stops chip music through the cache bus")
Sound.play(beepData, "Fix_Beep")
check(sourcesMade == 2, "reload evicted the cached sfx source")
Sound.invalidate()
love.audio = savedAudio

-- reload twice: invalidate is idempotent, the merge converges
local again = HotReload.run(game, { fs = hotFs })
check(hotData.pokemon.FIXMON_A.baseStats.speed == 123, "second reload converges")
check(#again.errors == 0, "second reload is clean")

-- a broken edit surfaces as an attributed error, not a crash
hotFiles["mods/hot_mod/main.lua"] = "return function(mod) error('boom') end"
local broken = HotReload.run(game, { fs = hotFs })
check(#broken.errors > 0, "broken edit lands in the error feed")
check(hotData.pokemon.FIXMON_A.baseStats.speed == 45,
  "broken mod rolls back to pristine base")
_G.MODKIT_TEST_READY = nil

-- ------- dev console: repl, verbs, tracer, input isolation

local Console = require("src.dev.Console")
local popped = 0
local stubStack = { states = {} }
function stubStack:top() return self.states[#self.states] end
function stubStack:pop()
  popped = popped + 1
  return table.remove(self.states)
end
function stubStack:push(state) table.insert(self.states, state) end

local inputMarker = {}
local consoleGame = {
  data = hotData,
  mods = game.mods,
  modStatus = game.mods:status(),
  save = { flags = {}, party = {}, inventory = {}, modData = {} },
  stack = stubStack,
  input = { marker = inputMarker,
            wasPressed = function() return false end },
}
local console = Console.new(consoleGame)

local function lastLine()
  return console.lines[#console.lines]
end

-- console output wraps to the canvas width, so recent-line checks scan a
-- window instead of the tail chunk alone
local function sawRecent(text)
  for i = math.max(1, #console.lines - 7), #console.lines do
    if console.lines[i]:find(text, 1, true) then return true end
  end
  return false
end

console:exec("1+1")
check(lastLine() == "2", "repl evaluates expressions")
console:exec("data.pokemon.FIXMON_A.baseStats.hp")
check(lastLine() == "45", "repl reads live data")
console:exec("nosuchfunction()")
check(sawRecent("error"), "repl reports errors")

console:exec("flag TEST_FLAG on")
check(consoleGame.save.flags.TEST_FLAG == true, "flag verb sets")
console:exec("flag TEST_FLAG off")
check(consoleGame.save.flags.TEST_FLAG == nil, "flag verb clears")

console:exec("give FIX_POTION 3")
check(consoleGame.save.inventory.FIX_POTION == 3, "give verb adds items")
console:exec("give FIXMON_C 7")
check(consoleGame.save.party[1] and consoleGame.save.party[1].species == "FIXMON_C"
  and consoleGame.save.party[1].level == 7, "give verb builds a party mon")

console:exec("mods")
local sawMod = false
for _, line in ipairs(console.lines) do
  if line:find("hot_mod", 1, true) then sawMod = true end
end
check(sawMod, "mods verb lists the loaded set")

-- tracer: events log with payloads, hooks log in -> out, wants widens
console:exec("trace fix.*")
Runtime.emit("fix.ping", { n = 7 })
check(sawRecent("fix.ping"), "tracer logs a matching event")
check(Runtime.wants("fix.anything") == true, "tracer widens wants()")
check(Runtime.wants("battle.unrelated") == false,
  "tracer leaves other names alone")
local hooked = Runtime.call("fix.hook", function(v) return v + 1 end, 2)
check(hooked == 3, "traced hook still returns the vanilla value")
local sawOut = false
for _, line in ipairs(console.lines) do
  if line:find("fix.hook", 1, true) and line:find("out", 1, true) then
    sawOut = true
  end
end
check(sawOut, "tracer logs the hook transformation")
Runtime.emit("mod.other.event", { x = 1 })
console:exec("trace off")
check(Runtime.wants("fix.anything") == false, "trace off restores wants()")

-- typed input: keys become buffer text, return executes, backtick closes
console:onKeyPressed("p")
console:onKeyPressed("p")
check(console.buffer == "pp", "letter keys append to the buffer")
console:onKeyPressed("backspace")
check(console.buffer == "p", "backspace edits the buffer")
console.buffer = "1+2"
console:onKeyPressed("return")
check(lastLine() == "3", "return executes the buffer")
console:onKeyPressed("up")
check(console.buffer == "1+2", "history recall")
console:onKeyPressed("`")
check(popped == 1, "backtick closes the console")
check(consoleGame.input.marker == inputMarker
  and consoleGame.input.state == nil,
  "console leaves game input untouched")

-- ------- quarantine report screen

local QuarantineReport = require("src.ui.QuarantineReport")
local report = {
  lostMons = { { species = "ZORUA", from = "party" } },
  lostItems = { { id = "MOD_ITEM", count = 3, from = "inventory" } },
  remappedMaps = { { id = "MOD_TOWN", to = "PALLET_TOWN", field = "player" } },
  restoredMons = { { species = "MEWTHREE", box = 2 } },
  restoredItems = {},
  recovered = "bak",
  modsDiff = { added = {}, removed = { "illusion_pack" }, changed = {} },
}
local rgame = {
  save = { meta = { mods = { { id = "illusion_pack", version = "1.1.0" } } } },
  stack = stubStack,
  input = { wasPressed = function(_, btn) return btn == "a" end },
}
local screen = QuarantineReport.new(rgame, report)
local blob = table.concat(screen.lines, "\n")
check(blob:find("ZORUA", 1, true) ~= nil, "report names the lost mon")
check(blob:find("MOD_ITEM x3", 1, true) ~= nil, "report names the lost item")
check(blob:find("MOD_TOWN", 1, true) ~= nil, "report names the remapped map")
check(blob:find("MEWTHREE", 1, true) ~= nil, "report names the restored mon")
check(blob:find("bak", 1, true) ~= nil, "report notes the backup recovery")
check(blob:find("no longer active", 1, true) ~= nil, "report carries the mods diff")
local before = popped
screen:update()
check(popped == before + 1, "CONTINUE pops the report screen")
-- draw must not throw under the stub (Font pages already loaded upstream)
local drawOk = pcall(function() screen:draw() end)
check(drawOk, "report draws headless")

-- an empty report never builds content rows
local empty = QuarantineReport.new(rgame, { lostMons = {}, lostItems = {},
  remappedMaps = {}, restoredMons = {}, restoredItems = {} })
check(#empty.lines == 0, "empty report renders no rows")

-- ------- modkit CLI: scaffold -> validate green, lint gate red

-- luajit's pclose drops the exit status, so the shell reports it in-band
local function run(command)
  local pipe = io.popen(command .. ' 2>&1; echo "EXIT:$?"')
  local output = pipe:read("*a")
  pipe:close()
  local code = tonumber(output:match("EXIT:(%d+)%s*$")) or -1
  return output, code
end

local python = "python3"
local haveTools = run(python .. " --version")
check(haveTools:find("Python 3", 1, true) ~= nil, "python3 available for modkit")

local tmp = os.tmpname()
os.remove(tmp)
local root = tmp .. "_modkit"
check(os.execute(("mkdir -p %q"):format(root)) == 0
  or os.execute(("mkdir -p %q"):format(root)) == true, "scratch dir")

local out, code = run(("%s tools/modkit.py scaffold scaffy --dest %q")
  :format(python, root))
check(code == 0, "modkit scaffold succeeds: " .. out)
local manifest = io.open(root .. "/scaffy/manifest.json", "rb")
check(manifest ~= nil, "scaffold writes a manifest")
manifest:close()

out, code = run(("%s tools/modkit.py validate %q")
  :format(python, root .. "/scaffy"))
check(code == 0, "scaffolded mod validates clean: " .. out)

-- the template patches MEW, which only the player's imported dataset carries.
-- Against that dataset MK103 resolves it; against the three-species fixture
-- the rule has no evidence either way, so it reports itself skipped rather
-- than guessing -- a warning there would be fatal under pack and --strict
local haveImported = io.open("data/generated/pokemon.lua", "rb")
if haveImported then
  haveImported:close()
  out, code = run(("%s tools/modkit.py validate %q --base imported")
    :format(python, root .. "/scaffy"))
  check(code == 0, "template validates against the imported dataset: " .. out)
  check(out:find("MK103", 1, true) == nil,
    "template patch target resolves in the imported dataset")
end
out, code = run(("%s tools/modkit.py validate %q --base fixture")
  :format(python, root .. "/scaffy"))
check(code == 0, "template stays a pass against the fixture stand-in")
check(out:find("MK103 not checked", 1, true) ~= nil,
  "the fixture base names MK103 as skipped instead of reporting it")

-- the ROM-free path CI actually runs (M13 criterion 4): the tool's own
-- onboarding example must strict-validate AND pack with no ROM imported
out, code = run(("%s tools/modkit.py validate %q --base fixture --strict")
  :format(python, root .. "/scaffy"))
check(code == 0, "template strict-validates ROM-free: " .. out)

local pkg = root .. "/scaffy.modpkg"
out, code = run(("%s tools/modkit.py pack %q -o %q --base fixture")
  :format(python, root .. "/scaffy", pkg))
check(code == 0, "template packs ROM-free: " .. out)
local packed = io.open(pkg, "rb")
check(packed ~= nil, "packing the template writes a .modpkg")
if packed then packed:close() end

-- a bad mod trips the schema rule and the no-ROM-content gate
local bad = root .. "/badmod"
os.execute(("mkdir -p %q"):format(bad))
local function write(path, body)
  local handle = assert(io.open(path, "wb"))
  handle:write(body)
  handle:close()
end
write(bad .. "/manifest.json",
  [[{"id":"badmod","name":"Bad","version":"1.0.0","api":2,"entry":"main.lua"}]])
write(bad .. "/main.lua", [[
return function(mod)
  mod.content.pokemon:patch("FIXMON_A", { base_stats = { speed = 130 } })
end
]])
write(bad .. "/hack.gb", "GBDATA")
write(bad .. "/cachepath.lua",
  'return { pic = "assets/generated/battle/front/mew.png" }')

-- pinned to the fixture so the expectations hold with or without an import
out, code = run(("%s tools/modkit.py validate %q --base fixture")
  :format(python, bad))
check(code ~= 0, "bad mod fails validate")
check(out:find("MK101", 1, true) ~= nil, "schema typo reported as MK101")
check(out:find("base_stats", 1, true) ~= nil, "MK101 names the bad field")
check(out:find("MK301", 1, true) ~= nil, "cache reference reported as MK301")
check(out:find("MK303", 1, true) ~= nil, "ROM patch file reported as MK303")

out, code = run(("%s tools/modkit.py pack %q -o %q --base fixture")
  :format(python, bad, root .. "/bad.modpkg"))
check(code ~= 0, "pack refuses a failing mod")
check(io.open(root .. "/bad.modpkg", "rb") == nil, "no package written on refusal")

-- ------- the completed rule table: MK005, MK006, MK103, MK104

-- every case below runs against the fixture so the verdicts do not depend on
-- whether the machine has an imported dataset
local function ruleMod(id, manifestExtra, body)
  local dir = root .. "/" .. id
  os.execute(("mkdir -p %q"):format(dir))
  write(dir .. "/manifest.json",
    ('{"id":"%s","name":"%s","version":"1.0.0","api":2,"entry":"main.lua"%s}')
      :format(id, id, manifestExtra or ""))
  write(dir .. "/main.lua", body)
  return dir
end

local function validate(dir, extra)
  return run(("%s tools/modkit.py validate %q --base fixture %s")
    :format(python, dir, extra or ""))
end

-- MK103: a patch whose target nothing defines is a no-op, almost always a typo
local orphan = ruleMod("orphanpatch", nil, [[
return function(mod)
  mod.content.pokemon:patch("NOSUCHMON", { baseStats = { speed = 99 } })
end
]])
-- only the imported dataset owns the vanilla id space, so only there does a
-- miss prove a typo -- and there it is an error, not an advisory warning
if haveImported then
  out, code = run(("%s tools/modkit.py validate %q --base imported")
    :format(python, orphan))
  check(out:find("MK103", 1, true) ~= nil,
    "orphan patch target reported as MK103: " .. out)
  check(out:find("NOSUCHMON", 1, true) ~= nil, "MK103 names the missing target")
  check(code ~= 0, "MK103 fails validate against the authoritative base")
end
-- the fixture cannot tell NOSUCHMON from MEW, so it says so and stays out of
-- the exit code under both plain and --strict runs
out, code = validate(orphan)
check(code == 0, "MK103 is skipped, not guessed, against the fixture: " .. out)
check(out:find("MK103 not checked", 1, true) ~= nil,
  "the skip names the rule that did not run")
out, code = validate(orphan, "--strict")
check(code == 0, "--strict cannot promote a rule that never ran: " .. out)

-- ...and stays quiet for a target the base defines, or one the load set
-- registers itself
local anchored = ruleMod("anchoredpatch", nil, [[
return function(mod)
  mod.content.pokemon:patch("FIXMON_A", { baseStats = { speed = 99 } })
  mod.content.tokens:register("MK103_TOK", function() return "a" end)
  mod.content.tokens:patch("MK103_TOK", function() return "b" end)
end
]])
out, code = validate(anchored)
check(code == 0, "a grounded patch validates clean: " .. out)
check(out:find("MK103", 1, true) == nil,
  "MK103 spares a base id and a self-registered id")

-- MK104: a tombstone that strands a live reference is its own rule, not an
-- unclassified cross-ref failure
local orphanRemove = ruleMod("orphanremove", nil, [[
return function(mod)
  mod.content.pokemon:remove("FIXMON_B")
end
]])
out, code = validate(orphanRemove)
check(code ~= 0, "a remove that strands a reference fails validate")
check(out:find("MK104", 1, true) ~= nil, "orphaning remove reported as MK104: " .. out)
check(out:find("FIXMON_B", 1, true) ~= nil, "MK104 names the removed id")

-- a plain dangling reference is still MK102; MK104 must not swallow it
local dangling = ruleMod("danglingref", nil, [[
return function(mod)
  mod.content.pokemon:patch("FIXMON_A", {
    evolutions = { { method = "LEVEL", level = 9, species = "NOPEMON" } },
  })
end
]])
out, code = validate(dangling)
check(code ~= 0, "a dangling reference fails validate")
check(out:find("MK102", 1, true) ~= nil, "plain dangling reference stays MK102")
check(out:find("MK104", 1, true) == nil, "MK104 does not swallow plain dangling refs")

-- MK005: the permission vocabulary is the engine's own
local badPerm = ruleMod("badperm", ',"permissions":["network","warp_drive"]',
  "return function(mod) end\n")
out, code = validate(badPerm)
check(code ~= 0, "an unknown permission fails validate")
check(out:find("MK005", 1, true) ~= nil, "unknown permission reported as MK005")
check(out:find("warp_drive", 1, true) ~= nil, "MK005 names the bad permission")
local mk005 = 0
for _ in out:gmatch("MK005") do mk005 = mk005 + 1 end
check(mk005 == 1, "MK005 is reported once, not echoed again by the loader")

local goodPerm = ruleMod("goodperm",
  ',"permissions":["network","filesystem","engine_internals"]',
  "return function(mod) end\n")
out, code = validate(goodPerm)
check(code == 0, "the known permission set validates clean: " .. out)
check(out:find("MK005", 1, true) == nil, "MK005 spares declared, known permissions")

-- MK006: the require never runs, so only a static scan can see it -- which is
-- why this is not left to the loader's dev-mode tripwire
local reachy = ruleMod("reachy", nil, [[
-- a commented require("src.core.Data") is not a reach past the API
local Semver = require("src.mods.Semver")
local function lazy()
  return require("src.core.Logger")
end
return function(mod)
  local doc = "call require('src.core.Data') at your peril"
  if Semver == nil or lazy == nil or doc == nil then error("unreachable") end
end
]])
out, code = validate(reachy)
check(out:find("MK006", 1, true) ~= nil, "undeclared engine require reported as MK006")
check(out:find("src.core.Logger", 1, true) ~= nil, "MK006 names the module")
check(out:find("main.lua:4", 1, true) ~= nil, "MK006 reports file:line")
check(out:find("src.core.Data", 1, true) == nil,
  "a require in a comment or a string literal does not fire MK006")
check(out:find("src.mods.Semver", 1, true) == nil,
  "a supported require does not fire MK006")
check(code == 0, "MK006 is a warning by default")
out, code = validate(reachy, "--strict")
check(code ~= 0, "--strict makes MK006 fatal")

local declared = ruleMod("declaredreach", ',"permissions":["engine_internals"]',
  [[
local function lazy()
  return require("src.core.Logger")
end
return function(mod)
  if lazy == nil then error("unreachable") end
end
]])
out, code = validate(declared)
check(code == 0, "a declared engine_internals require validates clean: " .. out)
check(out:find("MK006", 1, true) == nil,
  "MK006 spares a require the manifest declares")

-- pack runs validate --strict, so a warn-only mod passes validate and is still
-- refused by the distribution path -- otherwise MK006 and MK3xx have no teeth
-- where they matter most
local warnPkg = root .. "/reachy.modpkg"
out, code = run(("%s tools/modkit.py pack %q -o %q --base fixture")
  :format(python, reachy, warnPkg))
check(code ~= 0, "pack refuses a mod whose only finding is a warning: " .. out)
check(out:find("MK006", 1, true) ~= nil, "pack names the warn-severity rule")
check(io.open(warnPkg, "rb") == nil, "no package written for a warn-only mod")

local cleanPkg = root .. "/declared.modpkg"
out, code = run(("%s tools/modkit.py pack %q -o %q --base fixture")
  :format(python, declared, cleanPkg))
check(code == 0, "a finding-free mod still packs: " .. out)
local packed = io.open(cleanPkg, "rb")
check(packed ~= nil, "pack writes the package")
if packed then packed:close() end

-- MK305 diffs shipped tables against the imported dataset; fake one under
-- a scratch repo root so the check exercises the same on ROM-less machines
local fake = root .. "/fakerepo"
os.execute(("mkdir -p %q %q"):format(
  fake .. "/data/generated", fake .. "/mods/dumper"))
local rows = {}
for index = 1, 12 do
  rows[#rows + 1] = ("  FAKE_%02d = { index = %d, power = %d },")
    :format(index, index, index * 5)
end
local dump = "return {\n" .. table.concat(rows, "\n") .. "\n}\n"
write(fake .. "/data/generated/moves.lua", dump)
write(fake .. "/mods/dumper/manifest.json",
  [[{"id":"dumper","name":"Dumper","version":"1.0.0","api":2,"entry":"main.lua"}]])
write(fake .. "/mods/dumper/main.lua", "return function(mod) end\n")
write(fake .. "/mods/dumper/moves.lua", dump)

out, code = run(("%s tools/modkit.py --repo %q lint %q")
  :format(python, fake, fake .. "/mods/dumper"))
check(code ~= 0, "bulk data-table dump fails lint: " .. out)
check(out:find("MK305", 1, true) ~= nil, "dump reported as MK305")

-- no interpreter means no verdict; the gate fails closed, never open
out, code = run(("MODKIT_LUAJIT=%q %s tools/modkit.py --repo %q lint %q")
  :format(fake .. "/no-such-luajit", python, fake, fake .. "/mods/dumper"))
check(code ~= 0, "lint fails when luajit is missing")
check(out:find("MK100", 1, true) ~= nil, "missing luajit reported as MK100")

-- without an imported dataset the skip is visible, not silent
out, code = run(("%s tools/modkit.py --repo %q lint %q")
  :format(python, root, fake .. "/mods/dumper"))
check(code == 0, "dump check without a dataset stays a warning")
check(out:find("MK305 WARN", 1, true) ~= nil, "skipped dump check is reported")

os.execute(("rm -rf %q"):format(root))

-- ------- restore shared runtime state for the suites that follow

Runtime.events, Runtime.hooks = savedEvents, savedHooks
Runtime.errors = savedErrors
Runtime.wants, Runtime.wantsHook = savedWants, savedWantsHook

S.finish()
