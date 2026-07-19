-- The constants & field deep registries: engine-seeded vanilla defaults,
-- per-key deep merge (siblings survive, lists extend, override replaces),
-- schema and cross-reference enforcement, and the field.boot config read
-- at new-game time.
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local Data = require("src.core.Data")
local Loader = require("src.mods.Loader")
local Merge = require("src.mods.Merge")
local Schemas = require("src.mods.Schemas")
local SaveData = require("src.core.SaveData")
local Badges = require("src.inventory.Badges")

local S = require("tests.harness").suite("mod constants")
local check = S.check

Data:load()

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

local function manifestJson(id)
  return ([[{"id":"%s","name":"%s","version":"1.0.0","entry":"main.lua","api":2}]])
    :format(id, id)
end

-- a private copy of the real tables: these tests merge into their data, and
-- the suites that run after this one read the live Data
local function fixture()
  return {
    constants = Merge.deepCopy(Data.constants),
    field = Merge.deepCopy(Data.field),
    items = Merge.deepCopy(Data.items),
    moves = Merge.deepCopy(Data.moves),
    tilesets = Merge.deepCopy(Data.tilesets),
  }
end

local function deepEqual(a, b, path)
  path = path or "root"
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false, path end
  for k, v in pairs(a) do
    local ok, where = deepEqual(v, b[k], path .. "." .. tostring(k))
    if not ok then return false, where end
  end
  for k in pairs(b) do
    if a[k] == nil then return false, path .. "." .. tostring(k) end
  end
  return true
end

-- run one inline mod against a fresh fixture; returns the merged data
local function withMod(id, source)
  local loader = Loader.new({ fs = memfs({
    ["mods/" .. id .. "/manifest.json"] = manifestJson(id),
    ["mods/" .. id .. "/main.lua"] = source,
  }) })
  local data = fixture()
  local ok = loader:load(data)
  return data, loader, ok
end

-- ------- engine-seeded vanilla defaults

check(Data.constants.bagSize == 20, "bagSize seeded from BAG_ITEM_CAPACITY")
check(Data.constants.partyMax == 6, "partyMax seeded")
check(Data.constants.boxCount == 12 and Data.constants.boxSize == 20,
  "box geometry seeded")
check(Data.constants.moveMax == 4, "moveMax seeded")
check(Data.constants.levelCap == 100, "levelCap seeded")
check(Data.constants.coinCap == 9999, "coinCap seeded")
check(Data.constants.dexSize == 151, "dexSize derived from the merged roster")
check(Data.constants.dexDigits == 3, "dexDigits derived from dexSize")
check(#Data.constants.badges == 8
  and Data.constants.badges[1].id == "BOULDERBADGE"
  and Data.constants.badges[8].id == "EARTHBADGE",
  "the eight Kanto badges seeded in gym order")
check(#Data.constants.hmMoves == 5 and Data.constants.hmMoves[1] == "CUT",
  "hmMoves seeded")

local boot = Data.field.boot
check(boot.startMap == "PALLET_TOWN" and boot.startX == 5 and boot.startY == 6
  and boot.startFacing == "down", "field.boot seeded with the Pallet spawn")
check(boot.playerName == "RED" and boot.rivalName == "BLUE"
  and boot.startMoney == 3000, "field.boot seeded with the Red new-game values")
check(boot.namePresets.player[1] == "RED" and boot.namePresets.rival[1] == "BLUE",
  "field.boot name presets seeded from the extracted preset names")
check(boot.screens.title == "TitleState", "field.boot boot-screen chain seeded")
-- the presets are copied, not aliased, so a boot patch cannot rewrite the
-- table the naming screen data came from
check(boot.namePresets.player ~= Data.field.presetNames.player,
  "seeded presets are a copy of field.presetNames")

-- every seeded and imported key satisfies the catalog schema, so a mod
-- that copies a vanilla value back in always validates
for _, pair in ipairs({ { "constants", Data.constants }, { "field", Data.field } }) do
  local name, table_ = pair[1], pair[2]
  local spec = Schemas.REGISTRIES[name]
  for id, value in pairs(table_) do
    local ok, err = Schemas.check(spec, name, id, value, "override")
    check(ok, "vanilla " .. name .. " key validates: " .. tostring(err))
  end
end

-- ------- parity: with no mod, neither table moves

