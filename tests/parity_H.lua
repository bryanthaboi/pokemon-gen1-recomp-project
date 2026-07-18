-- Parity test,  Workstream H.
-- Covers: Seafoam B2F boulder cascade. field.py now parses
-- scripts/SeafoamIslands1F.asm / SeafoamIslandsB1F.asm the same way it
-- already parsed B2F/B3F/B4F, wiring SEAFOAM_ISLANDS_1F.holes ->
-- SEAFOAM_ISLANDS_B1F and SEAFOAM_ISLANDS_B1F.holes -> SEAFOAM_ISLANDS_B2F.
-- data/scripts/seafoam.lua's onEnter hack that force-showed the B2F
-- boulders is gone; the generic OverworldState:boulderIntoHole (driven by
-- this data) now reveals every floor's plug boulders only once the
-- boulder above them actually falls through its hole.
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end
local fails, total = 0, 0
local function check(c, m) total = total + 1; if c then print("ok   " .. m) else fails = fails + 1; print("FAIL " .. m) end end
local function eq(g, w, m) check(g == w, ("%s (got %s, want %s)"):format(m, tostring(g), tostring(w))) end

-- === (1) static extraction assertions ===
local sf = Data.field.seafoam
check(sf.SEAFOAM_ISLANDS_1F ~= nil, "field.seafoam has a SEAFOAM_ISLANDS_1F entry")
check(sf.SEAFOAM_ISLANDS_B1F ~= nil, "field.seafoam has a SEAFOAM_ISLANDS_B1F entry")
if sf.SEAFOAM_ISLANDS_1F then
  eq(#sf.SEAFOAM_ISLANDS_1F.holes, 2, "SEAFOAM_ISLANDS_1F has 2 holes")
  eq(sf.SEAFOAM_ISLANDS_1F.holeDestination, "SEAFOAM_ISLANDS_B1F",
     "SEAFOAM_ISLANDS_1F holes drop to B1F")
  local h1 = sf.SEAFOAM_ISLANDS_1F.holes[1]
  eq(h1.boulderEvent, "EVENT_SEAFOAM1_BOULDER1_DOWN_HOLE", "1F hole 1 boulder event")
  eq(h1.hideObject, "TOGGLE_SEAFOAM_ISLANDS_1F_BOULDER_1", "1F hole 1 hides 1F boulder 1")
  eq(h1.showObject, "TOGGLE_SEAFOAM_ISLANDS_B1F_BOULDER_1", "1F hole 1 shows B1F boulder 1")
end
if sf.SEAFOAM_ISLANDS_B1F then
  eq(#sf.SEAFOAM_ISLANDS_B1F.holes, 2, "SEAFOAM_ISLANDS_B1F has 2 holes")
  eq(sf.SEAFOAM_ISLANDS_B1F.holeDestination, "SEAFOAM_ISLANDS_B2F",
     "SEAFOAM_ISLANDS_B1F holes drop to B2F")
  local h1 = sf.SEAFOAM_ISLANDS_B1F.holes[1]
  eq(h1.boulderEvent, "EVENT_SEAFOAM2_BOULDER1_DOWN_HOLE", "B1F hole 1 boulder event")
  eq(h1.hideObject, "TOGGLE_SEAFOAM_ISLANDS_B1F_BOULDER_1", "B1F hole 1 hides B1F boulder 1")
  eq(h1.showObject, "TOGGLE_SEAFOAM_ISLANDS_B2F_BOULDER_1", "B1F hole 1 shows B2F boulder 1")
end
-- the pre-existing B3F edge (already ported) must be untouched
check(sf.SEAFOAM_ISLANDS_B3F and #sf.SEAFOAM_ISLANDS_B3F.holes == 2,
      "SEAFOAM_ISLANDS_B3F still has its own 2 holes (B3F->B4F, unrelated to this change)")

-- data/scripts/seafoam.lua no longer force-shows the B2F boulders on entry
local seafoamScripts = require("data.scripts.seafoam")
check(seafoamScripts.SEAFOAM_ISLANDS_B2F == nil,
      "data/scripts/seafoam.lua no longer hardcodes a SEAFOAM_ISLANDS_B2F onEnter hook")

-- === (2) functional 1F -> B1F -> B2F -> B3F -> B4F cascade ===
require("src.render.Font").load(Data)
local Game = require("src.core.Game")
local Input = require("src.core.Input")
local StateStack = require("src.core.StateStack")
local Renderer = require("src.render.Renderer")
local SaveData = require("src.core.SaveData")
local OW = require("src.world.OverworldController")

Game.data = Data
Game.input = Input; Input:init()
Game.renderer = Renderer; Renderer:init()
Game.stack = StateStack
StateStack:init()
Game.save = SaveData.newGame()
Game.save.flags = {}
Game.save.objectToggles = nil

local function objOf(mapId, name)
  for _, o in ipairs(Data.maps[mapId].objects) do
    if o.name == name then return o end
  end
end

while Game.stack:top() do Game.stack:pop() end
Game.stack:push(OW, "SEAFOAM_ISLANDS_1F", 1, 1, "down")
local ow = Game.stack:top()
check(ow ~= nil and ow.map ~= nil and ow.map.id == "SEAFOAM_ISLANDS_1F",
      "pushed OverworldController headlessly onto SEAFOAM_ISLANDS_1F")

-- baseline: 1F boulders start visible (toggle ON), B1F/B2F ones start
-- hidden (data/maps/toggleable_objects.asm:398-409) since nothing has
-- fallen through a hole yet
check(OW.objectVisible(Game.save, "SEAFOAM_ISLANDS_1F",
                       objOf("SEAFOAM_ISLANDS_1F", "SEAFOAMISLANDS1F_BOULDER1")),
      "1F boulder 1 starts visible")
check(OW.objectVisible(Game.save, "SEAFOAM_ISLANDS_1F",
                       objOf("SEAFOAM_ISLANDS_1F", "SEAFOAMISLANDS1F_BOULDER2")),
      "1F boulder 2 starts visible")
for _, name in ipairs({ "SEAFOAMISLANDSB1F_BOULDER1", "SEAFOAMISLANDSB1F_BOULDER2" }) do
  check(not OW.objectVisible(Game.save, "SEAFOAM_ISLANDS_B1F", objOf("SEAFOAM_ISLANDS_B1F", name)),
        "B1F " .. name .. " starts hidden")
end
for _, name in ipairs({ "SEAFOAMISLANDSB2F_BOULDER1", "SEAFOAMISLANDSB2F_BOULDER2" }) do
  check(not OW.objectVisible(Game.save, "SEAFOAM_ISLANDS_B2F", objOf("SEAFOAM_ISLANDS_B2F", name)),
        "B2F " .. name .. " starts hidden")
end

-- Fall order, top to bottom. Each entry pushes a synthesized boulder npc
-- onto a hole cell and checks the hide/show/event side effects.  The
-- destMap/name pairs and hole coords come from the oracle refs (see the
-- workstream H spec): SeafoamIslands1F.asm/SeafoamIslandsB1F.asm (the new
-- wiring) and the pre-existing SeafoamIslandsB2F.asm/B3F.asm (already
-- ported, kept here as a regression check of the full chain).
--
-- Note: the B2F -> B3F leg's *destination* visibility (steps 5-6 below)
-- is a known pre-existing gap unrelated to this workstream: B3F's
-- toggleable_objects.asm ordinal skips BOULDER1/BOULDER4, so
-- TOGGLE_SEAFOAM_ISLANDS_B3F_BOULDER_3/4 (which should land on
-- SEAFOAMISLANDSB3F_BOULDER5/6) resolve through
-- OverworldController.lua's toggleToObjectName() to the wrong (already-
-- visible) BOULDER3/4 instead. That resolver lives outside this
-- workstream's port targets, so only the event flag + source-hide (both
-- correct today) are asserted for that leg; the cosmetic destination
-- reveal is left as-is.
local pushes = {
  { curMap = "SEAFOAM_ISLANDS_1F", hx = 17, hy = 6,
    event = "EVENT_SEAFOAM1_BOULDER1_DOWN_HOLE",
    srcMap = "SEAFOAM_ISLANDS_1F", srcName = "SEAFOAMISLANDS1F_BOULDER1",
    dstMap = "SEAFOAM_ISLANDS_B1F", dstName = "SEAFOAMISLANDSB1F_BOULDER1",
    checkDst = true },
  { curMap = "SEAFOAM_ISLANDS_1F", hx = 24, hy = 6,
    event = "EVENT_SEAFOAM1_BOULDER2_DOWN_HOLE",
    srcMap = "SEAFOAM_ISLANDS_1F", srcName = "SEAFOAMISLANDS1F_BOULDER2",
    dstMap = "SEAFOAM_ISLANDS_B1F", dstName = "SEAFOAMISLANDSB1F_BOULDER2",
    checkDst = true },
  { curMap = "SEAFOAM_ISLANDS_B1F", hx = 18, hy = 6,
    event = "EVENT_SEAFOAM2_BOULDER1_DOWN_HOLE",
    srcMap = "SEAFOAM_ISLANDS_B1F", srcName = "SEAFOAMISLANDSB1F_BOULDER1",
    dstMap = "SEAFOAM_ISLANDS_B2F", dstName = "SEAFOAMISLANDSB2F_BOULDER1",
    checkDst = true },
  { curMap = "SEAFOAM_ISLANDS_B1F", hx = 23, hy = 6,
    event = "EVENT_SEAFOAM2_BOULDER2_DOWN_HOLE",
    srcMap = "SEAFOAM_ISLANDS_B1F", srcName = "SEAFOAMISLANDSB1F_BOULDER2",
    dstMap = "SEAFOAM_ISLANDS_B2F", dstName = "SEAFOAMISLANDSB2F_BOULDER2",
    checkDst = true },
  { curMap = "SEAFOAM_ISLANDS_B2F", hx = 19, hy = 6,
    event = "EVENT_SEAFOAM3_BOULDER1_DOWN_HOLE",
    srcMap = "SEAFOAM_ISLANDS_B2F", srcName = "SEAFOAMISLANDSB2F_BOULDER1",
    dstMap = "SEAFOAM_ISLANDS_B3F", dstName = "SEAFOAMISLANDSB3F_BOULDER5",
    checkDst = false },
  { curMap = "SEAFOAM_ISLANDS_B2F", hx = 22, hy = 6,
    event = "EVENT_SEAFOAM3_BOULDER2_DOWN_HOLE",
    srcMap = "SEAFOAM_ISLANDS_B2F", srcName = "SEAFOAMISLANDSB2F_BOULDER2",
    dstMap = "SEAFOAM_ISLANDS_B3F", dstName = "SEAFOAMISLANDSB3F_BOULDER6",
    checkDst = false },
  { curMap = "SEAFOAM_ISLANDS_B3F", hx = 3, hy = 16,
    event = "EVENT_SEAFOAM4_BOULDER1_DOWN_HOLE",
    srcMap = "SEAFOAM_ISLANDS_B3F", srcName = "SEAFOAMISLANDSB3F_BOULDER1",
    dstMap = "SEAFOAM_ISLANDS_B4F", dstName = "SEAFOAMISLANDSB4F_BOULDER1",
    checkDst = true },
  { curMap = "SEAFOAM_ISLANDS_B3F", hx = 6, hy = 16,
    event = "EVENT_SEAFOAM4_BOULDER2_DOWN_HOLE",
    srcMap = "SEAFOAM_ISLANDS_B3F", srcName = "SEAFOAMISLANDSB3F_BOULDER2",
    dstMap = "SEAFOAM_ISLANDS_B4F", dstName = "SEAFOAMISLANDSB4F_BOULDER2",
    checkDst = true },
}

