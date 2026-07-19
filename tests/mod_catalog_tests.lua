-- The D3 catalog completed in M4: a round-trip through every registry the
-- milestone adds, a crafted rejection per registry, the engine's own
-- registrations checked against their own schemas, and the type_chart
-- category oracle against the Damage.isSpecial list it will replace.
package.path = "./?.lua;./?/init.lua;" .. package.path

local Loader = require("src.mods.Loader")
local Schemas = require("src.mods.Schemas")
local Merge = require("src.mods.Merge")
local Builtins = require("src.mods.Builtins")
local TypeChart = require("src.battle.TypeChart")
local Damage = require("src.battle.Damage")
local Commands = require("src.script.Commands")

local S = require("tests.harness").suite("mod catalog")
local check = S.check

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

-- ------- the parity oracle: type category vs the hard-coded special list

-- Damage.isSpecial is still the live implementation; M7 replaces its body
-- with this lookup, so the two must already agree on every vanilla type.
local typeCount = 0
for id, record in pairs(TypeChart.TYPES) do
  typeCount = typeCount + 1
  check((record.category == "special") == Damage.isSpecial(id),
    "type_chart category matches Damage.isSpecial for " .. id)
end
check(typeCount == 15, "all 15 vanilla types carry a category record")

-- and the reverse direction: nothing outside the chart is special
check(not Damage.isSpecial("FAIRY"), "an unknown type is not special")

-- ------- the fixture

local vanillaChart = require("data.generated.type_chart")

local function fixtureData()
  return {
    pokemon = {}, moves = {},
    items = { POTION = { id = "POTION", name = "POTION", price = 300 } },
    type_chart = Merge.deepCopy(vanillaChart),
  }
end

-- one registration per registry this milestone adds, all cross-consistent
local catalogMod = [[
return function(mod)
  local function handler() end
  mod.content.type_chart:register("FAIRY", { name = "FAIRY", category = "special" })
  mod.content.type_chart:register("FAIRY>DRAGON", { multiplier = 20 })
  mod.content.statuses:register("CRS", { id = "CRS", label = "CRS",
    hudLabel = "CRS", catchBonus = 12 })
  mod.content.move_effects:register("SAP_PP_EFFECT", { kind = "primary", run = handler })
  mod.content.item_effects:register("MOON_FLUTE", { use = handler, field = true })
  mod.content.balls:register("DUSK_BALL", { randMax = 100, hpFactor = 10 })
  mod.content.evolution_methods:register("FRIENDSHIP", { check = handler })
  mod.content.growth_rates:register("ERRATIC",
    { expForLevel = function(level) return level * level end })
  mod.content.rulesets:register("no_crits", { name = "no crits", critRate = 0 })
  mod.content.ai_classes:register("OPP_MODDER",
    { uses = 2, chance = 64, item = "POTION" })
  mod.content.battle_anims:register("SHADOW_BALL", { seq = { 1, 2 } })
  mod.content.battle_anims:register("subanim:99", { blocks = { 1 }, type = "shake" })
  mod.content.battle_anims:register("tilesheet:9",
    { path = "anim.png", width = 8, height = 8, tiles = 1 })
  mod.content.palettes:register("MODMON",
    { { 255, 255, 255 }, { 200, 200, 200 }, { 100, 100, 100 }, { 0, 0, 0 } })
  mod.content.icons:register("PIKACHU", "SPARK")
  mod.content.font:register("cyrillic", { image = "cyr.png", base = 128,
    glyphsPerRow = 16, charmap = { { code = 200, seq = "<YO>" } } })
  mod.content.sfx:register("SFX_MOD_CHIME", { file = "chime.ogg" })
  mod.content.cries:register("MODMON", { file = "cry.ogg" })
  mod.content.music:register("Music_ModTheme", { file = "theme.ogg" })
  mod.content.map_songs:register("MOD_TOWN", "Music_ModTheme")
  mod.content.commands:register("shake_screen", handler)
  mod.content.tokens:register("CLOCK", handler)
  mod.content.transitions:register("dissolve", { frames = 30, draw = handler })
  mod.content.text_pointers:patch("PalletTown",
    { TEXT_MOD_SIGN = { text = "_ModSign", mart = { "POTION" } } })
  mod.content.migrations:register("catalog", { since = "1.0.0", run = handler })
end
]]