local parityData = fixture()
local snapshot = Merge.deepCopy(parityData)
local emptyLoader = Loader.new({ fs = memfs({}) })
check(emptyLoader:load(parityData) == true, "empty load succeeds")
-- the engine's own registrations own the namespaces they create; the deep
-- tables this suite is about must not move
local engineRoots = require("src.mods.Builtins").namespaceRoots()
local carried = {}
for key, value in pairs(parityData) do
  if snapshot[key] ~= nil then carried[key] = value
  else check(engineRoots[key], "only engine namespaces appear (saw " .. key .. ")") end
end
local same, where = deepEqual(carried, snapshot)
check(same, "no-mod merge leaves constants and field identical (differs at "
  .. tostring(where) .. ")")

-- ------- deep merge of one constant leaves every sibling intact

local capData, capLoader = withMod("rebalance", [[
return function(mod)
  mod.content.constants:patch("levelCap", 80)
end
]])
check(#capLoader.errors == 0, "constants patch loads cleanly: "
  .. table.concat(capLoader.errors, "; "))
check(capData.constants.levelCap == 80, "scalar constant patched")
check(capData.constants.bagSize == 20 and capData.constants.partyMax == 6
  and capData.constants.boxCount == 12 and capData.constants.moveMax == 4
  and capData.constants.coinCap == 9999 and capData.constants.dexSize == 151,
  "sibling constants intact after a single-key patch")
check(#capData.constants.badges == 8 and #capData.constants.hmMoves == 5,
  "sibling list constants intact after a single-key patch")
check(capData.constants.speciesOrder ~= nil and capData.constants.moveOrder ~= nil,
  "imported constants the catalog does not describe survive the merge")
check(Data.constants.levelCap == 100, "the merge never touched the live Data")

-- register is a synonym of patch on a deep registry
local regData = withMod("register_form", [[
return function(mod)
  mod.content.constants:register("levelCap", 55)
end
]])
check(regData.constants.levelCap == 55,
  "register merges instead of colliding on a deep key")

-- ------- dexSize drives the dex upper bound

