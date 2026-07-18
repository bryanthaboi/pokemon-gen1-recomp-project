-- Headless tests for tools/save-editor/panels/MapBrowser.lua.
-- Run from repo root: lua5.4 tests/save_editor_task8_tests.lua
-- (love_stub lacks push/pop/scale/scissor; MapBrowser skips real
-- rendering under those but still runs all click/button logic, which is
-- what these tests exercise via Kit.beginFrame like the other panels.)

package.path = package.path .. ";./?.lua;./?/init.lua;./tools/save-editor/?.lua"
  .. ";./tools/save-editor/panels/?.lua"

local love_stub = require("tests.love_stub")
love = love_stub

local passed, failed = 0, 0

local function check(cond, msg)
  if cond then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL: " .. msg)
  end
end

local function eq(a, b, msg)
  check(a == b, msg .. string.format(" (got %s, want %s)", tostring(a), tostring(b)))
end

print("== save editor task 8 (map browser) tests ==")

local Data = require("src.core.Data")
Data:load()

local SaveData = require("src.core.SaveData")
local State = require("State")
local Kit = require("Kit")
local MapBrowser = require("MapBrowser")

local LIST_W, LIST_H, ROW_H = 200, 300, 20
local MAX_ROWS = math.floor(LIST_H / ROW_H)
local VIEW_W, VIEW_H = 480, 432

local function newState()
  local S = State.new()
  S.data = Data
  S.save = SaveData.newGame()
  S.mapId = S.save.player.map -- PALLET_TOWN
  return S
end

local px, py = 12, 80
local vx, vy = px + LIST_W + 20, py + 24

