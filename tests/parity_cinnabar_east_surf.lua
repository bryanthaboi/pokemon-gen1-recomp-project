-- Regression (#125): SURF from Cinnabar's east coast into Route 20 water.
--
-- Cinnabar's easternmost cells are walkable land (tile $39); the water is
-- on ROUTE_20 across the east connection. pokered loads that strip into
-- the border, so IsNextTileShoreOrWater sees shore tile $32. The port
-- must read the connection landing the same way -- an inBounds-only
-- water check returns "no_water" and blocks the mount (and the reverse
-- party-menu dismount back onto the coast).
--
-- Self-contained; run via `luajit tests/parity_cinnabar_east_surf.lua`.
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end

local Data = require("src.core.Data")
if not (Data.maps and Data.maps.CINNABAR_ISLAND) then Data:load() end

local Game = require("src.core.Game")
local Input = require("src.core.Input")
local Map = require("src.world.Map")
local MapLoader = require("src.world.MapLoader")
local Renderer = require("src.render.Renderer")
local SaveData = require("src.core.SaveData")
local StateStack = require("src.core.StateStack")
local OW = require("src.world.OverworldController")
local S = require("tests.harness").suite("parity cinnabar east surf")
local check, eq = S.check, S.eq

local function mkMon(species, ...)
  local moves = {}
  for _, id in ipairs({ ... }) do
    table.insert(moves, { id = id, pp = 10, ppUp = 0 })
  end
  return {
    species = species, level = 30, hp = 50, maxHp = 50,
    status = 0, moves = moves, nickname = nil,
  }
end

local cin = MapLoader.load(Data, "CINNABAR_ISLAND")
local r20 = MapLoader.load(Data, "ROUTE_20")
local r20ts = Data.tilesets[r20.def.tileset]

-- ground truth: east edge is land, Route 20 west landing is shore/water
check(cin:isWalkableCell(19, 8), "Cinnabar (19,8) is walkable coast")
check(not cin:isWaterCell(19, 8), "Cinnabar (19,8) is not water")
check(not cin:inBounds(20, 8), "facing east from (19,8) is off-map")
check(r20:isWaterCell(0, 8), "ROUTE_20 (0,8) is water/shore")
check(Map.defIsWaterCell(r20.def, r20ts, 0, 8),
      "defIsWaterCell agrees on ROUTE_20 (0,8)")
check(Map.defIsWalkableCell(cin.def, Data.tilesets[cin.def.tileset], 19, 8),
      "defIsWalkableCell agrees on Cinnabar coast")

Game.data = Data
Game.input = Input; Input:init()
Game.renderer = Renderer; Renderer:init()
Game.stack = StateStack
StateStack:init()
Game.save = SaveData.newGame()
Game.save.party = { mkMon("SQUIRTLE", "SURF") }
Game.save.inventory = { SOULBADGE = true }
Game.overworld = OW

while Game.stack:top() do Game.stack:pop() end
Game.stack:push(OW, "CINNABAR_ISLAND", 19, 8, "right")
local ow = Game.stack:top()
eq(ow.map.id, "CINNABAR_ISLAND", "start on Cinnabar east coast")
eq(ow.player.cellX, 19, "coast x")
eq(ow.player.cellY, 8, "coast y")
eq(ow.player.facing, "right", "facing east toward Route 20")

check(ow:facingIsShoreOrWater(),
      "facingIsShoreOrWater reads Route 20 shore across the seam")
eq(ow:useSurfFieldMove(), "ok",
   "useSurfFieldMove ok facing connection water (#125)")

-- reverse: surfing on Route 20 west edge, facing Cinnabar land
while Game.stack:top() do Game.stack:pop() end
Game.stack:push(OW, "ROUTE_20", 0, 8, "left")
ow = Game.stack:top()
ow.player.surfing = true
eq(ow.map.id, "ROUTE_20", "on Route 20 west water")
check(ow.map:isWaterCell(0, 8), "standing cell is water")
check(ow:facingIsLandDismount(),
      "facingIsLandDismount sees Cinnabar coast across the seam")
eq(ow:useSurfFieldMove(), "dismount",
   "party-menu SURF dismounts onto Cinnabar east coast")

-- facing open water while surfing still refuses
ow.player.facing = "right"
eq(ow:useSurfFieldMove(), "no_place",
   "surfing + facing open water: no place (unchanged)")

-- mount step crosses the seam onto Route 20 (surfing already armed)
while Game.stack:top() do Game.stack:pop() end
Game.stack:push(OW, "CINNABAR_ISLAND", 19, 8, "right")
ow = Game.stack:top()
ow.player.surfing = true
check(ow:stepForwardOrCrossEdge("right"),
      "stepForwardOrCrossEdge crosses onto Route 20 while surfing")
eq(ow.map.id, "ROUTE_20", "map swapped to Route 20 after edge surf step")
-- crossConnection parks one cell before the seam and walks in (same as
-- a live edge press); the landing target is Route 20 (0,8)
eq(ow.player.targetX, 0, "step target is Route 20 west column")
eq(ow.player.targetY, 8, "same Y across offset-0 east connection")
check(ow.player.moving, "seam step is in progress")

-- in-map Pallet south shore still works (no false connection match)
while Game.stack:top() do Game.stack:pop() end
Game.stack:push(OW, "PALLET_TOWN", 4, 13, "down")
ow = Game.stack:top()
ow.player.surfing = false
eq(ow:useSurfFieldMove(), "ok", "in-map water mount still ok")
ow.player.facing = "up"
eq(ow:useSurfFieldMove(), "no_water", "in-map land still no_water")

S.finish()
