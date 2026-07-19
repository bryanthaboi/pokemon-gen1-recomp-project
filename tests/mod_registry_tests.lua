-- Registry & merge v2 over the headless loader: patch/remove/each
-- semantics, the tombstone delete pass, schema validation (api 2 errors,
-- api 1 warns), namespace creation for base-less registries, v1 alias
-- deprecation, and the structural-identity parity gate with no mod.
package.path = "./?.lua;./?/init.lua;" .. package.path

local Loader = require("src.mods.Loader")
local Registry = require("src.mods.Registry")
local Merge = require("src.mods.Merge")
local Schemas = require("src.mods.Schemas")
local Logger = require("src.core.Logger")

local S = require("tests.harness").suite("registry merge v2")
local check = S.check

local function loggedCount(fragmentA, fragmentB)
  local count = 0
  for _, line in ipairs(Logger.history) do
    if line:find(fragmentA, 1, true) and line:find(fragmentB, 1, true) then
      count = count + 1
    end
  end
  return count
end

local function logged(fragmentA, fragmentB)
  return loggedCount(fragmentA, fragmentB) > 0
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

local function manifestJson(id, opts)
  opts = opts or {}
  return ([[{"id":"%s","name":"%s","version":"1.0.0","entry":"main.lua","dependencies":%s%s}]])
    :format(id, id, opts.deps or "[]", opts.api and (',"api":' .. opts.api) or "")
end