local dexData, dexLoader = withMod("big_dex", [[
return function(mod)
  mod.content.constants:patch("dexSize", 200)
end
]])
check(#dexLoader.errors == 0, "dexSize patch loads cleanly")
check(dexData.constants.dexSize == 200, "dexSize patched")
check(dexData.constants.dexDigits == 3,
  "dexDigits is a separate constant a mod may leave alone")
check(dexData.constants.badges ~= nil and #dexData.constants.badges == 8,
  "dexSize patch touched no other constant")

-- the dex list itself: bound and number width come from the constants, so
-- a species numbered past the vanilla roster is reachable
local function dexList(constants, dex)
  return require("src.ui.PokedexMenu").new({
    data = { constants = constants,
      pokemon = { NEWMON = { id = "NEWMON", name = "NEWMON", dex = dex } } },
    save = { pokedex = { seen = { NEWMON = true }, owned = {} } },
    stack = { push = function() end },
  }).items
end
check(#dexList({ dexSize = 151, dexDigits = 3 }, 152) == 0,
  "a species past dexSize is out of the list's range")
local widened = dexList({ dexSize = 200, dexDigits = 3 }, 152)
check(#widened == 1 and widened[1].label == "152 NEWMON",
  "raising dexSize brings the species into the list")
local padded = dexList({ dexSize = 1000, dexDigits = 4 }, 152)
check(padded[1].label == "0152 NEWMON",
  "dexDigits widens every dex number at once")
check(dexList({}, 151)[1].label == "151 NEWMON",
  "an absent constant falls back to the Kanto bound and width")

-- ------- badge list: lists accumulate, only override replaces

local ninth = [[
    mod.content.items:register("NINTH_BADGE",
      { id = "NINTH_BADGE", name = "NINTH BADGE", price = 0 })
]]

local appendData, appendLoader = withMod("ninth_gym", [[
return function(mod)
]] .. ninth .. [[
  mod.content.constants:patch("badges", { __append = { { id = "NINTH_BADGE" } } })
end
]])
check(#appendLoader.errors == 0, "badge append loads cleanly: "
  .. table.concat(appendLoader.errors, "; "))
local appended = appendData.constants.badges
check(#appended == 9, "the __append wrapper extends the badge list")
check(appended[1].id == "BOULDERBADGE" and appended[8].id == "EARTHBADGE",
  "Kanto's eight badges survive the append")
check(appended[9].id == "NINTH_BADGE", "the new badge lands last")
check(appended.__append == nil, "the extension wrapper never survives into Data")

local prependData = withMod("zeroth_gym", [[
return function(mod)
]] .. ninth .. [[
  mod.content.constants:patch("badges", { __prepend = { { id = "NINTH_BADGE" } } })
end
]])
check(prependData.constants.badges[1].id == "NINTH_BADGE"
  and #prependData.constants.badges == 9,
  "the __prepend wrapper extends the front of the list")

-- a bare list is the same append: the wrapper is only needed where the
-- payload also carries dictionary keys, or to reach the front of the list
local bareData = withMod("two_gyms", [[
return function(mod)
]] .. ninth .. [[
  mod.content.constants:patch("badges", { { id = "NINTH_BADGE" } })
end
]])
check(#bareData.constants.badges == 9
  and bareData.constants.badges[1].id == "BOULDERBADGE"
  and bareData.constants.badges[9].id == "NINTH_BADGE",
  "a bare list appends on a deep registry instead of erasing Kanto")

local overrideData = withMod("one_gym", [[
return function(mod)
  mod.content.constants:override("badges", { { id = "EARTHBADGE" } })
end
]])
check(#overrideData.constants.badges == 1,
  "override replaces the badge list, the total-conversion path")

-- the badge consumers read the merged list, not their own copy
check(#Badges.list(appendData) == 9, "Badges.list reads constants.badges")
check(#Badges.list({}) == 8, "Badges.list falls back to the gym order")
local badgeSave = { inventory = { BOULDERBADGE = 1, NINTH_BADGE = 1 } }
check(Badges.count(appendData, badgeSave) == 2,
  "Badges.count counts a mod-added badge")
check(Badges.count({}, badgeSave) == 1,
  "the fallback list counts only the badges it knows")

-- ------- field: per-map dictionaries and lists merge per key

local worldData, worldLoader = withMod("sable_cove", [[
return function(mod)
  mod.content.field:patch("hiddenItems", {
    SABLE_COVE = { { x = 3, y = 9, item = "NUGGET" } },
  })
  mod.content.field:patch("flyOrder", { __append = { "SABLE_COVE" } })
  mod.content.field:patch("townMap", {
    locations = { SABLE_COVE = { x = 4, y = 17, name = "SABLE COVE" } },
  })
end
]])
check(#worldLoader.errors == 0, "field patches load cleanly: "
  .. table.concat(worldLoader.errors, "; "))
check(worldData.field.hiddenItems.SABLE_COVE[1].item == "NUGGET",
  "a new map's hidden items merge in")
check(worldData.field.hiddenItems.CERULEAN_CAVE_1F ~= nil,
  "Kanto's hidden items survive the map-dict merge")
check(#worldData.field.flyOrder == #Data.field.flyOrder + 1
  and worldData.field.flyOrder[#worldData.field.flyOrder] == "SABLE_COVE",
  "flyOrder appends without disturbing the vanilla order")
check(worldData.field.townMap.locations.SABLE_COVE.name == "SABLE COVE"
  and worldData.field.townMap.locations.PALLET_TOWN ~= nil,
  "town-map locations merge per map")
check(worldData.field.townMap.gridPixelSize == Data.field.townMap.gridPixelSize,
  "unpatched town-map keys keep their imported values")
check(#worldData.field.ledges == #Data.field.ledges,
  "sibling field keys are untouched by a patch elsewhere")

-- ------- field.boot changes the new game

local vanillaSave = SaveData.newGame(Data.field.boot)
check(vanillaSave.player.map == "PALLET_TOWN" and vanillaSave.player.x == 5
  and vanillaSave.player.y == 6 and vanillaSave.player.facing == "down",
  "the seeded boot config reproduces the Pallet spawn")
check(vanillaSave.player.name == "RED" and vanillaSave.player.rival == "BLUE"
  and vanillaSave.money == 3000, "the seeded boot config reproduces the Red start")
check(vanillaSave.lastHeal.map == "PALLET_TOWN" and vanillaSave.lastHeal.x == 5
  and vanillaSave.lastHeal.y == 6, "heal point defaults to the spawn")
-- an absent config is still the vanilla new game
local bareSave = SaveData.newGame()
check(bareSave.player.map == "PALLET_TOWN" and bareSave.money == 3000
  and bareSave.lastHeal.map == "PALLET_TOWN",
  "newGame without a boot config is unchanged")

local bootData, bootLoader = withMod("total_conversion", [[
return function(mod)
  mod.content.field:patch("boot", {
    startMap = "SABLE_COVE", startX = 3, startY = 4, startFacing = "up",
    playerName = "ALEX", startMoney = 0,
    namePresets = { player = { "ALEX", "SAM" } },
  })
end
]])
check(#bootLoader.errors == 0, "field.boot patch loads cleanly: "
  .. table.concat(bootLoader.errors, "; "))
local tcSave = SaveData.newGame(bootData.field.boot)
check(tcSave.player.map == "SABLE_COVE" and tcSave.player.x == 3
  and tcSave.player.y == 4 and tcSave.player.facing == "up",
  "field.boot override moves the new-game spawn")
check(tcSave.player.name == "ALEX", "field.boot override renames the player")
check(tcSave.player.rival == "BLUE", "an unpatched boot key keeps its vanilla value")
check(tcSave.money == 0, "a zero startMoney is honored, not treated as absent")
check(tcSave.lastHeal.map == "SABLE_COVE" and tcSave.lastHeal.x == 3
  and tcSave.lastHeal.y == 4, "the heal point follows the new spawn")
local seededPresets = #Data.field.boot.namePresets.player
check(#bootData.field.boot.namePresets.player == seededPresets + 2
  and bootData.field.boot.namePresets.player[seededPresets + 1] == "ALEX"
  and bootData.field.boot.namePresets.rival[1] == "BLUE",
  "a patched preset list extends its own side and leaves the other alone")
check(bootData.field.boot.screens.title == "TitleState",
  "the boot-screen chain survives a spawn patch")
check(bootData.field.hiddenItems.CERULEAN_CAVE_1F ~= nil
  and #bootData.field.flyOrder == #Data.field.flyOrder,
  "sibling field keys are intact after a boot patch")
check(Data.field.boot.startMap == "PALLET_TOWN",
  "the boot merge never touched the live Data")

-- the save table is a copy: writing to it cannot reach back into Data
tcSave.lastHeal.map = "ELSEWHERE"
check(bootData.field.boot.startMap == "SABLE_COVE",
  "the new-game save never aliases the boot config")

-- ------- validation and cross-references

local badTypeData, badTypeLoader, badTypeOk = withMod("bad_constant", [[
return function(mod)
  mod.content.constants:patch("partyMax", "six")
end
]])
check(badTypeOk == false, "a mistyped constant fails an api 2 mod")
local badTypeError = table.concat(badTypeLoader.errors, "\n")
check(badTypeError:find("constants.partyMax", 1, true) ~= nil,
  "the schema error names the constant")
check(badTypeData.constants.partyMax == 6,
  "the rejected patch leaves the constant untouched")

local badRowLoader = select(2, withMod("bad_badge_row", [[
return function(mod)
  mod.content.constants:patch("badges", { { name = "NO ID" } })
end
]]))
check(#badRowLoader.errors > 0, "a badge row without an id fails")
check(table.concat(badRowLoader.errors, "\n"):find("badges", 1, true) ~= nil,
  "the badge row error names the key")

local danglingLoader = select(2, withMod("phantom_badge", [[
return function(mod)
  mod.content.constants:patch("badges", { { id = "PHANTOM_BADGE" } })
end
]]))
check(#danglingLoader.errors > 0, "a badge with no item record fails")
check(table.concat(danglingLoader.errors, "\n"):find("PHANTOM_BADGE", 1, true) ~= nil,
  "the cross-reference error names the missing item")

-- a key the catalog does not describe is a mod's own data, not an error
local stashData, stashLoader = withMod("stash", [[
return function(mod)
  mod.content.field:patch("questBoard", { chapters = { "one", "two" } })
end
]])
check(#stashLoader.errors == 0, "an undescribed field key is accepted")
check(stashData.field.questBoard.chapters[2] == "two",
  "the mod's own field data merges through")

-- ------- removal

local removeData, removeLoader = withMod("no_ledges", [[
return function(mod)
  mod.content.field:remove("ledges")
end
]])
check(#removeLoader.errors == 0, "removing a field key loads cleanly")
check(removeData.field.ledges == nil, "remove tombstones the top-level key")
check(removeData.field.hiddenItems ~= nil, "sibling keys survive the removal")

S.finish()
