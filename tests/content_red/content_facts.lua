-- T3: the pinned Red facts, asserted from tests/content_red/facts.lua
-- (21-testing-and-ci "test taxonomy").
--
-- Every value here is Red-specific and would be wrong for a total
-- conversion, which is exactly why it lives in this tier and not in
-- tests/engine/.  The numbers come out of facts.lua so a conversion can
-- point the same assertions at its own table.

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local facts = require("tests.content_red.facts")

local Data = require("src.core.Data")
Data:load()

-- ------- the dataset the ROM import is supposed to produce

for _, name in ipairs(facts.requiredModules) do
  T.check(Data[name] ~= nil, "generated data module loaded: " .. name)
end

do
  local dex = 0
  for _ in pairs(Data.pokemon) do dex = dex + 1 end
  T.eq(dex, facts.dexSize, "the full dex is imported")
  T.eq(Data.constants.dexSize, facts.dexSize, "constants.dexSize matches the roster")
end

-- the type records are engine built-ins that arrive with the merge, so
-- the zero-mod load has to run before they can be counted
local run = T.sdk.loadNone({ data = Data })
T.eq(#run.errors, 0, "the generated dataset loads with no mods and no errors")

do
  local types = 0
  for _ in pairs(Data.type_chart.types or {}) do types = types + 1 end
  T.eq(types, facts.typeCount, "the Gen 1 type list is complete")
end

-- ------- maps

local MapLoader = require("src.world.MapLoader")

for id, size in pairs(facts.maps) do
  local map = MapLoader.load(Data, id)
  T.check(map ~= nil, "map loads: " .. id)
  if map then
    T.eq(map.widthCells, size.widthCells, id .. " width in cells")
    T.eq(map.heightCells, size.heightCells, id .. " height in cells")
  end
end

do
  local pallet = MapLoader.load(Data, "PALLET_TOWN")
  for _, cell in ipairs(facts.pallet.walkable) do
    T.check(pallet:isWalkableCell(cell[1], cell[2]),
      ("Pallet cell (%d,%d) is walkable"):format(cell[1], cell[2]))
  end
  for _, cell in ipairs(facts.pallet.blocked) do
    T.check(not pallet:isWalkableCell(cell[1], cell[2]),
      ("Pallet cell (%d,%d) is blocked"):format(cell[1], cell[2]))
  end

  local door = facts.pallet.doorWarp
  T.check(pallet:isWarpTileCell(door.x, door.y), "Red's house door is a door tile")
  local warp = pallet:warpAtCell(door.x, door.y)
  T.eq(warp and warp.def.destMap, door.destMap, "the door warp leads to Red's house")

  local sign = pallet:signAtCell(facts.pallet.oakSign.x, facts.pallet.oakSign.y)
  T.eq(sign and sign.text, facts.pallet.oakSign.text, "Oak's lab sign text constant")
end

-- ------- species

local Stats = require("src.pokemon.Stats")
local ZERO_DVS = { hp = 0, attack = 0, defense = 0, speed = 0, special = 0 }

for id, want in pairs(facts.starters) do
  local def = Data.pokemon[id]
  T.check(def ~= nil, "starter present: " .. id)
  if def then
    T.eq(def.dex, want.dex, id .. " dex number")
    T.eq(#def.types, #want.types, id .. " type count")
    for i, typeId in ipairs(want.types) do
      T.eq(def.types[i], typeId, ("%s type %d"):format(id, i))
    end
    local stats = Stats.calc(def, 5, ZERO_DVS)
    for stat, value in pairs(want.statsAt5) do
      T.eq(stats[stat], value, ("L5 %s %s (0 DVs)"):format(id, stat))
    end
  end
end

-- ------- engine literals that a conversion overrides

T.eq(Data.constants.fallbackMove, facts.fallbackMove, "the move-slot repair floor")

for i, move in ipairs(facts.hmMoves) do
  T.eq(Data.constants.hmMoves[i], move, "HM move " .. i)
end

for i, badge in ipairs(facts.badges) do
  T.eq(Data.constants.badges[i].id, badge, "badge " .. i .. " in gym order")
end

-- ------- party icons

for dex, icon in pairs(facts.icons) do
  T.eq(Data.icons.byDex[dex], icon, "party icon for dex " .. dex)
end

run.release()

T.finish("content_red_facts")
