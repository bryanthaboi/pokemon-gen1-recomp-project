-- Editor mod-awareness (15 testing): with a mod enabled, App.load merges
-- the mod set into Data before the catalogs build, so the species list
-- carries the mod's mon, the flag list carries its MOD_ flags scraped
-- from the mod root, and MonOps stops asserting on the modded species.
-- Runs in its own process (run_tests spawns it): App.load's loader must
-- be the first to merge vanilla records over the singleton Data, or the
-- engine's registrations collide with an earlier loader's merge.
-- Self-contained: own bootstrap, assert-based checks, error() on failure.
package.path = "./?.lua;./?/init.lua;./tools/save-editor/?.lua;"
  .. "./tools/save-editor/panels/?.lua;" .. package.path
love = love or require("tests.love_stub")

local Runtime = require("src.mods.Runtime")
local Assets = require("src.render.Assets")
local SaveData = require("src.core.SaveData")
local Data = require("src.core.Data")

local function check(value, message)
  assert(value, message)
end

-- the fs surface the editor's loader needs, backed by a flat table
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
      return (loadstring or load)(files[path], path)
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

local MOD_ROOT = "mods/zz_editor_fixture"

local MOD_MAIN = [[
return function(mod)
  local giftFlag = "MOD_EDITMON_GIFT"
  mod.exports.giftFlag = giftFlag
  mod.content.pokemon:register("EDITMON", {
    id = "EDITMON", name = "EDITMON", dex = 152,
    types = { "NORMAL" },
    baseStats = { hp = 50, attack = 50, defense = 50, speed = 50, special = 50 },
    catchRate = 45, baseExp = 100,
    level1Moves = { "GROWL" },
    growthRate = "MEDIUM_FAST",
    learnset = { { level = 10, move = "TACKLE" } },
    evolutions = {},
    spriteFront = "editmon_front.png", spriteBack = "editmon_back.png",
    frontSize = 5,
  })
end
]]

-- the loader discovers the fixture through love.filesystem, while the
-- flag scrape lists the mod root with io; the disk copy carries no
-- manifest, so a crash that strands it leaves a directory the game ignores
local savedFS = love.filesystem
local savedEvents, savedHooks, savedErrors =
  Runtime.events, Runtime.hooks, Runtime.errors
local savedBridge = Assets.loader

love.filesystem = memfs({
  [MOD_ROOT .. "/manifest.json"] =
    '{"id":"zz_editor_fixture","name":"zz_editor_fixture","version":"1.0.0",'
    .. '"entry":"main.lua","dependencies":[],"api":2}',
  [MOD_ROOT .. "/main.lua"] = MOD_MAIN,
})
os.execute('mkdir -p "' .. MOD_ROOT .. '"')
local diskMain = assert(io.open(MOD_ROOT .. "/main.lua", "w"))
diskMain:write(MOD_MAIN)
diskMain:close()

local tmpPath = os.tmpname() .. "-editor-modaware.lua"
os.remove(tmpPath)

local ok, err = pcall(function()
  local App = require("App")
  local MonOps = require("MonOps")
  local Growth = require("src.pokemon.Growth")

  App.load(tmpPath)
  local S = App.getState()

  local loaded = S.mods:status().loaded
  check(#loaded == 1 and loaded[1].id == "zz_editor_fixture",
    "fixture mod loads through the editor's loader")
  check(loaded[1].path == MOD_ROOT, "loaded mod reports its root path")

  local hasSpecies = false
  for _, id in ipairs(S.cat.species) do
    if id == "EDITMON" then hasSpecies = true end
  end
  check(hasSpecies, "editor species catalog carries the mod's mon")

  local hasModFlag, hasVanillaFlag = false, false
  for _, name in ipairs(S.events) do
    if name == "MOD_EDITMON_GIFT" then hasModFlag = true end
    if name:match("^EVENT_") then hasVanillaFlag = true end
  end
  check(hasModFlag, "editor flag list carries the mod's MOD_ flag")
  check(hasVanillaFlag, "vanilla EVENT_ flags still scraped beside the mod's")

  -- MonOps reads the same merged Data the catalog was built from
  check(Data.pokemon.EDITMON ~= nil, "merge landed in the Data table MonOps reads")
  local mon = MonOps.create(Data, "PIDGEY", 10)
  MonOps.setSpecies(Data, mon, "EDITMON")
  check(mon.species == "EDITMON", "MonOps.setSpecies accepts the modded species")
  check(mon.exp == Growth.expForLevel("MEDIUM_FAST", 10),
    "setSpecies resyncs exp against the mod's growth curve")
  check(mon.stats.hp > 0, "recalc computes stats from the mod's base stats")
  MonOps.recalc(Data, mon)

  -- and the game-side scrub agrees: a save holding the modded mon passes
  -- clean instead of quarantining it
  local probe = { player = { map = "PALLET_TOWN" },
                  party = { { species = "EDITMON", level = 10,
                              moves = { { id = "TACKLE", pp = 10 } } } } }
  local report = SaveData.validate(probe, Data)
  check(#report.lostMons == 0 and probe.party[1].species == "EDITMON",
    "validate keeps the modded mon while the mod is enabled")
end)

os.remove(MOD_ROOT .. "/main.lua")
os.execute('rmdir "' .. MOD_ROOT .. '" 2>/dev/null')
os.remove(tmpPath)
love.filesystem = savedFS
-- leave shared singletons the way we found them (the fixture merged one
-- record into Data.pokemon)
Data.pokemon.EDITMON = nil
Assets.loader = savedBridge
Assets.invalidate()
Runtime.install(savedEvents, savedHooks, savedErrors)
if not ok then error(err, 0) end

print("ok   save editor mod awareness")
