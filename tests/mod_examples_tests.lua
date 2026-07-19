-- The shipped example gallery (25-community-and-ecosystem.md 1): every
-- entry loads clean through the real loader, produces its stated effect,
-- and carries the metadata the polish checklist requires.
--
-- The seven entries load TOGETHER against one dataset, which is the case a
-- player who enables the whole gallery gets and the only way to catch two
-- examples fighting over the same id.
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local Data = require("src.core.Data")
local FsIo = require("tests.fs_io")
local Loader = require("src.mods.Loader")
local Manifest = require("src.mods.Manifest")
local Runtime = require("src.mods.Runtime")

local S = require("tests.harness").suite("example gallery (M15B)")
local check, eq = S.check, S.eq

local GALLERY_ROOT = "mods/examples"
local IDS = {
  "example_balance_tweaks", "example_shiny_palette", "example_jukebox",
  "example_lost_parcel", "example_weather", "example_dexnav",
  "example_mini_conversion",
}

-- the closed vocabulary from 25 3.1; GAMEPLAY is the accepted v1 alias
local CATEGORIES = {
  TWEAK = true, BALANCE = true, CONTENT = true, QUEST = true,
  MECHANIC = true, GRAPHICS = true, AUDIO = true, UI = true, TOOL = true,
  TOTAL_CONVERSION = true, OTHER = true, GAMEPLAY = true,
}

local function exists(path)
  local handle = io.open(path, "rb")
  if handle then handle:close() return true end
  return false
end

-- ------- an imported dataset of this suite's own
-- Data:load() folds into the singleton and require() hands back cached
-- module tables, so a mod merge through either would leak into every other
-- suite in this process.  loadfile skips the cache, which is the same door
-- POKEPORT_DATA_DIR uses.

-- methods only: inheriting the Data singleton wholesale would let a
-- namespace an earlier suite merged into it (Data.balls, Data.commands)
-- show through as this dataset's base, and the engine's own registrations
-- would then collide with themselves
local function dataMethods()
  local methods = {}
  for key, value in pairs(Data) do
    if type(value) == "function" then methods[key] = value end
  end
  return methods
end

-- the namespaces are whatever the importer wrote; discovering them beats
-- restating Data's module list, which would drift the moment one is added
local function freshImported()
  local set = setmetatable({}, { __index = dataMethods() })
  local pipe = io.popen("ls -1 data/generated/*.lua 2>/dev/null")
  if not pipe then return nil end
  local loaded = 0
  for path in pipe:lines() do
    local name = path:match("([^/]+)%.lua$")
    local chunk = name and loadfile(path)
    if chunk then
      set[name] = chunk()
      loaded = loaded + 1
    end
  end
  pipe:close()
  if set.pokemon == nil or set.maps == nil or loaded < 10 then return nil end
  Data.seedDefaults(set)
  return set
end

-- ------- static metadata: true with or without an imported dataset