-- internally consistent so the cross-reference pass finds every id
local function fixtureData()
  return {
    pokemon = {
      PIKACHU = { id = "PIKACHU", name = "PIKACHU", dex = 25,
        types = { "ELECTRIC" },
        baseStats = { hp = 35, attack = 55, defense = 30, speed = 90, special = 50 },
        catchRate = 190, baseExp = 82,
        level1Moves = { "THUNDERSHOCK", "GROWL" },
        growthRate = "MEDIUM_FAST",
        learnset = { { level = 9, move = "THUNDER_WAVE" } },
        evolutions = { { method = "ITEM", item = "THUNDER_STONE", species = "RAICHU" } },
        spriteFront = "pikachu_front.png", spriteBack = "pikachu_back.png",
        frontSize = 5 },
      RAICHU = { id = "RAICHU", name = "RAICHU", dex = 26,
        types = { "ELECTRIC" },
        baseStats = { hp = 60, attack = 90, defense = 55, speed = 110, special = 90 },
        catchRate = 75, baseExp = 122,
        level1Moves = { "THUNDERSHOCK" },
        growthRate = "MEDIUM_FAST",
        learnset = {}, evolutions = {},
        spriteFront = "raichu_front.png", spriteBack = "raichu_back.png",
        frontSize = 6 },
    },
    moves = {
      THUNDERSHOCK = { id = "THUNDERSHOCK", name = "THUNDERSHOCK", type = "ELECTRIC",
        power = 40, accuracy = 100, pp = 30, effect = "PARALYZE_SIDE_EFFECT1" },
      GROWL = { id = "GROWL", name = "GROWL", type = "NORMAL",
        power = 0, accuracy = 100, pp = 40, effect = "ATTACK_DOWN1_EFFECT" },
      THUNDER_WAVE = { id = "THUNDER_WAVE", name = "THUNDER WAVE", type = "ELECTRIC",
        power = 0, accuracy = 100, pp = 20, effect = "PARALYZE_EFFECT" },
    },
    items = {
      POTION = { id = "POTION", name = "POTION", price = 300 },
      THUNDER_STONE = { id = "THUNDER_STONE", name = "THUNDER STONE", price = 2100 },
    },
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

-- ------- parity: with no mod, Data is structurally identical after load
local pristine = fixtureData()
local snapshot = Merge.deepCopy(pristine)
local emptyLoader = Loader.new({ fs = memfs({}) })
check(emptyLoader:load(pristine) == true, "empty load succeeds")
-- the engine seeds its own registries on every boot, so the namespaces
-- those write are expected; every pre-existing table must be untouched
local engineRoots = require("src.mods.Builtins").namespaceRoots()
local carried = {}
for key, value in pairs(pristine) do
  if snapshot[key] ~= nil then
    carried[key] = value
  else
    check(engineRoots[key], "no-mod merge creates only engine namespaces (saw "
      .. key .. ")")
  end
end
local same, where = deepEqual(carried, snapshot)
check(same, "no-mod merge keeps Data structurally identical (differs at " ..
  tostring(where) .. ")")

-- ------- patch: field-precise, stacking in load order, DELETE sentinel
local patchFiles = {
  ["mods/tweak_a/manifest.json"] = manifestJson("tweak_a", { api = 2 }),
  ["mods/tweak_a/main.lua"] = [[
return function(mod)
  mod.content.pokemon:patch("PIKACHU", { baseStats = { attack = 120 } })
end
]],
  ["mods/tweak_b/manifest.json"] = manifestJson("tweak_b", { api = 2, deps = '["tweak_a"]' }),
  ["mods/tweak_b/main.lua"] = [[
return function(mod)
  mod.content.pokemon:patch("PIKACHU", {
    catchRate = 45,
    level1Moves = { "GROWL" },
    evolutions = mod.DELETE,
  })
end
]],
}
local patchData = fixtureData()
local patchLoader = Loader.new({ fs = memfs(patchFiles) })
check(patchLoader:load(patchData) == true, "patch mods load cleanly")
local pika = patchData.pokemon.PIKACHU
check(pika.baseStats.attack == 120, "patched field applied")
check(pika.baseStats.hp == 35 and pika.baseStats.speed == 90,
  "sibling stats intact after patch")
check(pika.catchRate == 45, "later mod's patch stacks on the earlier one")
check(pika.name == "PIKACHU" and pika.spriteFront == "pikachu_front.png",
  "unrelated fields intact after patch")
check(pika.learnset[1].move == "THUNDER_WAVE", "nested list intact after patch")
check(#pika.level1Moves == 1 and pika.level1Moves[1] == "GROWL",
  "arrays replace wholesale in record patches")
check(pika.evolutions == nil, "DELETE sentinel unsets a field")
check(patchData.pokemon.RAICHU.baseStats.attack == 90,
  "other records untouched by patch")
check(patchLoader.content.pokemon:get("PIKACHU").baseStats.attack == 120,
  "registry get returns the folded record")

-- each() unions base and op ids
local ids = {}
for id in patchLoader.content.pokemon:each() do ids[id] = true end
check(ids.PIKACHU and ids.RAICHU, "each() yields base and patched ids")

-- ------- patch typo: near-match unknown field is a named load error
local typoFiles = {
  ["mods/typo/manifest.json"] = manifestJson("typo", { api = 2 }),
  ["mods/typo/main.lua"] = [[
return function(mod)
  mod.content.pokemon:patch("PIKACHU", { base_stats = { attack = 10 } })
end
]],
}
local typoData = fixtureData()
local typoLoader = Loader.new({ fs = memfs(typoFiles) })
check(typoLoader:load(typoData) == false, "typo'd patch fails the mod")
local typoError = table.concat(typoLoader.errors, "\n")
check(typoError:find('did you mean "baseStats"', 1, true) ~= nil,
  "typo error suggests the schema field")
check(typoData.pokemon.PIKACHU.baseStats.attack == 55,
  "failed patch leaves the record untouched")

-- ------- remove: tombstones survive the merge as deletes; re-register
-- after remove resurrects the id
local removeFiles = {
  ["mods/pruner/manifest.json"] = manifestJson("pruner", { api = 2 }),
  ["mods/pruner/main.lua"] = [[
return function(mod)
  mod.content.items:remove("POTION")
  mod.content.items:remove("THUNDER_STONE")
  mod.content.items:register("THUNDER_STONE",
    { id = "THUNDER_STONE", name = "THUNDER STONE", price = 9999 })
  mod.content.items:register("NEW_ITEM", { id = "NEW_ITEM", name = "NEW ITEM", price = 10 })
end
]],
}
local removeData = fixtureData()
removeData.pokemon.PIKACHU.evolutions = {} -- fixture no longer references the stone
local removeLoader = Loader.new({ fs = memfs(removeFiles) })
check(removeLoader:load(removeData) == true, "remove mod loads cleanly")
check(removeData.items.POTION == nil, "tombstone deletes the key from Data")
check(removeLoader.content.items:get("POTION") == nil,
  "registry get treats a tombstoned id as absent")
check(removeLoader.content.items:has("POTION") == false,
  "has() is false for a tombstoned id")
check(removeData.items.THUNDER_STONE ~= nil
  and removeData.items.THUNDER_STONE.price == 9999,
  "register after remove resurrects the id")
local itemIds = {}
for id in removeLoader.content.items:each() do itemIds[#itemIds + 1] = id end
table.sort(itemIds)
check(#itemIds == 2 and itemIds[1] == "NEW_ITEM" and itemIds[2] == "THUNDER_STONE",
  "each() skips tombstones and includes op-only ids")
for id in pairs(removeData.items) do
  check(id ~= "POTION", "no stale tombstoned key while iterating Data")
end

-- content is frozen after the merge; reads still work
check(not pcall(function()
  removeLoader.content.items:patch("NEW_ITEM", { price = 1 })
end), "patch refused after freeze")
check(not pcall(function()
  removeLoader.content.items:remove("NEW_ITEM")
end), "remove refused after freeze")
check(removeLoader.content.items:get("NEW_ITEM").price == 10,
  "frozen registry still readable")

-- ------- schema fail (api 2): named load error, no residue
local badFiles = {
  ["mods/strict_pack/manifest.json"] = manifestJson("strict_pack", { api = 2 }),
  ["mods/strict_pack/main.lua"] = [[
return function(mod)
  mod.content.pokemon:register("BADMON", { name = "BADMON" })
end
]],
}
local badData = fixtureData()
local badLoader = Loader.new({ fs = memfs(badFiles) })
check(badLoader:load(badData) == false, "schema violation fails an api 2 mod")
local badError = table.concat(badLoader.errors, "\n")
check(badError:find("strict_pack", 1, true) ~= nil,
  "schema error names the mod")
check(badError:find("pokemon.BADMON", 1, true) ~= nil
  and badError:find("missing required field", 1, true) ~= nil,
  "schema error names the registry, id and problem")
check(badData.pokemon.BADMON == nil and badLoader.content.pokemon:get("BADMON") == nil,
  "rejected registration leaves zero residue")

-- ------- schema pass (api 2): a valid new record registers and merges
local goodFiles = {
  ["mods/adder/manifest.json"] = manifestJson("adder", { api = 2 }),
  ["mods/adder/main.lua"] = [[
return function(mod)
  mod.content.pokemon:register("NEWMON", {
    id = "NEWMON", name = "NEWMON", dex = 152,
    types = { "NORMAL" },
    baseStats = { hp = 50, attack = 50, defense = 50, speed = 50, special = 50 },
    catchRate = 45, baseExp = 100,
    level1Moves = { "GROWL" },
    growthRate = "MEDIUM_FAST",
    learnset = { { level = 10, move = "THUNDERSHOCK" } },
    evolutions = {},
    spriteFront = "newmon_front.png", spriteBack = "newmon_back.png",
    frontSize = 5,
  })
end
]],
}
local goodData = fixtureData()
local goodLoader = Loader.new({ fs = memfs(goodFiles) })
check(goodLoader:load(goodData) == true, "valid api 2 registration loads")
check(goodData.pokemon.NEWMON ~= nil and goodData.pokemon.NEWMON.dex == 152,
  "valid registration merges into Data")

-- ------- api 1 compat: the same violation downgrades to a warning
local legacyFiles = {
  ["mods/legacy_pack/manifest.json"] = manifestJson("legacy_pack"),
  ["mods/legacy_pack/main.lua"] = [[
return function(mod)
  mod.content.pokemon:register("BADMON", { name = "BADMON" })
end
]],
}
local legacyData = fixtureData()
local legacyLoader = Loader.new({ fs = memfs(legacyFiles) })
check(legacyLoader:load(legacyData) == true,
  "api 1 mod loads despite the schema violation")
check(legacyData.pokemon.BADMON ~= nil and legacyData.pokemon.BADMON.name == "BADMON",
  "api 1 registration still merges")
check(logged("[legacy_pack]", "missing required field"),
  "api 1 violation logged as a mod-attributed warning")

-- ------- namespace creation: base-less registries merge into created
-- namespaces and data.audio.songs appears when absent
local nsFiles = {
  ["mods/screens_pack/manifest.json"] = manifestJson("screens_pack", { api = 2 }),
  ["mods/screens_pack/main.lua"] = [[
return function(mod)
  mod.content.screens:register("QuestLog", { new = function() return {} end })
  mod.content.map_scripts:register("PALLET_TOWN", {
    talk = { TEXT_TEST = { { "show_text", "HELLO" } } },
  })
  mod.content.music:register("MOD_SONG", { file = "song.ogg" })
end
]],
  ["mods/scripts_pack/manifest.json"] = manifestJson("scripts_pack",
    { api = 2, deps = '["screens_pack"]' }),
  ["mods/scripts_pack/main.lua"] = [[
return function(mod)
  mod.content.map_scripts:register("PALLET_TOWN", {
    onEnter = function() end,
    priority = 10,
  })
end
]],
}
local nsData = fixtureData()
local nsLoader = Loader.new({ fs = memfs(nsFiles) })
check(nsLoader:load(nsData) == true, "namespace mods load cleanly")
check(type(nsData.screens) == "table" and type(nsData.screens.QuestLog) == "table"
  and type(nsData.screens.QuestLog.new) == "function",
  "screens registration merges into a created namespace")
check(nsLoader.content.screens:get("QuestLog") ~= nil,
  "screens value retrievable via content get")
local chain = nsData.map_scripts and nsData.map_scripts.PALLET_TOWN
check(type(chain) == "table" and #chain == 2,
  "map_scripts compose chain carries both registrations")
check(type(chain[1].onEnter) == "function",
  "higher-priority chain entry sorts first")
check(chain[2].talk and chain[2].talk.TEXT_TEST ~= nil,
  "chain keeps the talk registration")
local got = nsLoader.content.map_scripts:get("PALLET_TOWN")
check(got ~= nil and type(got.onEnter) == "function",
  "content get returns the top-priority chain entry")
check(nsData.audio and nsData.audio.songs
  and nsData.audio.songs.MOD_SONG
  and nsData.audio.songs.MOD_SONG.file == "song.ogg",
  "data.audio.songs created when the base module is absent")

-- the interim consumer: data/scripts/init.lua layers merged chains over
-- its built-in table and is untouched with no chains present
love = love or require("tests.love_stub")
local CoreData = require("src.core.Data")
local mapScripts = require("data.scripts.init")
local builtIn = mapScripts.get("PALLET_TOWN")
check(builtIn ~= nil and builtIn.talk ~= nil, "built-in pallet town script present")
CoreData.map_scripts = { PALLET_TOWN = { { talk = { TEXT_TEST = { { "text", "HI" } } } } } }
local layeredTalk = mapScripts.talkScript("PALLET_TOWN", "TEXT_TEST")
check(type(layeredTalk) == "table", "mod talk script layered over the built-ins")
check(mapScripts.talkScript("PALLET_TOWN", "TEXT_PALLETTOWN_OAK") ~= nil,
  "built-in talk scripts survive the layering")
local layeredMap = mapScripts.get("PALLET_TOWN")
for key, value in pairs(builtIn) do
  if key ~= "talk" then
    check(layeredMap[key] == value, "built-in hook preserved: " .. tostring(key))
  end
end
CoreData.map_scripts = nil
check(mapScripts.get("PALLET_TOWN") == builtIn,
  "no chains resolves to the built-in table untouched")

-- ------- v1 aliases: scripts/ui keep working with a one-shot deprecation
-- warning per mod; the audio whole-table registry warns too
local aliasFiles = {
  ["mods/v1_pack/manifest.json"] = manifestJson("v1_pack"),
  ["mods/v1_pack/main.lua"] = [[
return function(mod)
  mod.content.scripts:register("VIRIDIAN_CITY", {
    talk = { TEXT_TEST = { { "text", "HI" } } },
  })
  mod.content.scripts:register("PALLET_TOWN", {
    talk = { TEXT_TEST = { { "text", "YO" } } },
  })
  mod.content.ui:register("LegacyScreen", function() return {} end)
  mod.content.audio:override("battle", { theme = "X" })
end
]],
}
local aliasData = fixtureData()
local aliasLoader = Loader.new({ fs = memfs(aliasFiles) })
check(aliasLoader:load(aliasData) == true, "v1 alias mod loads cleanly")
check(aliasData.map_scripts and aliasData.map_scripts.VIRIDIAN_CITY ~= nil,
  "v1 scripts registration lands in map_scripts")
check(type(aliasData.screens.LegacyScreen) == "function",
  "v1 ui registration lands in screens")
check(aliasData.audio and aliasData.audio.battle
  and aliasData.audio.battle.theme == "X",
  "v1 audio whole-key override still works")
check(loggedCount("[v1_pack]", "the scripts registry is deprecated") == 1,
  "scripts deprecation warned exactly once per mod")
check(logged("[v1_pack]", "use map_scripts"), "scripts warning names the successor")
check(logged("[v1_pack]", "the ui registry is deprecated"),
  "ui deprecation warned")
check(logged("[v1_pack]", "the audio registry is deprecated"),
  "audio deprecation warned")

-- ------- cross-reference pass: a dangling f.id is caught post-merge
local danglingFiles = {
  ["mods/dangler/manifest.json"] = manifestJson("dangler", { api = 2 }),
  ["mods/dangler/main.lua"] = [[
return function(mod)
  mod.content.pokemon:patch("PIKACHU", { level1Moves = { "MISSING_MOVE" } })
end
]],
}
local danglingData = fixtureData()
local danglingLoader = Loader.new({ fs = memfs(danglingFiles) })
check(danglingLoader:load(danglingData) == false,
  "dangling reference fails an api 2 mod")
check(table.concat(danglingLoader.errors, "\n")
  :find("MISSING_MOVE", 1, true) ~= nil,
  "cross-reference error names the missing id")

-- ------- cross-reference pass: removing an id still referenced by a
-- vanilla record no mod touched is caught and pinned on the remover
local removedRefFiles = {
  ["mods/species_pruner/manifest.json"] = manifestJson("species_pruner", { api = 2 }),
  ["mods/species_pruner/main.lua"] = [[
return function(mod)
  mod.content.pokemon:remove("PIKACHU")
end
]],
}
local removedRefData = fixtureData()
removedRefData.trainers = {
  OPP_TEST = { id = "OPP_TEST", name = "TEST",
    parties = { { { level = 5, species = "PIKACHU" } } } },
}
local removedRefLoader = Loader.new({ fs = memfs(removedRefFiles) })
check(removedRefLoader:load(removedRefData) == false,
  "removing a still-referenced species fails the removing mod")
local removedRefError = table.concat(removedRefLoader.errors, "\n")
check(removedRefError:find("species_pruner", 1, true) ~= nil,
  "removal cross-ref error names the removing mod")
check(removedRefError:find("OPP_TEST", 1, true) ~= nil
  and removedRefError:find("PIKACHU", 1, true) ~= nil,
  "removal cross-ref error names the referencing record and the removed id")

-- ------- every vanilla record must satisfy its schema, so the shipped
-- example's copy-the-base-record override idiom always validates cleanly
local vanillaSets = {
  { "pokemon", require("data.generated.pokemon") },
  { "moves", require("data.generated.moves") },
  { "items", require("data.generated.items") },
  { "maps", require("data.generated.maps") },
  { "tilesets", require("data.generated.tilesets") },
  { "encounters", require("data.generated.encounters") },
  { "trainers", require("data.generated.trainers") },
  { "sprites", require("data.generated.sprites") },
  { "text", require("data.generated.text") },
  { "music", require("data.generated.audio").songs },
}
for _, pair in ipairs(vanillaSets) do
  local name, records = pair[1], pair[2]
  local spec = Schemas.REGISTRIES[name]
  for id, record in pairs(records) do
    local ok, err = Schemas.check(spec, name, id, record, "register")
    check(ok, "vanilla record validates: " .. tostring(err))
  end
end

-- ------- value-schema records keep the extensible top level; the typo
-- guard and nested strictness survive
check(Schemas.check(Schemas.REGISTRIES.map_scripts, "map_scripts", "PALLET_TOWN",
  { onEnter = function() end, questFlag = "SOME_QUEST" }, "register") == true,
  "unknown top-level field allowed on a value-schema record")
check(Schemas.check(Schemas.REGISTRIES.screens, "screens", "QuestLog",
  { new = function() end, sourceMod = "quest_pack" }, "register") == true,
  "union rec alternative keeps the top level extensible")
check(Schemas.check(Schemas.REGISTRIES.music, "music", "MOD_SONG",
  { file = "song.ogg", composer = "someone" }, "register") == true,
  "music union rec keeps the top level extensible")
local typoOk, typoErr = Schemas.check(Schemas.REGISTRIES.map_scripts,
  "map_scripts", "PALLET_TOWN", { on_enter = function() end }, "register")
check(typoOk == nil and typoErr:find('did you mean "onEnter"', 1, true) ~= nil,
  "near-match typo on a value-schema record still rejected")
local nestedOk, nestedErr = Schemas.check(Schemas.REGISTRIES.map_scripts,
  "map_scripts", "PALLET_TOWN",
  { talk = { TEXT_TEST = 5 } }, "register")
check(nestedOk == nil and nestedErr ~= nil,
  "nested value inside a known field stays strictly typed")

-- ------- standalone registry fold semantics (no loader)
local reg = Registry.new("pokemon", Schemas.REGISTRIES.pokemon)
local base = { A = { name = "A", nested = { x = 1, y = 2 } } }
reg.base = function() return base end
reg:patch("A", { nested = { x = 9 } }, "m1")
check(reg:get("A").nested.x == 9 and reg:get("A").nested.y == 2,
  "standalone patch folds over the base record")
check(base.A.nested.x == 1, "fold never mutates the base record")
reg:remove("A", "m1")
check(reg:get("A") == nil, "standalone remove tombstones")
reg:register("A", { name = "A2" }, "m2")
check(reg:get("A").name == "A2", "register after remove resurrects")
reg:rollback("m2")
check(reg:get("A") == nil, "rollback drops an owner's ops")
reg:rollback("m1")
check(reg:get("A").nested.x == 1, "full rollback restores the base view")

-- a payload that IS the sentinel folds as a delete, never a value
reg:patch("A", Registry.DELETE, "m3")
check(reg:get("A") == nil, "whole-value DELETE patch tombstones the id")
reg:rollback("m3")
reg:override("A", Registry.DELETE, "m3")
check(reg:get("A") == nil, "whole-value DELETE override tombstones the id")
reg:rollback("m3")
check(reg:get("A").nested.x == 1, "rollback restores after sentinel ops")

-- ------- deep: lists accumulate so stacked mods never erase each other
local deepReg = Registry.new("text_pointers", Schemas.REGISTRIES.text_pointers)
local deepBase = { Cerulean = { TEXT_MART = { mart = { "POKE_BALL" } } } }
deepReg.base = function() return deepBase end
deepReg:patch("Cerulean", { TEXT_MART = { mart = { "TM_A" } } }, "modA")
deepReg:patch("Cerulean", { TEXT_MART = { mart = { "TM_B" } } }, "modB")
local mart = deepReg:get("Cerulean").TEXT_MART.mart
check(#mart == 3 and mart[1] == "POKE_BALL" and mart[2] == "TM_A"
  and mart[3] == "TM_B",
  "two patches of one deep list both survive, in load order")
check(#deepBase.Cerulean.TEXT_MART.mart == 1, "appending never mutates the base")
deepReg:override("Cerulean", { TEXT_MART = { mart = { "TM_C" } } }, "modC")
local replaced = deepReg:get("Cerulean").TEXT_MART.mart
check(#replaced == 1 and replaced[1] == "TM_C",
  "override still replaces the list wholesale")
deepReg:rollback("modC")
deepReg:rollback("modA")
local afterRollback = deepReg:get("Cerulean").TEXT_MART.mart
check(#afterRollback == 2 and afterRollback[2] == "TM_B",
  "rolling one contributor back leaves the other's rows")

-- record registries keep the replace rule: element-wise merging of a
-- learnset is ambiguous, so a whole list stands in for the old one
local recordReg = Registry.new("pokemon", Schemas.REGISTRIES.pokemon)
recordReg.base = function() return { A = { level1Moves = { "TACKLE" } } } end
recordReg:patch("A", { level1Moves = { "GROWL" } }, "m1")
check(#recordReg:get("A").level1Moves == 1
  and recordReg:get("A").level1Moves[1] == "GROWL",
  "a record-registry list still replaces wholesale")

-- ------- compose: get/items/each surface the same head chain() sorts first
local composeReg = Registry.new("map_scripts", Schemas.REGISTRIES.map_scripts)
composeReg:register("MAP", { onEnter = function() return "low" end }, "modLow")
composeReg:register("MAP",
  { onEnter = function() return "high" end, priority = 100 }, "modHigh")
local composeChain = composeReg:chain("MAP")
check(#composeChain == 2 and composeChain[1].onEnter() == "high",
  "chain sorts the higher-priority entry first")
check(composeReg:get("MAP").onEnter() == "high",
  "compose get returns the chain head")
check(composeReg:items().MAP.onEnter() == "high",
  "compose items() folds to the chain head")
for _, value in composeReg:each() do
  check(value.onEnter() == "high", "compose each() yields the chain head")
end

S.finish()