local data = fixtureData()
local loader = Loader.new({ fs = memfs({
  ["mods/catalog/manifest.json"] =
    '{"id":"catalog","name":"catalog","version":"1.0.0","entry":"main.lua","api":2}',
  ["mods/catalog/main.lua"] = catalogMod,
}) })
check(loader:load(data) == true,
  "the catalog mod loads clean: " .. table.concat(loader.errors, "; "))

-- ------- round-trip: every registration reaches its Data target

local function at(path)
  local node = data
  for key in path:gmatch("[^%.]+") do
    if type(node) ~= "table" then return nil end
    node = node[key]
  end
  return node
end

check(at("type_chart.types").FAIRY.category == "special", "type_chart type record merges")
check(at("statuses").CRS.label == "CRS", "statuses record merges")
check(at("move_effects").SAP_PP_EFFECT.kind == "primary", "move_effects record merges")
check(at("item_effects").MOON_FLUTE.field == true, "item_effects record merges")
check(at("balls").DUSK_BALL.randMax == 100, "balls record merges")
check(at("evolution_methods").FRIENDSHIP.check ~= nil, "evolution_methods record merges")
check(at("growth_rates").ERRATIC.expForLevel(5) == 25, "growth_rates record merges")
check(at("rulesets").no_crits.critRate == 0, "rulesets record merges")
check(at("ai_classes").OPP_MODDER.item == "POTION", "ai_classes record merges")
check(at("battle_anims.moveAnims").SHADOW_BALL.seq[2] == 2, "battle_anims move id merges")
check(at("battle_anims.subanims")[99].type == "shake", "battle_anims subanim id routes")
check(at("battle_anims.tilesheets")[9].tiles == 1, "battle_anims tilesheet id routes")
check(#at("palettes.palettes").MODMON == 4, "palettes record merges")
check(at("icons.bySpecies").PIKACHU == "SPARK", "icons record merges keyed by species")
check(at("font.pages").cyrillic.base == 128, "font page record merges")
check(at("audio.sfx").SFX_MOD_CHIME.file == "chime.ogg", "sfx record merges")
check(at("audio.cries").MODMON.file == "cry.ogg", "cries record merges")
check(at("audio.mapSongs").MOD_TOWN == "Music_ModTheme", "map_songs record merges")
check(at("commands").shake_screen ~= nil, "commands record merges")
check(at("tokens").CLOCK ~= nil, "tokens record merges")
check(at("transitions").dissolve.frames == 30, "transitions record merges")
check(at("text_pointers").PalletTown.TEXT_MOD_SIGN.text == "_ModSign",
  "text_pointers deep key merges")
check(#loader.content.migrations:chain("catalog") == 1, "migrations chain accumulates")

-- registry reads agree with the merged tables
check(loader.content.balls:get("DUSK_BALL").hpFactor == 10, "get returns the mod record")
check(loader.content.battle_anims:get("subanim:99").type == "shake",
  "get resolves a routed id")

-- ------- each(): the merged vanilla + mod view

local function idsOf(name)
  local ids = {}
  for id in loader.content[name]:each() do ids[id] = true end
  return ids
end

local statusIds = idsOf("statuses")
check(statusIds.PAR and statusIds.CRS, "statuses each() yields engine and mod ids")
local commandIds = idsOf("commands")
check(commandIds.show_text and commandIds.shake_screen,
  "commands each() yields engine and mod ids")
local typeIds = idsOf("type_chart")
check(typeIds.NORMAL and typeIds.FAIRY and typeIds["FAIRY>DRAGON"],
  "type_chart each() yields type records and matchup rows")
local ballIds = idsOf("balls")
check(ballIds.POKE_BALL and ballIds.DUSK_BALL, "balls each() yields engine and mod ids")
local animIds = idsOf("battle_anims")
check(animIds.SHADOW_BALL and animIds["subanim:99"],
  "battle_anims each() yields both id forms")

-- ------- type_chart merge rebuilds the row array the consumer reads

local rebuilt = data.type_chart.matchups
check(#rebuilt == #vanillaChart.matchups + 1,
  "the rebuilt chart keeps every vanilla row and adds the mod's")
for index, row in ipairs(vanillaChart.matchups) do
  local got = rebuilt[index]
  check(got.attacker == row.attacker and got.defender == row.defender
    and got.multiplier == row.multiplier,
    "rebuilt matchup row " .. index .. " is the vanilla row, in order")
end
local added = rebuilt[#rebuilt]
check(added.attacker == "FAIRY" and added.defender == "DRAGON"
  and added.multiplier == 20, "a registered matchup lands as a chart row")

-- ------- the engine's own registrations satisfy their own schemas

for name, registry in pairs(loader.content) do
  local spec = registry.spec
  for id in pairs(registry.ops) do
    if registry.owners[id] == Builtins.OWNER then
      local ok, err = Schemas.check(spec, name, id, registry:get(id), "register")
      check(ok, "vanilla " .. name .. " record validates: " .. tostring(err))
    end
  end
end

-- the registry serves the same function object the dispatcher calls, so
-- there is no window in which the two disagree
check(data.commands.show_text == Commands.show_text,
  "a registered command is the engine's own handler")

-- ------- schema rejection, one crafted violation per registry

local rejections = {
  { "type_chart", "FIRE", { name = "FIRE", category = "elemental" } },
  { "statuses", "CRS", { label = 7 } },
  { "move_effects", "X", { kind = "tertiary" } },
  { "item_effects", "X", { use = "not a function" } },
  { "balls", "X", { randMax = 900 } },
  { "evolution_methods", "X", { check = "nope" } },
  { "growth_rates", "X", { expForLevel = function() return 5 end } },
  { "rulesets", "X", { name = false } },
  { "ai_classes", "X", { uses = "many" } },
  { "battle_anims", "X", { seq = "not a list" } },
  { "palettes", "X", { { 1, 2, 3 }, { 4, 5, 6 } } },
  { "icons", "X", { frames = 2 } },
  { "font", "X", { image = "f.png", base = 0, glyphsPerRow = 1,
                   charmap = { { code = -1, seq = "x" } } } },
  { "sfx", "X", { file = 12 } },
  { "cries", "X", { pitch = "high" } },
  { "map_songs", "X", 42 },
  { "commands", "X", "not a function" },
  { "tokens", "X", { 1, 2 } },
  { "transitions", "X", { frames = 0 } },
  { "text_pointers", "PalletTown", { TEXT_X = { asm = "yes" } } },
  { "migrations", "mod", { since = 1, run = function() end } },
}
local covered = {}
for _, case in ipairs(rejections) do
  local name, id, value = case[1], case[2], case[3]
  covered[name] = true
  local spec = Schemas.REGISTRIES[name]
  check(spec ~= nil, name .. " is in the catalog")
  local ok, err = Schemas.check(spec, name, id, value, "register")
  check(not ok, name .. " rejects a malformed record")
  check(type(err) == "string" and err:find(name .. "." .. id, 1, true) ~= nil,
    name .. " names the offending path: " .. tostring(err))
end

-- the milestone's registry list, so a catalog entry cannot land untested
for _, name in ipairs({ "type_chart", "statuses", "move_effects", "item_effects",
    "balls", "evolution_methods", "growth_rates", "rulesets", "ai_classes",
    "battle_anims", "palettes", "icons", "font", "sfx", "cries", "map_songs",
    "commands", "tokens", "transitions", "text_pointers", "migrations" }) do
  check(Schemas.REGISTRIES[name] ~= nil, name .. " is declared")
  check(covered[name], name .. " has a rejection case")
  check(loader.content[name] ~= nil, name .. " is built by the loader")
end

-- ------- a schema violation is a load error for an api 2 mod

local badData = fixtureData()
local badLoader = Loader.new({ fs = memfs({
  ["mods/bad/manifest.json"] =
    '{"id":"bad","name":"bad","version":"1.0.0","entry":"main.lua","api":2}',
  ["mods/bad/main.lua"] = [[
return function(mod)
  mod.content.balls:register("SNAG_BALL", { randMax = 4096 })
end
]],
}) })
check(badLoader:load(badData) == false, "a malformed catalog record fails the mod")
check(table.concat(badLoader.errors, "\n"):find("balls.SNAG_BALL", 1, true) ~= nil,
  "the failure names the registry and id")
check(badData.balls.SNAG_BALL == nil, "a rejected record leaves no residue")
check(badData.balls.POKE_BALL ~= nil, "the engine's own balls still merged")

-- ------- a mod must say override to replace an engine record

local clashData = fixtureData()
local clashLoader = Loader.new({ fs = memfs({
  ["mods/clash/manifest.json"] =
    '{"id":"clash","name":"clash","version":"1.0.0","entry":"main.lua","api":2}',
  ["mods/clash/main.lua"] = [[
return function(mod)
  mod.content.balls:register("GREAT_BALL", { randMax = 180 })
end
]],
}) })
check(clashLoader:load(clashData) == false, "registering over an engine record fails")
check(clashData.balls.GREAT_BALL.randMax == 200, "the vanilla record survives")

local overData = fixtureData()
local overLoader = Loader.new({ fs = memfs({
  ["mods/over/manifest.json"] =
    '{"id":"over","name":"over","version":"1.0.0","entry":"main.lua","api":2}',
  ["mods/over/main.lua"] = [[
return function(mod)
  mod.content.balls:override("GREAT_BALL", { randMax = 180, hpFactor = 12 })
  mod.content.type_chart:override("FIRE", { name = "FIRE", category = "physical" })
end
]],
}) })
check(overLoader:load(overData) == true, "override replaces an engine record")
check(overData.balls.GREAT_BALL.randMax == 180, "the override reaches Data")
check(overData.type_chart.types.FIRE.category == "physical",
  "a retyped type reaches the rebuilt chart")

-- ------- merge order is decided by the target paths, not by pairs()

-- a whole-table registry has to merge before anything nested under it, or
-- its subtable swap drops the ids the granular registry already wrote
local order, position = loader:_mergeOrder(), {}
for index, name in ipairs(order) do position[name] = index end
local pairsChecked = 0
for outer, outerRegistry in pairs(loader.content) do
  local outerTarget = outerRegistry.spec.target
  for inner, innerRegistry in pairs(loader.content) do
    local innerTarget = innerRegistry.spec.target
    if outerTarget and innerTarget and outer ~= inner
        and innerTarget:sub(1, #outerTarget + 1) == outerTarget .. "." then
      pairsChecked = pairsChecked + 1
      check(position[outer] < position[inner],
        outer .. " must merge before " .. inner)
    end
  end
end
check(pairsChecked >= 4, "the audio family exercises the prefix rule")

-- and the same content always yields the same order
local sameOrder = Loader.new({ fs = memfs({}) }):_mergeOrder()
check(#sameOrder == #order, "the merge order covers every registry")
for index, name in ipairs(order) do
  check(sameOrder[index] == name, "merge order is stable at slot " .. index)
end

-- ------- the deprecated audio registry coexists with the granular ones

local mixedData = fixtureData()
local mixedLoader = Loader.new({ fs = memfs({
  ["mods/legacy/manifest.json"] =
    '{"id":"legacy","name":"legacy","version":"1.0.0","entry":"main.lua","api":1}',
  ["mods/legacy/main.lua"] = [[
return function(mod)
  mod.content.audio:override("cries", { OLD = { file = "old.ogg" } })
  mod.content.audio:override("sfx", { OLD = "SFX_OLD" })
end
]],
  ["mods/granular/manifest.json"] =
    '{"id":"granular","name":"granular","version":"1.0.0","entry":"main.lua","api":2}',
  ["mods/granular/main.lua"] = [[
return function(mod)
  mod.content.cries:register("NEW", { file = "new.ogg" })
  mod.content.sfx:register("NEW", { file = "new.ogg" })
end
]],
}) })
check(mixedLoader:load(mixedData) == true,
  "the v1 and v2 audio registries load together: "
    .. table.concat(mixedLoader.errors, "; "))
check(mixedData.audio.cries.OLD ~= nil and mixedData.audio.cries.NEW ~= nil,
  "the whole-table cries swap and the granular id both survive")
check(mixedData.audio.sfx.OLD ~= nil and mixedData.audio.sfx.NEW ~= nil,
  "the whole-table sfx swap and the granular id both survive")

S.finish()