for _, id in ipairs(IDS) do
  local dir = GALLERY_ROOT .. "/" .. id
  local prefix = id .. ": "

  local manifestBody = io.open(dir .. "/manifest.json", "rb")
  if not check(manifestBody ~= nil, prefix .. "ships a manifest.json") then
    manifestBody = nil
  end
  if manifestBody then
    local body = manifestBody:read("*a")
    manifestBody:close()
    local manifest = require("src.link.Json").decode(body)
    local ok, parsed = pcall(Manifest.validate, manifest, dir)
    check(ok, prefix .. "the manifest validates (" .. tostring(parsed) .. ")")
    if ok then
      eq(parsed.id, id, prefix .. "the manifest id matches the directory")
      eq(parsed.api, 2, prefix .. "is an api 2 mod")
      check(CATEGORIES[parsed.category],
        prefix .. "category " .. tostring(parsed.category) .. " is in the taxonomy")
      check(parsed.game_version ~= nil and parsed.game_version ~= "",
        prefix .. "declares a game_version range")
      check(parsed.description ~= "", prefix .. "the manifest carries a description")
    end
  end

  check(exists(dir .. "/README.md"), prefix .. "ships a README.md")
  check(exists(dir .. "/CHANGELOG.md"), prefix .. "ships a CHANGELOG.md")
  check(exists(dir .. "/tests/" .. id .. "_test.lua"),
    prefix .. "ships its own test suite")

  -- the card is Lua, never read by the merge; it must still parse and meet
  -- the 25 3.2 shape or the manager detail pane has nothing to draw
  local cardChunk = loadfile(dir .. "/mod.card")
  if check(cardChunk ~= nil, prefix .. "ships a parseable mod.card") then
    local okCard, card = pcall(cardChunk)
    if check(okCard and type(card) == "table", prefix .. "mod.card returns a table") then
      check(type(card.summary) == "string" and #card.summary > 0
        and #card.summary <= 100, prefix .. "summary is 1..100 chars")
      check(type(card.author) == "string" and card.author ~= "",
        prefix .. "author is present and non-empty")
      check(type(card.tags) == "table" and #card.tags > 0,
        prefix .. "carries at least one tag")
      for _, tag in ipairs(card.tags or {}) do
        check(tag == tag:lower() and not tag:find("%s"),
          prefix .. "tag " .. tostring(tag) .. " is lowercase kebab")
      end
      check(type(card.differences) == "table"
        and type(card.differences.changed) == "table"
        and type(card.differences.added) == "table"
        and type(card.differences.known) == "table",
        prefix .. "declares a changed/added/known differences ledger")
      check(type(card.credits) == "table" and #card.credits > 0,
        prefix .. "names at least one credit")
      for _, entry in ipairs(card.credits or {}) do
        check(type(entry.who) == "string" and type(entry.for_) == "string",
          prefix .. "every credit says who and what for")
      end
      check(type(card.compat) == "table" and card.compat.modApi == 2,
        prefix .. "compat declares modApi 2")
    end
  end
end

-- the legacy entry keeps its v1 manifest and gains only a card
do
  local cardChunk = loadfile("mods/example_mew_starter/mod.card")
  if check(cardChunk ~= nil, "example_mew_starter: ships a mod.card") then
    local ok, card = pcall(cardChunk)
    check(ok and type(card) == "table", "example_mew_starter: the card parses")
    check(ok and card.compat and card.compat.modApi == 1,
      "example_mew_starter: the card declares api 1, not 2")
  end
  local body = io.open("mods/example_mew_starter/manifest.json", "rb")
  if check(body ~= nil, "example_mew_starter: manifest is readable") then
    local manifest = require("src.link.Json").decode(body:read("*a"))
    body:close()
    check(manifest.api == nil, "example_mew_starter: stays an api 1 manifest")
    eq(manifest.category, "GAMEPLAY",
      "example_mew_starter: keeps the legacy category value")
    local ok = pcall(Manifest.validate, manifest, "mods/example_mew_starter")
    check(ok, "example_mew_starter: the v1 manifest still validates")
  end
end

-- ------- disabled by default
-- Loader:_discover walks one level below "mods".  The gallery sits a level
-- deeper, so a fresh install discovers none of it and the merged data of a
-- mod-free boot is unchanged -- the parity invariant, held by construction.

do
  local fs = FsIo.new(".")
  local top = {}
  for _, name in ipairs(fs.getDirectoryItems("mods")) do
    if fs.getInfo("mods/" .. name .. "/manifest.json") then top[name] = true end
  end
  for _, id in ipairs(IDS) do
    check(not top[id], id .. " is not discoverable at the mods/ root")
  end
  check(top.example_mew_starter,
    "the legacy example is still discovered at the mods/ root")
end

-- ------- the gallery loads

local data = freshImported()
if not data then
  print("modkit: example gallery load skipped -- no imported dataset in "
    .. "data/generated/ to fold the examples against")
  return S.finish()
end

-- The transform in example_shiny_palette reads the imported cache and
-- writes under save/mod-derived/.  The io-backed harness filesystem has no
-- createDirectory, so this run exercises the no-cache path instead: the
-- transform must degrade to writing nothing, not fail the mod.
local function galleryFs(ids)
  local inner = FsIo.new(".")
  local overlay = {}
  local hidden = "assets/generated/"

  local function map(path)
    if path == nil then return path end
    for _, id in ipairs(ids) do
      local mount = "mods/" .. id
      if path == mount then return GALLERY_ROOT .. "/" .. id end
      if path:sub(1, #mount + 1) == mount .. "/" then
        return GALLERY_ROOT .. "/" .. id .. path:sub(#mount + 1)
      end
    end
    return path
  end

  local fs = { root = inner.root }
  function fs.read(path)
    if path:sub(1, #hidden) == hidden then return nil end
    return overlay[path] or inner.read(map(path))
  end
  function fs.write(path, body) overlay[path] = body return true end
  function fs.createDirectory() return true end
  function fs.load(path) return inner.load(map(path)) end
  function fs.getInfo(path)
    if path == "mods" then return { type = "directory" } end
    if path:sub(1, #hidden) == hidden then return nil end
    if overlay[path] then return { type = "file" } end
    return inner.getInfo(map(path))
  end
  function fs.getDirectoryItems(path)
    if path == "mods" then
      local names = {}
      for i, id in ipairs(ids) do names[i] = id end
      table.sort(names)
      return names
    end
    return inner.getDirectoryItems(map(path))
  end
  return fs
end

local saved = { events = Runtime.events, hooks = Runtime.hooks,
                errors = Runtime.errors }
local loader = Loader.new({ fs = galleryFs(IDS) })
local ok, err = pcall(loader.load, loader, data)
check(ok, "the whole gallery loads without raising (" .. tostring(err) .. ")")

for _, message in ipairs(loader.errors) do
  check(false, "loader error: " .. tostring(message))
end
eq(#loader.errors, 0, "the gallery loads with zero loader errors")

local status = loader:status()
eq(#status.loaded, #IDS, "every gallery entry reached the loaded state")
for _, id in ipairs(IDS) do
  local mod = loader.mods[id]
  check(mod ~= nil, id .. " was discovered")
  eq(mod and mod.state, "loaded", id .. " reached the loaded state")
end

-- ------- each entry's stated effect landed in the merged data

-- #1 tweaker: patch and each
eq(data.pokemon.VENUSAUR.baseStats.speed, 100, "#1 patched VENUSAUR speed")
check(#data.pokemon.VENUSAUR.learnset > 0, "#1 patch left the learnset alone")
eq(data.items.TM_TOXIC.price, 2000, "#1 halved a TM price through each()")
eq(data.items.POTION.price, 300, "#1 left non-TM prices alone")
eq(data.encounters.ROUTE_1.grass.rate, 20, "#1 re-slotted Route 1")

-- #2 artist: palette records and the trueColor opt-out
check(data.palettes.palettes.EXAMPLE_SHINY ~= nil, "#2 registered a palette record")
eq(#data.palettes.palettes.PALLET, 4, "#2 overrode PALLET with four colors")
eq(data.sprites.SPRITE_RED.trueColor, true, "#2 opted SPRITE_RED into trueColor")
check(data.sprites.SPRITE_RED.image ~= nil,
  "#2 patched only the flag; the sheet path survived")

-- #3 musician: an authored program, a cry and a hook
local song = data.audio.songs.Music_ExamplePalletRain
check(type(song) == "table" and type(song.chip) == "table",
  "#3 registered an authored chip song")
check(#song.chip.blob > 0, "#3 the song assembled to a non-empty blob")
check(type(data.audio.cries.MEW) == "table" and data.audio.cries.MEW.chip,
  "#3 replaced the MEW cry with a chip program")
eq(Runtime.call("music.select", function(chosen) return chosen end,
  "Music_PalletTown", { reason = "map", mapId = "PALLET_TOWN" }),
  "Music_ExamplePalletRain", "#3 music.select swaps the Pallet Town theme")
eq(Runtime.call("music.select", function(chosen) return chosen end,
  "Music_Routes1", { reason = "map", mapId = "ROUTE_1" }),
  "Music_Routes1", "#3 every other map defers to the vanilla choice")

-- #4 quest author: compose semantics, a verb, a token, an item
check(data.items.EXAMPLE_LOST_PARCEL_PARCEL ~= nil, "#4 registered the parcel item")
check(data.tokens.EXAMPLE_PARCEL_REWARD ~= nil, "#4 registered its text token")
check(data.commands["example_lost_parcel:count_ask"] ~= nil, "#4 registered its verb")
check(data.commands.show_text ~= nil, "#4 the engine's own verbs are untouched")
local viridian = data.map_scripts and data.map_scripts.VIRIDIAN_CITY
check(viridian and #viridian > 0, "#4 composed into the VIRIDIAN_CITY chain")
check(viridian and viridian[1].talk
  and viridian[1].talk.TEXT_VIRIDIANCITY_GAMBLER1 ~= nil,
  "#4 the talk contribution addresses a real TEXT constant")
-- talk dispatch is single-winner, so the branches the quest does not own
-- have to replay the base handler rather than re-resolve its TEXT constant
check(data.commands["example_lost_parcel:base_nerd_chat"] ~= nil,
  "#4 registered the verb that replays the overridden base conversation")
local pewterTalk = data.map_scripts and data.map_scripts.PEWTER_CITY
  and data.map_scripts.PEWTER_CITY[1].talk.TEXT_PEWTERCITY_SUPER_NERD1
local fallback = pewterTalk and pewterTalk[#pewterTalk]
eq(fallback and fallback[1], "example_lost_parcel:base_nerd_chat",
  "#4 the vanilla branch ends in that verb, not a truncating show_text")

-- #5 mechanic designer: a ruleset, a status and a gated damage hook
local weather = data.rulesets.example_weather_battles
check(weather ~= nil, "#5 registered a selectable ruleset")
eq(weather.randMax, data.rulesets.gen1_faithful.randMax,
  "#5 the derived ruleset kept the vanilla rules")
check(data.statuses.EXAMPLE_RAIN ~= nil, "#5 registered the rain status record")
local function damage(ruleset, moveType)
  return Runtime.call("battle.damage", function() return 100, { crit = false } end,
    { ruleset = ruleset, move = { type = moveType } })
end
Runtime.emit("battle.started", { battle = { ruleset = data.rulesets.gen1_faithful } })
eq(damage(data.rulesets.gen1_faithful, "WATER"), 100,
  "#5 gen1_faithful is unchanged with the mod installed")
Runtime.emit("battle.started", { battle = { ruleset = weather } })
eq(damage(weather, "WATER"), 150, "#5 rain boosts WATER under its own ruleset")
eq(damage(weather, "FIRE"), 50, "#5 rain dampens FIRE under its own ruleset")
Runtime.emit("battle.ended", {})

-- #6 tool builder: exports, options and the start-menu wrap
local exports = loader.exports.example_dexnav
check(type(exports.countSeen) == "function", "#6 published a countSeen export")
eq(loader.optionSchemas.example_dexnav and #loader.optionSchemas.example_dexnav, 2,
  "#6 defined two option rows")
local menu = Runtime.call("ui.start_menu.items", function(_, items) return items end,
  { data = data }, { { label = "POKéDEX" }, { label = "SAVE" } })
eq(#menu, 3, "#6 added exactly one start-menu row")
eq(menu[2].label, "DEXNAV", "#6 anchored the row before SAVE")

-- #7 total conversion: boot, constants, species, map
eq(data.field.boot.startMap, "SABLE_COVE", "#7 owns the boot spawn")
eq(data.field.boot.startFacing, "down", "#7 patch left unnamed boot keys alone")
eq(data.constants.dexSize, 3, "#7 shrank the dex")
eq(#data.constants.badges, 1, "#7 override replaced the badge list")
eq(data.constants.partyMax, 6, "#7 left unpatched constants alone")
check(data.pokemon.SABLE_EMBERKIT ~= nil, "#7 registered its own species")
check(data.audio.cries.SABLE_EMBERKIT ~= nil, "#7 gave it a cry")
check(data.icons.bySpecies.SABLE_EMBERKIT ~= nil, "#7 gave it an icon")
check(data.maps.SABLE_COVE ~= nil, "#7 registered its map")
eq(#data.maps.SABLE_COVE.blocks,
  data.maps.SABLE_COVE.width * data.maps.SABLE_COVE.height,
  "#7 the map's block array matches its size")

-- co-existence: the gallery does not fight over ids
check(data.pokemon.MEW ~= nil, "vanilla species survive the whole gallery")
check(data.maps.PALLET_TOWN ~= nil, "vanilla maps survive the whole gallery")

Runtime.events, Runtime.hooks, Runtime.errors =
  saved.events, saved.hooks, saved.errors
Runtime.currentMod = nil

S.finish()
