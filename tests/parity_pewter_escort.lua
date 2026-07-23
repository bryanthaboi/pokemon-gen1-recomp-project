-- Parity test: Pewter City youngster gym escort paths.
-- Self-contained: run via `luajit tests/parity_pewter_escort.lua`; also
-- dofile'd by tests/run_tests.lua's aggregator.
--
-- Sources: scripts/PewterCity.asm, engine/overworld/auto_movement.asm
-- (RLEList_PewterGymPlayer / RLEList_PewterGymGuy),
-- engine/events/pewter_guys.asm (PewterGymGuyCoords).
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PEWTER_CITY) then Data:load() end
local S = require("tests.harness").suite("parity pewter escort")
local check, eq = S.check, S.eq

local mapScripts = require("data.scripts.init")
local pewter = mapScripts.get("PEWTER_CITY")
check(pewter and pewter.escort, "PEWTER_CITY exposes the escort tables")
local escort = pewter.escort

local function joined(t) return table.concat(t, ",") end

local D = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }

eq(#escort.guySteps, 41, "youngster takes 41 steps (RLEList_PewterGymGuy)")
eq(joined({ escort.guySteps[1], escort.guySteps[2], escort.guySteps[#escort.guySteps] }),
   "down,down,right", "guy path starts with DOWN×2 and ends RIGHT")
eq(#escort.guyReturnSteps, 41, "return path mirrors the escort")
do
  local opp = { up = "down", down = "up", left = "right", right = "left" }
  eq(escort.guyReturnSteps[1], opp[escort.guySteps[#escort.guySteps]],
     "return starts with opposite of escort's last step")
  local gx, gy = 12, 18
  for _, d in ipairs(escort.guyReturnSteps) do
    gx, gy = gx + D[d][1], gy + D[d][2]
  end
  check(gx == 35 and gy == 16,
        "return path from the gym lands on his spawn (35,16)")
end

-- every east-exit / talk tile lands both sprites by the gym road
local triggers = { { 35, 17 }, { 36, 17 }, { 37, 18 }, { 37, 19 }, { 34, 16 } }
for _, pos in ipairs(triggers) do
  local px, py = pos[1], pos[2]
  local plan = escort.playerPlan(px, py)
  check(plan, ("playerPlan for (%d,%d)"):format(px, py))
  local gx, gy = 35, 16
  local gi = 0
  for _ = 1, plan.guyHeadStart do
    gi = gi + 1
    local d = escort.guySteps[gi]
    gx, gy = gx + D[d][1], gy + D[d][2]
  end
  for i, ps in ipairs(plan.steps) do
    px, py = px + D[ps][1], py + D[ps][2]
    local gs = escort.guySteps[plan.guyHeadStart + i]
    if gs then
      gx, gy = gx + D[gs][1], gy + D[gs][2]
    end
  end
  eq(px, 11, ("player from (%d,%d) ends at x=11"):format(pos[1], pos[2]))
  eq(py, 18, ("player from (%d,%d) ends at y=18"):format(pos[1], pos[2]))
  eq(gx, 12, ("guy from (%d,%d) ends at x=12"):format(pos[1], pos[2]))
  eq(gy, 18, ("guy from (%d,%d) ends at y=18"):format(pos[1], pos[2]))
end

-- the short east-road trigger uses no head-start; the (36,17)/(37,18)
-- tiles pause for one guy step (eight NO_INPUT frames)
eq(escort.playerPlan(35, 17).guyHeadStart, 0, "(35,17) no head-start")
eq(escort.playerPlan(36, 17).guyHeadStart, 1, "(36,17) one-step head-start")
eq(escort.playerPlan(37, 18).guyHeadStart, 1, "(37,18) one-step head-start")

-- path stays off the PEWTER_GYM door warp and the blocked gym building
-- cells: sample the (35,17) walk and confirm no step lands on (16,17)
do
  local plan = escort.playerPlan(35, 17)
  local px, py = 35, 17
  local gx, gy = 35, 16
  for i, ps in ipairs(plan.steps) do
    px, py = px + D[ps][1], py + D[ps][2]
    local gs = escort.guySteps[i]
    if gs then gx, gy = gx + D[gs][1], gy + D[gs][2] end
    check(not (px == 16 and py == 17),
          ("player beat %d does not phase onto gym door"):format(i))
    check(not (gx == 16 and gy == 17),
          ("guy beat %d does not phase onto gym door"):format(i))
  end
end

-- gym door warp is still where the player is meant to walk afterward
local MapLoader = require("src.world.MapLoader")
local city = MapLoader.load(Data, "PEWTER_CITY")
local w = city:warpAtCell(16, 17)
check(w and w.def.destMap == "PEWTER_GYM", "(16,17) is the Pewter Gym door")

-- object spawn matches pokered object_event 35, 16
local young
for _, o in ipairs(Data.maps.PEWTER_CITY.objects) do
  if o.name == "PEWTERCITY_YOUNGSTER" then young = o; break end
end
check(young and young.x == 35 and young.y == 16,
      "PEWTERCITY_YOUNGSTER spawns at (35,16)")

-- Brock victory permanently HideObject's him (PewterGym.asm .gymVictory)
do
  local victories = require("data.scripts.victories")
  local hide = victories["OPP_BROCK#1"] and victories["OPP_BROCK#1"].hide
  check(hide, "OPP_BROCK#1 lists objects to hide")
  local found
  for _, entry in ipairs(hide or {}) do
    if entry[1] == "PEWTER_CITY" and entry[2] == "PEWTERCITY_YOUNGSTER" then
      found = true
    end
  end
  check(found, "Brock victory hides PEWTERCITY_YOUNGSTER")
end

S.finish()