for i, p in ipairs(pushes) do
  if ow.map.id ~= p.curMap then
    ow:setMap(p.curMap, 1, 1, "down")
  end
  local npc = { cellX = p.hx, cellY = p.hy, def = { name = p.srcName } }
  table.insert(ow.npcs, npc)
  table.insert(ow.entities, npc)
  local ok = ow:boulderIntoHole(npc)
  check(ok, ("push %d: boulderIntoHole(%s) returns true"):format(i, p.srcName))
  check(Game.save.flags[p.event] == true,
        ("push %d: %s is set"):format(i, p.event))
  check(not OW.objectVisible(Game.save, p.srcMap, objOf(p.srcMap, p.srcName)),
        ("push %d: source %s is now hidden"):format(i, p.srcName))
  if p.checkDst then
    check(OW.objectVisible(Game.save, p.dstMap, objOf(p.dstMap, p.dstName)),
          ("push %d: destination %s is now visible"):format(i, p.dstName))
  end
end

-- === end state: the known plug/current end state, now reached via the
-- full 1F -> B4F chain instead of starting mid-way at B2F ===
check(Game.save.flags.EVENT_SEAFOAM3_BOULDER1_DOWN_HOLE == true
      and Game.save.flags.EVENT_SEAFOAM3_BOULDER2_DOWN_HOLE == true,
      "both EVENT_SEAFOAM3_BOULDER{1,2}_DOWN_HOLE are set")
check(Game.save.flags.EVENT_SEAFOAM4_BOULDER1_DOWN_HOLE == true
      and Game.save.flags.EVENT_SEAFOAM4_BOULDER2_DOWN_HOLE == true,
      "both EVENT_SEAFOAM4_BOULDER{1,2}_DOWN_HOLE are set")
check(OW.objectVisible(Game.save, "SEAFOAM_ISLANDS_B4F",
                       objOf("SEAFOAM_ISLANDS_B4F", "SEAFOAMISLANDSB4F_BOULDER1")),
      "SEAFOAMISLANDSB4F_BOULDER1 is visible at the end state")
check(OW.objectVisible(Game.save, "SEAFOAM_ISLANDS_B4F",
                       objOf("SEAFOAM_ISLANDS_B4F", "SEAFOAMISLANDSB4F_BOULDER2")),
      "SEAFOAMISLANDSB4F_BOULDER2 is visible at the end state")

print(("parity H: %d/%d passed"):format(total - fails, total))
if fails > 0 then error(fails .. " parity-H assertion(s) failed") end