-- ---------------------------------------------------------------- list
do
  local S = newState()
  local ids = {}
  for id in pairs(Data.maps) do table.insert(ids, id) end
  table.sort(ids)
  check(#ids > 200, "generated data has lots of maps")

  -- click the 3rd row of the map id list -> selects that map, no crash
  -- despite love_stub missing push/pop/scale/scissor
  Kit.beginFrame(px + 10, py + 24 + 2 * ROW_H + 5, true)
  MapBrowser.draw(S, Kit, px, py)
  eq(S.mapId, ids[3], "clicking list row 3 selects the 3rd sorted map id")
  check(S.mapClickCell == nil, "switching maps clears any selected cell")
end

do
  local S = newState()
  -- Next then Prev should return to the first page
  Kit.beginFrame(px + 64 + 5, py + 24 + MAX_ROWS * ROW_H + 8 + 5, true) -- Next
  MapBrowser.draw(S, Kit, px, py)
  eq(S.mapListScroll, MAX_ROWS, "Next advances one page")

  Kit.beginFrame(px + 5, py + 24 + MAX_ROWS * ROW_H + 8 + 5, true) -- Prev
  MapBrowser.draw(S, Kit, px, py)
  eq(S.mapListScroll, 0, "Prev returns to page 0")
end

-- ------------------------------------------------------------- click-to-cell
do
  local S = newState() -- PALLET_TOWN
  -- (5,6) is a known-walkable, non-warp cell (tests/run_tests.lua uses
  -- the same ground truth); zoom 2 means 32 screen px per cell.
  local mx = vx + 5 * 16 * S.mapZoom + 4
  local my = vy + 6 * 16 * S.mapZoom + 4
  Kit.beginFrame(mx, my, true)
  MapBrowser.draw(S, Kit, px, py)
  check(S.mapClickCell ~= nil, "clicking inside the viewport selects a cell")
  if S.mapClickCell then
    eq(S.mapClickCell.cx, 5, "selected cell cx")
    eq(S.mapClickCell.cy, 6, "selected cell cy")
  end

  -- clicking outside the viewport (e.g. over the list) must not select a cell
  S.mapClickCell = nil
  Kit.beginFrame(px + 5, py + 5, true)
  MapBrowser.draw(S, Kit, px, py)
  check(S.mapClickCell == nil, "clicking outside the viewport doesn't select a cell")
end

-- ---------------------------------------------------------------- set player
do
  local S = newState()
  S.mapClickCell = { cx = 3, cy = 4 }
  local by = vy + VIEW_H + 8
  Kit.beginFrame(vx + 10, by + 22 + 10, true) -- Set player here
  MapBrowser.draw(S, Kit, px, py)
  eq(S.save.player.map, S.mapId, "Set player here updates player.map")
  eq(S.save.player.x, 3, "Set player here updates player.x")
  eq(S.save.player.y, 4, "Set player here updates player.y")
  check(S.dirty == true, "Set player here marks dirty")
end

do
  local S = newState()
  local by = vy + VIEW_H + 8
  Kit.beginFrame(vx + 10, by + 22 + 10, true) -- Set player here, no cell selected
  MapBrowser.draw(S, Kit, px, py)
  check(S.status:match("Click a cell first"), "Set player here without a selection warns")
end

-- ------------------------------------------------------------- lastOutdoor
do
  local S = newState() -- PALLET_TOWN has connections -> outdoor
  S.mapClickCell = { cx = 5, cy = 6 }
  local by = vy + VIEW_H + 8
  Kit.beginFrame(vx + 150 + 10, by + 22 + 10, true) -- Set lastOutdoor here
  MapBrowser.draw(S, Kit, px, py)
  check(S.save.lastOutdoor ~= nil, "Set lastOutdoor here sets lastOutdoor")
  if S.save.lastOutdoor then
    eq(S.save.lastOutdoor.id, "PALLET_TOWN", "lastOutdoor.id")
    eq(S.save.lastOutdoor.x, 5, "lastOutdoor.x")
    eq(S.save.lastOutdoor.y, 6, "lastOutdoor.y")
  end
end

do
  -- an interior with no connections and not in save.visited -> rejected
  local S = newState()
  S.mapId = "REDS_HOUSE_1F"
  S.mapClickCell = { cx = 1, cy = 1 }
  local by = vy + VIEW_H + 8
  Kit.beginFrame(vx + 150 + 10, by + 22 + 10, true)
  MapBrowser.draw(S, Kit, px, py)
  check(S.save.lastOutdoor == nil, "Set lastOutdoor here refuses a non-outdoor map")
  check(S.status:match("outdoor"), "status explains the refusal")
end

-- ---------------------------------------------------------------- lastHeal
do
  local S = newState()
  S.mapClickCell = { cx = 2, cy = 8 }
  local by = vy + VIEW_H + 8
  Kit.beginFrame(vx + 320 + 10, by + 22 + 10, true) -- Set lastHeal here
  MapBrowser.draw(S, Kit, px, py)
  check(S.save.lastHeal ~= nil, "Set lastHeal here sets lastHeal")
  eq(S.save.lastHeal.map, S.mapId, "lastHeal.map")
  eq(S.save.lastHeal.x, 2, "lastHeal.x")
  eq(S.save.lastHeal.y, 8, "lastHeal.y")
end

-- --------------------------------------------------------------- warp jump
do
  local S = newState()
  S.mapId = "PALLET_TOWN"
  local map = require("src.world.MapLoader").load(Data, "PALLET_TOWN")
  check(#map.def.warps > 0, "Pallet Town has warps to test with")
  local w = map.def.warps[1]

  local mx = vx + w.x * 16 * S.mapZoom + 4
  local my = vy + w.y * 16 * S.mapZoom + 4
  Kit.beginFrame(mx, my, true)
  MapBrowser.draw(S, Kit, px, py)
  check(S.mapId ~= "PALLET_TOWN" or w.destMap == "PALLET_TOWN",
    "clicking a warp cell jumps S.mapId to its destination")
  check(S.status:match("Followed warp"), "warp click sets a status message")
end

do
  -- LAST_MAP warp with no remembered outdoor map must not crash, and
  -- must not silently move the view.
  local S = newState()
  S.mapId = "REDS_HOUSE_1F"
  local MapLoader = require("src.world.MapLoader")
  local map = MapLoader.load(Data, "REDS_HOUSE_1F")
  local lastMapWarp
  for _, w in ipairs(map.def.warps) do
    if w.destMap == "LAST_MAP" then lastMapWarp = w end
  end
  if lastMapWarp then
    S.save.lastOutdoor = nil
    local mx = vx + lastMapWarp.x * 16 * S.mapZoom + 4
    local my = vy + lastMapWarp.y * 16 * S.mapZoom + 4
    Kit.beginFrame(mx, my, true)
    local ok = pcall(MapBrowser.draw, S, Kit, px, py)
    check(ok, "LAST_MAP warp with no lastOutdoor doesn't crash")
    eq(S.mapId, "REDS_HOUSE_1F", "LAST_MAP warp with no lastOutdoor doesn't move the view")
    check(S.status:match("lastOutdoor"), "status explains the skipped warp")
  else
    check(true, "REDS_HOUSE_1F has no LAST_MAP warp to test (skipped)")
  end
end

do
  -- Indigo Plateau uses tileset PLATEAU -> plateau.png (not indigo.png).
  -- Following its lobby door must remember lastOutdoor so the lobby's
  -- LAST_MAP mats return here (same as the game's outsideTilesets).
  local S = newState()
  S.mapId = "INDIGO_PLATEAU"
  S.save.lastOutdoor = { id = "ROUTE_22", x = 8, y = 5 }
  local MapLoader = require("src.world.MapLoader")
  local indigo = MapLoader.load(Data, "INDIGO_PLATEAU")
  eq(indigo.tileset.image, "assets/generated/tilesets/plateau.png",
     "Indigo Plateau tileset image is plateau.png")
  local door = indigo.def.warps[1]
  local mx = vx + door.x * 16 * S.mapZoom + 4
  local my = vy + door.y * 16 * S.mapZoom + 4
  Kit.beginFrame(mx, my, true)
  MapBrowser.draw(S, Kit, px, py)
  eq(S.mapId, "INDIGO_PLATEAU_LOBBY", "Indigo door warp jumps to the lobby")
  check(S.save.lastOutdoor and S.save.lastOutdoor.id == "INDIGO_PLATEAU",
        "following Indigo door remembers lastOutdoor as INDIGO_PLATEAU")

  local lobby = MapLoader.load(Data, "INDIGO_PLATEAU_LOBBY")
  local exitWarp
  for _, w in ipairs(lobby.def.warps) do
    if w.destMap == "LAST_MAP" then exitWarp = w break end
  end
  check(exitWarp ~= nil, "Indigo lobby has a LAST_MAP exit")
  -- re-zero the camera so the exit-cell click math matches cellAtScreen
  S.mapCamX, S.mapCamY = 0, 0
  mx = vx + exitWarp.x * 16 * S.mapZoom + 4
  my = vy + exitWarp.y * 16 * S.mapZoom + 4
  Kit.beginFrame(mx, my, true)
  MapBrowser.draw(S, Kit, px, py)
  eq(S.mapId, "INDIGO_PLATEAU", "Indigo lobby LAST_MAP exit returns to the plateau")
end

-- --------------------------------------------------------- zoom / pan input
do
  local S = newState()
  local z0 = S.mapZoom
  MapBrowser.wheelmoved(S, 1)
  check(S.mapZoom > z0, "wheelmoved(+) zooms in")
  MapBrowser.wheelmoved(S, -1)
  MapBrowser.wheelmoved(S, -1)
  check(S.mapZoom < z0, "wheelmoved(-) zooms out")

  S.mapZoom = 1
  for _ = 1, 20 do MapBrowser.wheelmoved(S, -1) end
  check(S.mapZoom >= 1, "zoom clamps at a minimum")
end

do
  local S = newState()
  S.mapCamX, S.mapCamY = 0, 0
  MapBrowser.keypressed(S, "d")
  eq(S.mapCamX, 16, "keypressed d pans camera right by one cell")
  MapBrowser.keypressed(S, "down")
  eq(S.mapCamY, 16, "keypressed down pans camera down by one cell")
  MapBrowser.keypressed(S, "unrelatedkey")
  eq(S.mapCamX, 16, "unrelated keys don't pan the camera")
end

print(string.format("save editor task 8 tests: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
