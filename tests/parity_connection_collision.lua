-- Regression: map-edge crossings must read the NEIGHBOR map's collision.
--
-- Without that read, Pallet Town's south shore land spit (cells x=2,3 at
-- y=17) walked straight onto ROUTE_21 (2,0)/(3,0) -- solid tiles. From
-- (2,0) a further step south lands on walkable (2,1), after which the
-- solid edge cell blocks the only path back to the seam, so the player
-- cannot return north. pokered's CollisionCheckOnLand reads the neighbor
-- strip's tile bytes and bumps; the port must do the same via
-- Map.defPassable before crossConnection commits.
--
-- Self-contained; run via `luajit tests/parity_connection_collision.lua`.
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end

local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end

local Game = require("src.core.Game")
local Input = require("src.core.Input")
local Map = require("src.world.Map")
local MapLoader = require("src.world.MapLoader")
local Renderer = require("src.render.Renderer")
local SaveData = require("src.core.SaveData")
local StateStack = require("src.core.StateStack")
local OW = require("src.world.OverworldController")
local S = require("tests.harness").suite("parity connection collision")
local check, eq = S.check, S.eq

local pallet = MapLoader.load(Data, "PALLET_TOWN")
local route21 = MapLoader.load(Data, "ROUTE_21")
local ts = Data.tilesets[route21.def.tileset]

-- ground truth: the spit is land, the Route 21 landings are solid, and
-- the water column next to it is surf-only
for _, x in ipairs({ 2, 3 }) do
  check(pallet:isWalkableCell(x, 17),
        ("Pallet south shore (%d,17) is walkable land"):format(x))
  check(not route21:isWalkableCell(x, 0),
        ("ROUTE_21 (%d,0) is a solid landing"):format(x))
  check(not Map.defPassable(route21.def, ts, x, 0, false),
        ("defPassable refuses land->solid at ROUTE_21 (%d,0)"):format(x))
end
check(route21:isWaterCell(5, 0), "ROUTE_21 (5,0) is water")
check(not Map.defPassable(route21.def, ts, 5, 0, false),
      "water landing without Surf is refused")
check(Map.defPassable(route21.def, ts, 5, 0, true),
      "water landing with Surf is allowed")
check(not Map.defPassable(route21.def, nil, 2, 0, false),
      "missing tileset fails closed (no permissive fallback)")

-- Live edge: standing on the spit and pressing into the seam must bump,
-- not swap maps. Pallet -> Route 1 north still crosses on grass.
Game.data = Data
Game.input = Input; Input:init()
Game.renderer = Renderer; Renderer:init()
Game.stack = StateStack
StateStack:init()
Game.save = SaveData.newGame()
Game.overworld = OW

while Game.stack:top() do Game.stack:pop() end
Game.stack:push(OW, "PALLET_TOWN", 2, 17, "down")
local ow = Game.stack:top()
eq(ow.map.id, "PALLET_TOWN", "start on Pallet south shore")
eq(ow.player.cellX, 2, "spit x")
eq(ow.player.cellY, 17, "spit y")

local conn = ow.map:connection("south")
check(conn and conn.map == "ROUTE_21", "Pallet south connects to ROUTE_21")
check(ow:crossConnection("down", conn) == false,
      "crossConnection bumps on ROUTE_21 solid landing")
eq(ow.map.id, "PALLET_TOWN", "still on Pallet after the refused cross")
eq(ow.player.cellX, 2, "x unchanged after bump")
eq(ow.player.cellY, 17, "y unchanged after bump")

-- surfing the water column still crosses
ow.player.cellX, ow.player.cellY = 5, 17
ow.player.px, ow.player.py = 5 * 16, 17 * 16
ow.player.surfing = true
ow.player.moving = false
check(ow:crossConnection("down", conn) == true,
      "surfing Pallet water still crosses onto ROUTE_21")
eq(ow.map.id, "ROUTE_21", "surf cross lands on ROUTE_21")

-- north seam onto Route 1 grass still works on foot
while Game.stack:top() do Game.stack:pop() end
Game.stack:push(OW, "PALLET_TOWN", 10, 0, "up")
ow = Game.stack:top()
local north = ow.map:connection("north")
check(north and north.map == "ROUTE_1", "Pallet north connects to ROUTE_1")
check(ow:crossConnection("up", north) == true,
      "Pallet -> Route 1 grass crossing still allowed")
eq(ow.map.id, "ROUTE_1", "north cross lands on ROUTE_1")

S.finish()
