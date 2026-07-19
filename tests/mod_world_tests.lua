-- World & maps v2: the de-Kanto'd literals replayed against their old
-- values, authoring a new map/tileset/encounter table through the
-- registries, the encounter/palette/collision/warp hooks, the map events,
-- MapLoader invalidation, and the mod.world runtime services.
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local Collision = require("src.world.Collision")
local Data = require("src.core.Data")
local Encounter = require("src.world.Encounter")
local Events = require("src.mods.Events")
local FieldDefaults = require("src.world.FieldDefaults")
local Hooks = require("src.mods.Hooks")
local Loader = require("src.mods.Loader")
local Map = require("src.world.Map")
local MapLoader = require("src.world.MapLoader")
local Merge = require("src.mods.Merge")
local OW = require("src.world.OverworldController")
local Registry = require("src.mods.Registry")
local Runtime = require("src.mods.Runtime")
local Schemas = require("src.mods.Schemas")
local Warp = require("src.world.Warp")
local WorldAPI = require("src.world.WorldAPI")

local S = require("tests.harness").suite("world & maps v2")
local check = S.check

if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end

-- the same upvalue rewire the parity suites use: OverworldState's methods
-- close over a module-local Game that only a real boot assigns
local function bindGame(fn, game)
  local i = 1
  while true do
    local name = debug.getupvalue(fn, i)
    if not name then return false end
    if name == "Game" then debug.setupvalue(fn, i, game) return true end
    i = i + 1
  end
end

-- ------- the literal-lift oracles

-- paletteNameFor before this milestone, verbatim, as the oracle
local TOWN_PALS = {
  PALLET_TOWN = "PALLET", VIRIDIAN_CITY = "VIRIDIAN",
  PEWTER_CITY = "PEWTER", CERULEAN_CITY = "CERULEAN",
  LAVENDER_TOWN = "LAVENDER", VERMILION_CITY = "VERMILION",
  CELADON_CITY = "CELADON", FUCHSIA_CITY = "FUCHSIA",
  CINNABAR_ISLAND = "CINNABAR", INDIGO_PLATEAU = "INDIGO",
  SAFFRON_CITY = "SAFFRON",
}
local function oldPaletteNameFor(def, lastOutdoorId)
  local ts, id = def.tileset, def.id
  if ts == "CEMETERY" then return "GRAYMON"
  elseif ts == "CAVERN" then return "CAVE"
  elseif id == "LORELEIS_ROOM" then return "PALLET"
  elseif id == "BRUNOS_ROOM" then return "CAVE"
  elseif TOWN_PALS[id] or id:match("^ROUTE_") then
    return TOWN_PALS[id] or "ROUTE"
  end
  local last = lastOutdoorId or "PALLET_TOWN"
  return TOWN_PALS[last] or "ROUTE"
end

do
  local fakeGame = { data = Data }
  check(bindGame(OW.paletteNameFor, fakeGame), "paletteNameFor binds Game")
  -- every map, with no outdoor memory and with each of the outdoor maps
  -- remembered, must land on the palette the literals used to pick
  -- "" stands for no outdoor memory at all
  local lasts = { "", "PALLET_TOWN", "ROUTE_1", "INDIGO_PLATEAU", "CELADON_CITY" }
  local mapIds = {}
  for id in pairs(Data.maps) do mapIds[#mapIds + 1] = id end
  table.sort(mapIds)
  local compared = 0
  for _, lastId in ipairs(lasts) do
    local last = lastId ~= "" and { id = lastId } or nil
    local state = setmetatable({ lastOutdoor = last }, { __index = OW })
    for _, id in ipairs(mapIds) do
      local def = Data.maps[id]
      local want = oldPaletteNameFor(def, last and last.id)
      local got = state:paletteNameFor({ id = id, def = def })
      check(got == want, ("palette parity %s (last %s): got %s, want %s")
        :format(id, tostring(last and last.id), tostring(got), tostring(want)))
      compared = compared + 1
    end
  end
  check(compared >= #mapIds * 2, "palette oracle covered every map")
end

do
  -- Map:isWaterCell against the pre-change literals, over every cell of
  -- the largest map of each tileset (SHIP_PORT's $32 exception included)
  local byTileset, area = {}, {}
  for id, def in pairs(Data.maps) do
    local size = def.width * def.height
    if size > (area[def.tileset] or -1) then
      area[def.tileset], byTileset[def.tileset] = size, id
    end
  end
  local cells = 0
  for tileset, mapId in pairs(byTileset) do
    local map = MapLoader.load(Data, mapId)
    for cy = 0, map.heightCells - 1 do
      for cx = 0, map.widthCells - 1 do
        local t = map:cellTile(cx, cy)
        local want = t == 0x14
          or (tileset ~= "SHIP_PORT" and (t == 0x32 or t == 0x48))
        check(map:isWaterCell(cx, cy) == want,
          ("water parity %s (%d,%d) tile %02x"):format(mapId, cx, cy, t))
        cells = cells + 1
      end
    end
  end
  check(cells > 10000, "water oracle walked a real sample of cells")
end

do
  -- outdoor / outside / region / ghost / pushable, replayed per map
  for id, def in pairs(Data.maps) do
    check(Map.isOutdoor(def) == (def.tileset == "OVERWORLD"),
      "outdoor parity " .. id)
    check(Map.isOutside(def) ==
      (def.tileset == "OVERWORLD" or def.tileset == "PLATEAU"),
      "outside parity " .. id)
    check(Map.inRegion(def, "SAFARI", "SAFARI_ZONE")
      == (id:find("SAFARI_ZONE", 1, true) == 1), "safari region parity " .. id)
    local ghost = Map.ghostBattles(def)
    check((ghost ~= nil) == (id:find("POKEMON_TOWER", 1, true) == 1),
      "ghost battle parity " .. id)
    for _, obj in ipairs(def.objects or {}) do
      check(Map.isPushable(obj) == (obj.sprite == "SPRITE_BOULDER"),
        "pushable parity " .. id)
    end
  end
  -- the properties win over the fallbacks, which is how a new map opts in
  check(Map.isOutdoor({ id = "X", tileset = "CAVERN", outdoor = true }),
    "map.outdoor overrides the tileset fallback")
  check(not Map.isOutdoor({ id = "X", tileset = "OVERWORLD", outdoor = false }),
    "map.outdoor = false is honored, not treated as absent")
  check(Map.inRegion({ id = "MY_ZONE", region = "SAFARI" }, "SAFARI", "SAFARI_ZONE"),
    "map.region reaches the safari rules without a Kanto name")
  check(not Map.inRegion({ id = "SAFARI_ZONE_X", region = "OTHER" }, "SAFARI",
    "SAFARI_ZONE"), "an explicit region beats the id prefix")
  check(Map.isPushable({ sprite = "SPRITE_OAK", pushable = true }),
    "obj.pushable makes any sprite a boulder")
end

do
  -- the Route 22 Gate LAST_MAP rewrite, now a table
  local rewrite = FieldDefaults.field(Data, "lastMapRewrites").ROUTE_22_GATE
  for y = 0, 8 do
    local want = y < 4 and "ROUTE_23" or "ROUTE_22"
    check(OW.rewrittenLastMap(rewrite, 0, y) == want,
      "last-map rewrite parity at y=" .. y)
  end
  -- ordered rules, first match wins, and the x axis works the same
  local custom = { axis = "x", rules = { { below = 2, map = "A" },
                                         { atLeast = 6, map = "C" },
                                         { map = "B" } } }
  check(OW.rewrittenLastMap(custom, 1, 0) == "A", "x-axis rewrite low")
  check(OW.rewrittenLastMap(custom, 4, 0) == "B", "x-axis rewrite default row")
  check(OW.rewrittenLastMap(custom, 7, 0) == "C", "x-axis rewrite atLeast")
end

do
  -- badge gates dispatch on the record's shape, not the map id, and the
  -- Route 22 gate keeps its pre-v2 save flag spelling
  check(FieldDefaults.fieldValue(Data, "badgeGates", "ROUTE_22_GATE", "passedFlag")
    == "PASSED_ROUTE22_GATE", "the vanilla gate keeps its save flag name")
  check(FieldDefaults.fieldValue(Data, "badgeGates", "MY_GATE", "passedFlag")
    == nil, "a gate a mod adds falls through to PASSED_<mapId>")
  check(Data.field.badgeGates.ROUTE_22_GATE.coords ~= nil,
    "the Route 22 gate record is the coords shape")
  check(Data.field.badgeGates.ROUTE_23.guards ~= nil,
    "the Route 23 record is the guards shape")
end

do
  -- the ledge rows keep their OVERWORLD-only reach until a row says otherwise
  local rows = 0
  for _, ledge in ipairs(Data.field.ledges) do
    check(ledge.tileset == nil, "vanilla ledge rows carry no tileset")
    rows = rows + 1
  end
  check(rows > 0, "ledge rows extracted")
end

-- ------- encounter buckets

do
  check(FieldDefaults.constant(Data, "encounterBuckets")[10] == 256,
    "encounterBuckets seeded, last bucket 256")
  local seq, i = { 0, 20 }, 0
  local function rng() i = i + 1 return seq[i] end
  -- rate 30 > 0 so the first draw bites; pick 20 lands in slot 1 (< 51)
  local def = { grass = { rate = 30, slots = {
    { species = "RATTATA", level = 3 }, { species = "PIDGEY", level = 5 } } } }
  local enc = Encounter.roll(def, rng)
  check(enc and enc.species == "RATTATA", "vanilla buckets pick slot 1")
  -- a per-def bucket array of any length reshapes the odds
  i = 0
  def.grass.buckets = { 10, 256 }
  enc = Encounter.roll(def, rng)
  check(enc and enc.species == "PIDGEY", "per-def buckets reshape the slot pick")
end

-- ------- fixture + inline mods

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

-- a private slice of the real dataset: these tests merge into their data
local function fixture()
  local maps = {}
  for _, id in ipairs({ "PALLET_TOWN", "ROUTE_21", "ROUTE_22_GATE",
                        "SEAFOAM_ISLANDS_B4F", "VERMILION_GYM" }) do
    maps[id] = Merge.deepCopy(Data.maps[id])
  end
  local pokemon = {}
  for _, id in ipairs({ "TANGELA", "MAGIKARP", "GOLDEEN", "POLIWAG" }) do
    pokemon[id] = Merge.deepCopy(Data.pokemon[id])
  end
  return {
    maps = maps,
    pokemon = pokemon,
    tilesets = Merge.deepCopy(Data.tilesets),
    items = Merge.deepCopy(Data.items),
    moves = Merge.deepCopy(Data.moves),
    sprites = Merge.deepCopy(Data.sprites),
    encounters = {},
    constants = Merge.deepCopy(Data.constants),
    field = FieldDefaults.seed({ field = Merge.deepCopy(Data.field) }).field,
  }
end

local function withMod(id, source)
  local loader = Loader.new({ fs = memfs({
    ["mods/" .. id .. "/manifest.json"] = manifestJson(id),
    ["mods/" .. id .. "/main.lua"] = source,
  }) })
  local data = fixture()
  local ok = loader:load(data)
  return data, loader, ok
end

-- ------- seeding is fill-only and idempotent

do
  local data = { field = { palettes = { byMap = { MY_TOWN = "MINE" } } },
                 constants = { world = { stepFrames = 4 } } }
  FieldDefaults.seed(data)
  check(data.field.palettes.byMap.MY_TOWN == "MINE",
    "seed never overwrites a stamped value")
  check(data.field.palettes.byMap.PALLET_TOWN == "PALLET",
    "seed fills the missing siblings of a stamped record")
  check(data.constants.world.stepFrames == 4, "seed leaves a stamped constant")
  check(data.constants.world.turnFrames == 2, "seed fills the missing siblings")
  check(data.field.fishing.OLD_ROD.always.species == "MAGIKARP",
    "seed installs the whole missing key")
  local before = data.field.fishing
  FieldDefaults.seed(data)
  check(data.field.fishing == before, "seed is idempotent")
  -- the vanilla dataset is untouched by any of this
  check(Data.field.source ~= nil, "the real field table still loads")
end

-- ------- authoring a new map, tileset, connection and encounter table

local SABLE = [[
return function(mod)
  -- a mod-local atlas is just a path; this fixture borrows the vanilla
  -- sheet so the headless renderer has real dimensions to quad up
  mod.content.tilesets:register("SABLE_TILES", {
    id = "SABLE_TILES",
    image = "assets/generated/tilesets/overworld.png",
    imageWidth = 128, imageHeight = 48, tilesPerRow = 16,
    blocks = (function()
      local blocks = {}
      for b = 1, 4 do
        local row = {}
        -- block 0 is all grass, block 3 all water; 1 and 2 are spare
        for i = 1, 16 do row[i] = (b == 1) and 0x01 or 0x14 end
        blocks[b] = row
      end
      return blocks
    end)(),
    walkable = { 0x01 },
    waterTiles = { 0x14 },
    shoreTiles = {},
    grassTile = 0x01,
  })
  mod.content.maps:register("SABLE_COVE", {
    id = "SABLE_COVE", label = "SableCove",
    tileset = "SABLE_TILES", width = 4, height = 4,
    blocks = (function()
      local b = {}
      for i = 1, 16 do b[i] = (i <= 8) and 0 or 3 end
      return b
    end)(),
    borderBlock = 3,
    warps = {}, signs = {}, objects = {},
    connections = { north = { map = "ROUTE_21", offset = 0 } },
    outdoor = true, palette = "WATER",
  })
  mod.content.maps:patch("ROUTE_21", {
    connections = { south = { map = "SABLE_COVE", offset = 0 } },
  })
  mod.content.encounters:register("SABLE_COVE", {
    grass = { rate = 200, slots = (function()
      local s = {}
      for i = 1, 10 do s[i] = { level = 22, species = "TANGELA" } end
      return s
    end)() },
  })
  mod.content.field:patch("hiddenItems", {
    SABLE_COVE = { { x = 3, y = 3, item = "NUGGET" } },
  })
  mod.content.field:patch("flyWarps", { SABLE_COVE = { x = 2, y = 2 } })
  mod.content.field:patch("flyOrder", { __append = { "SABLE_COVE" } })
  mod.content.field:patch("townMap", {
    locations = { SABLE_COVE = { x = 4, y = 17, name = "SABLE COVE" } },
    cursorOrder = { __append = { "SABLE_COVE" } },
  })
  mod.content.field:patch("palettes", { byMap = { SABLE_COVE = "WATER" } })
end
]]

do
  local data, loader, ok = withMod("sable_cove", SABLE)
  check(ok, "the new-map mod loads: " .. tostring((loader.errors or {})[1]))
  check(data.maps.SABLE_COVE ~= nil, "the authored map reaches data.maps")
  check(data.tilesets.SABLE_TILES ~= nil, "the authored tileset reaches data")
  check(data.maps.ROUTE_21.connections.south.map == "SABLE_COVE",
    "a connections patch lands on a base map")
  check(data.maps.ROUTE_21.connections.north ~= nil,
    "the base map keeps its other connections")

  -- the map builds and walks: MapLoader resolves both records lazily
  MapLoader.invalidate("SABLE_COVE")
  local cove = MapLoader.load(data, "SABLE_COVE")
  check(cove.widthCells == 8 and cove.heightCells == 8, "authored map geometry")
  check(cove:isWalkableCell(0, 0), "authored walkable tile")
  check(cove:isGrassCell(0, 0), "authored grass tile")
  check(cove:isWaterCell(0, 7), "authored water tile via tileset.waterTiles")
  check(not cove:isWaterCell(0, 0), "authored land tile is not water")
  check(Map.isOutdoor(cove.def), "the authored map declares itself outdoor")

  -- neighbors compose off the patched connection, both ways
  local fromCove = OW.computeNeighbors(data.maps, "SABLE_COVE", 1)
  check(#fromCove == 1 and fromCove[1].id == "ROUTE_21",
    "the authored map connects north to Route 21")
  local fromRoute = OW.computeNeighbors(data.maps, "ROUTE_21", 1)
  local sawCove = false
  for _, n in ipairs(fromRoute) do
    if n.id == "SABLE_COVE" then sawCove = true end
  end
  check(sawCove, "Route 21 connects back south to the authored map")

  -- the encounter table rolls the authored species
  local seq, i = { 0, 0 }, 0
  local enc = Encounter.roll(data.encounters.SABLE_COVE,
    function() i = i + 1 return seq[i] or 0 end)
  check(enc and enc.species == "TANGELA", "the authored encounter table rolls")

  -- the field patches added to Kanto instead of replacing it
  check(data.field.hiddenItems.SABLE_COVE[1].item == "NUGGET",
    "a map-dict field patch adds the mod's map")
  check(data.field.hiddenItems.VIRIDIAN_FOREST ~= nil,
    "the map-dict keeps every vanilla entry")
  check(data.field.flyWarps.SABLE_COVE.x == 2, "a fly warp is one patch")
  check(data.field.flyWarps.PALLET_TOWN ~= nil, "the vanilla fly warps survive")
  check(data.field.flyOrder[#data.field.flyOrder] == "SABLE_COVE",
    "__append puts the new map at the end of the fly order")
  check(#data.field.flyOrder == #Data.field.flyOrder + 1,
    "__append extends the list instead of replacing it")
  check(data.field.townMap.locations.SABLE_COVE.name == "SABLE COVE",
    "the town-map square is one patch")
  check(data.field.townMap.locations.PALLET_TOWN ~= nil,
    "the vanilla town-map squares survive")
  check(data.field.palettes.byMap.SABLE_COVE == "WATER",
    "a palettes patch adds a map")
  check(data.field.palettes.byMap.PALLET_TOWN == "PALLET",
    "the vanilla palette table survives the patch")
  MapLoader.invalidate("SABLE_COVE")
end

-- ------- town map and fly order as data

do
  local data = fixture()
  data.field.flyOrder = { "PALLET_TOWN", "ROUTE_21", "PALLET_TOWN" }
  data.maps.ROUTE_21.outdoor = false
  local game = { data = data, save = { visited = { PALLET_TOWN = true,
                                                   ROUTE_21 = true } } }
  local menu = require("src.ui.FlyMenu").new(game)
  local labels = {}
  for _, item in ipairs(menu.items or {}) do labels[#labels + 1] = item.value end
  check(#labels == 1 and labels[1] == "PALLET_TOWN",
    "the fly menu reads flyOrder, dedupes, and honors map.outdoor")
end

-- ------- MapLoader invalidation

do
  local data = fixture()
  local before = MapLoader.load(data, "PALLET_TOWN")
  local rendererBefore = before.renderer
  check(MapLoader.load(data, "PALLET_TOWN") == before, "the cache returns one instance")
  check(MapLoader.cached("PALLET_TOWN") == before, "cached() sees it")

  -- an un-invalidated map keeps its instance even after its record changes
  data.maps.PALLET_TOWN.blocks[1] = 0x0B
  check(MapLoader.load(data, "PALLET_TOWN") == before,
    "a record change alone does not reach a cached map")

  check(MapLoader.invalidate("PALLET_TOWN"), "invalidate reports the drop")
  check(MapLoader.cached("PALLET_TOWN") == nil, "the entry is gone")
  local after = MapLoader.load(data, "PALLET_TOWN")
  check(after ~= before, "the next load builds a fresh Map")
  check(after.renderer ~= rendererBefore, "and a fresh TileRenderer")
  check(after:blockAt(0, 0) == 0x0B, "blockAt reflects the patched record")
  check(not MapLoader.invalidate("NO_SUCH_MAP"), "invalidating a cold map is false")
  MapLoader.invalidateAll()
  check(MapLoader.cached("PALLET_TOWN") == nil, "invalidateAll clears everything")
end

-- ------- hooks: empty chains are the vanilla path

local function withBuses(fn)
  local events, hooks = Events.new(), Hooks.new()
  local prevE, prevH = Runtime.events, Runtime.hooks
  Runtime.install(events, hooks)
  local ok, err = pcall(fn, events, hooks)
  Runtime.events, Runtime.hooks = prevE, prevH
  if not ok then error(err, 0) end
end

do
  check(not Runtime.wantsHook("encounter.roll"),
    "no chain means no encounter ctx is ever built")
  check(not Runtime.wants("world.stepped"),
    "no listener means no world.stepped payload is ever built")
end

do
  -- encounter.roll suppresses; encounter.species transforms; unhooked is vanilla
  local data = fixture()
  data.encounters.PALLET_TOWN = { grass = { rate = 255, slots = (function()
    local s = {}
    for i = 1, 10 do s[i] = { level = 5, species = "TANGELA" } end
    return s
  end)() } }
  -- rollEncounter needs no Game: it reads the def it is handed and the map
  -- id off self, which is what keeps the hot path free of a Data lookup
  local state = setmetatable({ map = MapLoader.load(data, "PALLET_TOWN") },
    { __index = OW })

  local vanilla = state:rollEncounter(data.encounters.PALLET_TOWN, "grass")
  check(vanilla and vanilla.species == "TANGELA",
    "with no wrapper the roll is the vanilla pick")

  withBuses(function(_, hooks)
    hooks:wrap("encounter.roll", function() return nil end, 0, "suppressor")
    local suppressed = 0
    for _ = 1, 200 do
      if state:rollEncounter(data.encounters.PALLET_TOWN, "grass") == nil then
        suppressed = suppressed + 1
      end
    end
    check(suppressed == 200, "an encounter.roll wrapper suppresses every encounter")
  end)

  withBuses(function(_, hooks)
    local sawCtx
    hooks:wrap("encounter.species", function(next_, enc, ctx)
      sawCtx = ctx
      enc = next_(enc, ctx)
      enc.species = "MAGIKARP"
      return enc
    end, 0, "transformer")
    local enc = state:rollEncounter(data.encounters.PALLET_TOWN, "grass")
    check(enc and enc.species == "MAGIKARP",
      "an encounter.species wrapper transforms the roll")
    check(sawCtx.mapId == "PALLET_TOWN" and sawCtx.terrain == "grass",
      "the encounter ctx carries the documented fields")
  end)

  -- the chain sees the def and may force a pick without calling next
  withBuses(function(_, hooks)
    hooks:wrap("encounter.roll", function()
      return { species = "GOLDEEN", level = 40 }
    end, 0, "forcer")
    local enc = state:rollEncounter(nil, "water")
    check(enc and enc.species == "GOLDEEN" and enc.level == 40,
      "a wrapper that skips next forces its own encounter")
  end)
  MapLoader.invalidateAll()
end

do
  -- the rod tables are field.fishing now, and encounter.fishing wraps the
  -- catch with the resolved pool in hand
  local fishing = FieldDefaults.field(Data, "fishing")
  check(fishing.OLD_ROD.always.species == "MAGIKARP",
    "the Old Rod's fixed catch is data")
  check(#fishing.GOOD_ROD.pool == 2 and fishing.GOOD_ROD.pool[1].species == "GOLDEEN",
    "the Good Rod's pool is data")
  check(fishing.SUPER_ROD.perMap == "superRod",
    "the Super Rod points at the per-map field key")
  check(Data.field.superRod ~= nil, "and that key is the extracted table")
end

do
  -- movement.collision: the verdict flips, the reason rides ctx
  local map = MapLoader.load(Data, "PALLET_TOWN")
  local mover = { cellX = 5, cellY = 6, facing = "up" }
  local blocked, why = Collision.canMove(map, { mover }, mover, "left")
  check(blocked == true, "the plaza step is legal with no wrapper")
  withBuses(function(_, hooks)
    local seen
    hooks:wrap("movement.collision", function(next_, allowed, ctx)
      seen = ctx
      allowed = next_(allowed, ctx)
      ctx.reason = "warded"
      return false
    end, 0, "warder")
    local ok2, reason = Collision.canMove(map, { mover }, mover, "left")
    check(ok2 == false and reason == "warded",
      "a movement.collision wrapper blocks a legal step")
    check(seen.map == map and seen.mover == mover and seen.dir == "left"
      and seen.fromX == 5 and seen.fromY == 6 and seen.toX == 4 and seen.toY == 6,
      "the collision ctx carries the documented fields")
  end)
  -- (4,4) is a house wall: the vanilla reason survives the unwrapped path
  local walled = { cellX = 4, cellY = 5, facing = "up" }
  blocked, why = Collision.canMove(map, { walled }, walled, "up")
  check(blocked == false and why == "tile", "a walled step still reports 'tile'")
end

do
  -- warp.destination reroutes one door without owning the warp table
  local warpDef = Data.maps.PALLET_TOWN.warps[1]
  local m1 = Warp.destination(Data, warpDef)
  withBuses(function(_, hooks)
    hooks:wrap("warp.destination", function(next_, mapId, x, y, ctx)
      check(ctx.warp == warpDef, "warp ctx carries the warp record")
      local _, nx, ny = next_(mapId, x, y, ctx)
      return "ROUTE_21", nx, ny
    end, 0, "rerouter")
    local m2, x2 = Warp.destination(Data, warpDef)
    check(m2 == "ROUTE_21", "a warp.destination wrapper reroutes the door")
    check(x2 ~= nil, "and the landing cell still resolves")
  end)
  check(Warp.destination(Data, warpDef) == m1,
    "unwrapping restores the vanilla destination")
end

do
  -- map.palette recolors without touching the table
  local state = setmetatable({}, { __index = OW })
  check(bindGame(OW.paletteNameFor, { data = Data }), "paletteNameFor rebinds")
  local map = { id = "PALLET_TOWN", def = Data.maps.PALLET_TOWN }
  check(state:paletteNameFor(map) == "PALLET", "vanilla palette unhooked")
  withBuses(function(_, hooks)
    hooks:wrap("map.palette", function(next_, name, m)
      check(m == map, "the palette hook sees the map")
      return next_(name, m) .. "_NIGHT"
    end, 0, "night")
    check(state:paletteNameFor(map) == "PALLET_NIGHT",
      "a map.palette wrapper transforms the name")
  end)
end

-- ------- events

do
  local data = fixture()
  withBuses(function(events)
    local seen = {}
    events:on("world.block_replaced", function(ev) seen.block = ev end, 0, "spy")
    events:on("map.reloaded", function(ev) seen.reload = ev end, 0, "spy")
    local map = MapLoader.load(data, "PALLET_TOWN")
    local state = setmetatable({ map = map, neighbors = {} }, { __index = OW })
    state:replaceBlock(1, 1, 7)
    check(seen.block and seen.block.mapId == "PALLET_TOWN"
      and seen.block.bx == 1 and seen.block.by == 1 and seen.block.block == 7,
      "world.block_replaced fires with the documented payload")

    check(bindGame(OW.reloadMap, { data = data }), "reloadMap binds Game")
    state.map = nil -- not the active map: pure cache drop
    state:reloadMap("ROUTE_21", "hot_reload")
    check(seen.reload and seen.reload.mapId == "ROUTE_21"
      and seen.reload.reason == "hot_reload",
      "map.reloaded carries the reason")
  end)
  MapLoader.invalidateAll()
end

-- ------- a live world, driven headlessly

-- setMap and onStepComplete close over the same two module-locals a real
-- boot fills in; with both rewired the world runs without a Game:load
local function liveWorld(data)
  local StateStack = require("src.core.StateStack")
  local SaveData = require("src.core.SaveData")
  require("src.render.Font").load(data)
  local stack = setmetatable({ states = {} }, { __index = StateStack })
  local game = { data = data, save = SaveData.newGame(), stack = stack,
                 input = { isDown = function() return false end },
                 renderer = { worldViewSize = function() return 160, 144 end } }
  check(bindGame(OW.setMap, game), "setMap binds Game")
  local i = 1
  while true do
    local name = debug.getupvalue(OW.setMap, i)
    if not name then break end
    if name == "mapScripts" then
      debug.setupvalue(OW.setMap, i, require("data.scripts.init"))
    end
    i = i + 1
  end
  local state = setmetatable({ camera = require("src.render.Camera").new(),
                               scriptMoves = {}, npcPool = {} },
                             { __index = OW })
  stack.states[1] = state
  game.overworld = state
  return state, game
end

do
  local data = fixture()
  data.maps = Merge.deepCopy(Data.maps) -- setMap walks the connection graph
  data.encounters = Merge.deepCopy(Data.encounters)
  data.audio = Data.audio
  data.text = Data.text
  data.font = Data.font
  local state, game = liveWorld(data)

  withBuses(function(events)
    local seen = {}
    events:on("map.entered", function(ev) seen.entered = ev end, 0, "spy")
    events:on("map.exited", function(ev) seen.exited = ev end, 0, "spy")
    events:on("world.stepped", function(ev) seen.stepped = ev end, 0, "spy")

    state:setMap("PALLET_TOWN", 5, 6, "down", { via = "boot" })
    check(seen.entered and seen.entered.mapId == "PALLET_TOWN"
      and seen.entered.via == "boot" and seen.entered.fromMapId == nil
      and seen.entered.map == state.map,
      "map.entered fires at boot with the documented payload")
    check(seen.exited == nil, "map.exited does not fire when no map was loaded")

    state:setMap("ROUTE_21", 5, 6, "down")
    check(seen.exited and seen.exited.mapId == "PALLET_TOWN"
      and seen.exited.toMapId == "ROUTE_21",
      "map.exited names both sides of the change")
    check(seen.entered.via == "warp" and seen.entered.fromMapId == "PALLET_TOWN",
      "map.entered reports the previous map and how it was reached")

    state:setMap("PALLET_TOWN", 5, 6, "down", { seamless = true })
    check(seen.entered.via == "connection", "a seamless crossing reports 'connection'")

    pcall(state.onStepComplete, state)
    check(seen.stepped and seen.stepped.mapId == "PALLET_TOWN"
      and seen.stepped.x == 5 and seen.stepped.y == 6
      and type(seen.stepped.tile) == "number",
      "world.stepped fires with mapId, cell and tile")
  end)

  -- WorldAPI against the live world: invalidateMap reloads in place
  withBuses(function(events)
    local reloaded
    events:on("map.reloaded", function(ev) reloaded = ev end, 0, "spy")
    local api = WorldAPI.new(game, "tester")
    local snapshot = api:current()
    check(snapshot.mapId == "PALLET_TOWN" and snapshot.x == 5,
      "current() finds the world through the stack marker")

    local before = MapLoader.cached("PALLET_TOWN")
    local pool = state.npcPool
    data.maps.PALLET_TOWN.blocks[1] = 0x0B
    check(api:invalidateMap("PALLET_TOWN") == true, "invalidateMap succeeds")
    check(reloaded and reloaded.mapId == "PALLET_TOWN"
      and reloaded.reason == "invalidate", "map.reloaded fires for the caller")
    check(MapLoader.cached("PALLET_TOWN") ~= before, "the map was rebuilt")
    check(state.map:blockAt(0, 0) == 0x0B, "the reloaded map sees the new record")
    check(state.player.cellX == 5 and state.player.cellY == 6,
      "the player keeps its cell across the reload")
    check(state.npcPool == pool, "the NPC pool identity survives the reload")

    -- warping through the facade lands the player on the new map
    check(api:warpTo("ROUTE_21", 4, 4, "up") == true, "warpTo starts the warp")
    check(state.transitioning == true, "and the world is mid-transition")
  end)

  -- walking the authored map triggers a wild battle from its own table
  do
    local moddedData, _, loaded = withMod("sable_cove", SABLE)
    check(loaded, "the authored map mod loads for the walk")
    moddedData.maps.ROUTE_21 = Merge.deepCopy(Data.maps.ROUTE_21)
    moddedData.audio, moddedData.text = data.audio, data.text
    moddedData.font, moddedData.trainer_headers = data.font, {}
    local walker, walkerGame = liveWorld(moddedData)
    walkerGame.save.party = { require("src.pokemon.Pokemon").new(moddedData,
                                                                 "TANGELA", 30) }
    walker:setMap("SABLE_COVE", 0, 0, "down", { via = "boot" })
    check(walker.map:isGrassCell(0, 0), "the player stands in authored grass")
    local caught
    walker.pushBattle = function(_, battle) caught = battle end
    -- rate 200/256 per step: no reseed, so the shared RNG stream the rest
    -- of the runner depends on is left exactly where it was
    for _ = 1, 200 do
      pcall(walker.onStepComplete, walker)
      if caught then break end
    end
    check(caught ~= nil, "a wild battle fires on the authored map")
    check(caught.enemy and caught.enemy.mon
      and caught.enemy.mon.species == "TANGELA",
      "and it is the species the authored encounter table names")

    -- the same walk with an encounter.roll wrapper never starts a battle
    withBuses(function(_, hooks)
      hooks:wrap("encounter.roll", function() return nil end, 0, "nuzlocke")
      caught = nil
      for _ = 1, 1000 do
        pcall(walker.onStepComplete, walker)
        check(caught == nil, "encounter.roll suppression holds for the whole walk")
      end
    end)
    MapLoader.invalidateAll()
  end

  MapLoader.invalidateAll()
end

-- ------- a map record that omits the optional subtables

do
  -- warps/signs/objects are all f.opt in the maps schema, so a record
  -- authored without them has to survive the entered-map spawn loop and
  -- the neighbor ghost loop, not just Map.new
  local data = fixture()
  data.maps = Merge.deepCopy(Data.maps)
  data.encounters = Merge.deepCopy(Data.encounters)
  data.audio, data.text, data.font = Data.audio, Data.text, Data.font
  data.trainer_headers = {}

  local bare = Merge.deepCopy(Data.maps.ROUTE_21)
  bare.id, bare.label = "BARE_COVE", "BareCove"
  bare.warps, bare.signs, bare.objects = nil, nil, nil
  bare.connections = { north = { map = "ROUTE_21", offset = 0 } }
  data.maps.BARE_COVE = bare
  data.maps.ROUTE_21.connections.south = { map = "BARE_COVE", offset = 0 }

  local state = liveWorld(data)
  local ok, err = pcall(state.setMap, state, "BARE_COVE", 1, 1, "down",
                        { via = "boot" })
  check(ok, "entering a map with no objects table does not throw: "
    .. tostring(err))
  check(#state.npcs == 0, "and it simply spawns no NPCs")

  -- the same record reached as a rendered neighbor of the active map
  ok, err = pcall(state.setMap, state, "ROUTE_21", 5, 5, "down")
  check(ok, "a neighbor with no objects table does not throw: "
    .. tostring(err))
  local sawBare = false
  for _, nb in ipairs(state.neighbors) do
    if nb.map.id == "BARE_COVE" then sawBare = true end
  end
  check(sawBare, "and that neighbor really was in the drawn set")

  MapLoader.invalidateAll()
end

-- ------- mod.world

do
  local api = WorldAPI.new({ data = Data, stack = { states = {} } }, "tester")
  local value, err = api:current()
  check(value == nil and err == "no overworld", "current() off the world")
  value, err = api:warpTo("PALLET_TOWN", 5, 6)
  check(value == nil and err == "no overworld", "warpTo() off the world")
  value, err = api:replaceBlock(0, 0, 1)
  check(value == nil and err == "no overworld", "replaceBlock() off the world")
  value, err = api:spawnNpc("PALLET_TOWN", { sprite = "SPRITE_OAK" })
  check(value == nil and err == "no overworld", "spawnNpc() off the world")
  value, err = api:npc("PALLET_TOWN", 1)
  check(value == nil and err == "no overworld", "npc() off the world")
  value, err = api:queueScript({})
  check(value == nil and err == "no overworld", "queueScript() off the world")
end

do
  local data = fixture()
  local save = { flags = {}, objectToggles = {}, party = {} }
  local map = MapLoader.load(data, "PALLET_TOWN")
  local state = setmetatable({ map = map, npcs = {}, entities = {}, npcPool = {},
                               neighbors = {}, player = { cellX = 5, cellY = 6,
                                                          facing = "down" } },
                             { __index = OW })
  local game = { data = data, save = save,
                 stack = { states = { state } } }
  check(bindGame(OW.addRuntimeObject, game), "addRuntimeObject binds Game")
  local api = WorldAPI.new(game, "tester")
  local other = WorldAPI.new(game, "intruder")

  local snapshot = api:current()
  check(snapshot.mapId == "PALLET_TOWN" and snapshot.x == 5 and snapshot.y == 6
    and snapshot.facing == "down", "current() snapshots the live world")

  -- flags
  check(api:setFlag("mod:tester:hello", true), "setFlag writes")
  check(api:getFlag("mod:tester:hello") == true, "getFlag reads back")
  check(save.flags["mod:tester:hello"] == true, "the flag lands in the save")

  -- object toggles emit and persist
  withBuses(function(events)
    local seen
    events:on("world.object_toggled", function(ev) seen = ev end, 0, "spy")
    -- an inactive map takes the plain save-write path
    check(api:toggleObject("ROUTE_21", "SOMEONE", false), "toggleObject writes")
    check(save.objectToggles.ROUTE_21.SOMEONE == false, "the toggle persists")
    check(seen and seen.mapId == "ROUTE_21" and seen.objName == "SOMEONE"
      and seen.visible == false, "world.object_toggled fires")
  end)

  -- spawnNpc / removeNpc, with ownership enforced
  local before = #data.maps.PALLET_TOWN.objects
  local npcId = api:spawnNpc("PALLET_TOWN",
    { x = 6, y = 6, sprite = "SPRITE_OAK", movement = "STAY", range = "DOWN" })
  check(type(npcId) == "string", "spawnNpc returns an id: " .. tostring(npcId))
  check(#data.maps.PALLET_TOWN.objects == before + 1,
    "the runtime object joins the map record")
  local spawned = data.maps.PALLET_TOWN.objects[before + 1]
  check(spawned.runtime == true and spawned.owner == "tester",
    "the runtime object records its owner")
  check(#state.npcs == 1 and state.npcs[1].id == npcId,
    "the NPC is instantiated on the active map")
  check(#state.entities == 1, "and joins the collision entities")

  check(bindGame(OW.removeRuntimeObject, game), "removeRuntimeObject binds Game")
  value, err = other:removeNpc(npcId)
  check(value == nil and err:find("not owned", 1, true),
    "removeNpc refuses another mod's object")
  check(#data.maps.PALLET_TOWN.objects == before + 1, "and changes nothing")
  check(api:removeNpc(npcId) == true, "the owner may remove it")
  check(#data.maps.PALLET_TOWN.objects == before, "the record is clean again")
  check(#state.npcs == 0 and #state.entities == 0, "and so is the live world")

  -- imported objects are never removable through this door
  local importedId = "PALLET_TOWN_obj_" .. data.maps.PALLET_TOWN.objects[1].index
  value, err = api:removeNpc(importedId)
  check(value == nil and err:find("no runtime object", 1, true),
    "removeNpc refuses an imported object")

  -- a handle onto a live NPC
  npcId = api:spawnNpc("PALLET_TOWN",
    { x = 7, y = 6, sprite = "SPRITE_OAK", movement = "STAY", range = "DOWN" })
  local handle = api:npc("PALLET_TOWN", npcId)
  check(handle ~= nil, "npc() resolves a handle by id")
  state.scriptMoves = {}
  check(handle:face("left"), "the handle turns the NPC")
  local hx, hy = handle:position()
  check(hx == 7 and hy == 6, "the handle reports the NPC cell")
  check(handle:scriptMove("left", 1), "the handle queues a scripted move")
  check(#state.scriptMoves == 1, "and the move reached the queue")
  api:removeNpc(npcId)

  -- spawnNpc on a map the dataset does not have
  value, err = api:spawnNpc("NO_SUCH_MAP", { sprite = "SPRITE_OAK" })
  check(value == nil and err:find("unknown map", 1, true),
    "spawnNpc refuses an unknown map")
  value, err = api:warpTo("NO_SUCH_MAP", 0, 0)
  check(value == nil and err:find("unknown map", 1, true),
    "warpTo validates against the merged maps")

  -- invalidateMap on the live map keeps the player and the pool identity
  check(bindGame(OW.reloadMap, game), "reloadMap rebinds")
  check(bindGame(OW.setMap, game), "setMap binds Game")
  check(bindGame(OW.healPoint, game), "healPoint binds Game")
  MapLoader.invalidateAll()
end

-- ------- no-mod parity of the seeded tables

do
  -- FieldDefaults never reaches into Data at require time
  local before = Merge.deepCopy(Data.field.ledges)
  local _ = FieldDefaults.field(Data, "palettes")
  local same = true
  for i, row in ipairs(Data.field.ledges) do
    for k, v in pairs(row) do if before[i][k] ~= v then same = false end end
  end
  check(same, "reading a default never mutates the dataset")
  check(Data.field.hiddenExtras.trashCans.map == "VERMILION_GYM",
    "a key the importer stamps is left as the importer wrote it")
end

-- ------- the boot path seeds, so a mod's patch folds over Kanto

do
  -- Data:load runs seedDefaults, which pulls these in.  Without them the
  -- registry's base for the key is nil and the first patch replaces Kanto
  -- wholesale instead of merging into it.
  check(Data.field.palettes.byMap.PALLET_TOWN == "PALLET",
    "the boot path seeded field.palettes")
  check(Data.field.playerSprites.walk == "SPRITE_RED",
    "the boot path seeded field.playerSprites")
  check(Data.field.badgeGates.ROUTE_22_GATE.passedFlag == "PASSED_ROUTE22_GATE",
    "the boot path filled the gaps in a stamped key")
  check(Data.constants.world.stepFrames == 16,
    "the boot path seeded constants.world")
  check(Data.constants.encounterBuckets[10] == 256,
    "the boot path seeded constants.encounterBuckets")

  local registry = Registry.new("field", Schemas.REGISTRIES.field)
  registry.base = function() return Data.field end
  registry:patch("palettes", { byMap = { SABLE_COVE = "WATER" } }, "somemod")
  local merged = registry:get("palettes")
  check(merged.byMap.SABLE_COVE == "WATER", "a field patch lands")
  check(merged.byMap.PALLET_TOWN == "PALLET", "and Kanto survives it")
  check(merged.default == "ROUTE", "including the fallthrough")
end

S.finish()
