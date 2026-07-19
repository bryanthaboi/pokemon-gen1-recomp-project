-- Parity test,  Workstream C.
-- Self-contained: run via `luajit tests/parity_C.lua`; also dofile'd by
-- tests/run_tests.lua's aggregator.
--
-- Oracle: pokered/engine/events/elevator.asm (DisplayElevatorFloorMenu),
-- pokered/engine/overworld/elevator.asm (ShakeElevator),
-- pokered/scripts/SilphCoElevator.asm / CeladonMartElevator.asm /
-- RocketHideoutElevator.asm (floor tables), pokered/data/items/names.asm
-- (short FLOOR_* tokens).
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end
local S = require("tests.harness").suite("parity C")
local check, eq = S.check, S.eq

-- empty a table in place (rebinding the local wouldn't reach closures
-- that already captured the original table, e.g. ow.startWarpTo below)
local function clear(t)
  for i = #t, 1, -1 do t[i] = nil end
end

local mapScripts = require("data.scripts.init")
local ListMenu = require("src.ui.ListMenu")
local Sound = require("src.core.Sound")
local Map = require("src.world.Map")
local Warp = require("src.world.Warp")

-- synchronous scriptMove/takeWarp for the walk-out: elevatorWalkOut
-- (data/scripts/story3.lua) rewrites the car's exit warps then walks the
-- player out through the doorway and takes the rewritten warp, instead of
-- the old jump-cut startWarpTo.
local DIRVEC = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }

-- the Rocket Hideout keyGate path pushes a TextBox, which needs the font
-- loaded (like tests/run_tests.lua does before any TextBox use)
local Font = require("src.render.Font")
Font.load(Data)

-- spy on Sound.play so we can see the arrival-SFX beat without real audio
local sfxCalls
local origSoundPlay = Sound.play
Sound.play = function(data, name)
  sfxCalls[#sfxCalls + 1] = name
  return origSoundPlay(data, name)
end

-- fake StateStack: just enough for ListMenu:close()/onCancel's game.stack use
local function newStack()
  local items = {}
  local stack = {}
  function stack:push(item) items[#items + 1] = item end
  function stack:pop() items[#items] = nil end
  function stack:top() return items[#items] end
  return stack, items
end

-- drives one elevator map's onEnter and returns the pushed state (either a
-- ListMenu or, for the keyGated Rocket Hideout without the key, a TextBox)
local function openElevator(mapId, inventory)
  local script = mapScripts.get(mapId)
  check(script ~= nil, mapId .. " script registered")
  check(script and script.onEnter ~= nil, mapId .. " has onEnter")
  local stack, items = newStack()
  local warpCalls = {}
  local ow = {}
  -- the real elevator car map (built without the tile renderer -- Map.new
  -- is pure data), plus the player standing on the exit tile they warped
  -- in onto (the true arrival cell), so the post-ride walk-out has a
  -- door and geometry to work with
  local carDef = Data.maps[mapId]
  ow.map = Map.new(carDef, Data.tilesets[carDef.tileset])
  local firstWarp = carDef.warps[1]
  ow.player = { cellX = firstWarp.x, cellY = firstWarp.y, facing = "up" }
  ow.scriptMoves = {}
  ow.walkSteps = {}
  function ow:startWarpTo(map, x, y, facing)
    warpCalls[#warpCalls + 1] = { map = map, x = x, y = y, facing = facing }
  end
  -- synchronous: advance the entity one step per tile and fire onDone
  function ow:scriptMove(entity, dir, tiles, onDone)
    local d = DIRVEC[dir]
    entity.cellX = entity.cellX + d[1] * tiles
    entity.cellY = entity.cellY + d[2] * tiles
    entity.facing = dir
    self.walkSteps[#self.walkSteps + 1] = dir
    if onDone then onDone() end
  end
  -- resolve the (rewritten) warp entry like OverworldState:takeWarp does
  function ow:takeWarp(warpDef)
    local destMap, x, y = Warp.destination(Data, warpDef, self.lastOutdoor)
    warpCalls[#warpCalls + 1] =
      { map = destMap, x = x, y = y, facing = self.player.facing }
  end
  local game = {
    data = Data,
    save = { inventory = inventory or {}, player = { name = "RED", rival = "BLUE" } },
    stack = stack,
  }
  sfxCalls = {}
  script.onEnter(game, ow)
  return items[#items], warpCalls, stack, ow
end

-- step the ElevatorShake state (pokered ShakeElevator) frame by frame
-- until it pops itself; returns how many frames the ride took plus the
-- observed scroll-offset trace (first nonzero frame/value, both signs
-- seen).  Headless the SFX_SAFARI_ZONE_PA source never sounds, so the
-- .musicLoop wait resolves on the frame after the 100 cycles.
local function rideOut(stack, shake, ow)
  local steps, firstFrame, firstOffset = 0, nil, nil
  local sawUp, sawDown = false, false
  while stack:top() == shake and steps < 400 do
    shake:update(1 / 60)
    steps = steps + 1
    local o = ow.bgShakeY or 0
    if o ~= 0 and not firstFrame then firstFrame, firstOffset = steps, o end
    if o > 0 then sawUp = true elseif o < 0 then sawDown = true end
  end
  return steps, firstFrame, firstOffset, sawUp and sawDown
end

local function countSfx(name)
  local n = 0
  for _, s in ipairs(sfxCalls) do if s == name then n = n + 1 end end
  return n
end

-- ===================================================================
-- Silph Co elevator: 11 floors, the double-digit sort/label regression
-- ===================================================================
do
  local menu, warpCalls, stack, ow = openElevator("SILPH_CO_ELEVATOR")
  check(menu ~= nil and getmetatable(menu) == ListMenu, "SILPH_CO_ELEVATOR opens a ListMenu")
  if menu then
    eq(#menu.items, 11, "Silph Co elevator lists all 11 floors")
    local wantOrder = { "1F", "2F", "3F", "4F", "5F", "6F", "7F", "8F", "9F", "10F", "11F" }
    for i, want in ipairs(wantOrder) do
      local item = menu.items[i]
      eq(item and item.label, want, "Silph Co floor " .. i .. " label/order")
    end
    -- labels are short floor tokens, never the full source map id
    check(menu.items[1].label ~= "SILPH CO 1F" and not menu.items[1].label:find("SILPH"),
          "Silph Co floor label is the short token, not the full map id")

    -- Cancel: pokered's DisplayElevatorFloorMenu does `ret c` on B --
    -- no warp at all.
    clear(warpCalls)
    menu.onCancel()
    eq(#warpCalls, 0, "Cancel does not warp (bare ret c, no floors[1] fallback)")

    -- Choose a mid-list floor (5F): pokered never warps on the spot --
    -- DisplayElevatorFloorMenu sets BIT_CUR_MAP_USED_ELEVATOR and the
    -- map script runs ShakeElevator: a 12-frame lead-in (the script's
    -- Delay3 + ShakeElevator's own 9 frames of Delay3s), then 100
    -- two-frame cycles of hSCY bouncing -1/+1 with SFX_COLLISION each
    -- cycle, then SFX_SAFARI_ZONE_PA, and only then the floor warp.
    clear(warpCalls)
    sfxCalls = {}
    local chosen = menu.items[5] -- "5F"
    menu.onChoose(chosen, menu)
    eq(#warpCalls, 0, "choosing a floor does not warp on the spot (the shake runs first)")
    local shake = stack:top()
    check(shake ~= nil and getmetatable(shake) ~= ListMenu and shake.update ~= nil,
          "choosing a floor pushes the ElevatorShake state")
    local steps, firstFrame, firstOffset, bothWays = rideOut(stack, shake, ow)
    eq(steps, 12 + 200 + 1, "Silph ride: 12 lead-in frames + 100 2-frame cycles + PA poll")
    eq(firstFrame, 13, "first scroll write lands right after the 12-frame lead-in")
    eq(firstOffset, -1, "first hSCY offset is -1 (ld e, $1 then xor $fe)")
    check(bothWays, "the scroll oscillates both ways (-1/+1)")
    eq(ow.bgShakeY, 0, "hSCY restored to rest after the ride")
    eq(countSfx("Collision"), 100, "SFX_COLLISION plays once per shake cycle (ld b, 100)")
    eq(countSfx("Safari_Zone_PA"), 1, "SFX_SAFARI_ZONE_PA plays once")
    eq(sfxCalls[#sfxCalls], "Safari_Zone_PA", "SFX_SAFARI_ZONE_PA caps the ride")
    -- .UpdateWarp rewrites the car's exit warp entries to the chosen
    -- floor, then the player walks out onto that warp (no jump cut)
    eq(ow.map.def.warps[1].destMap, chosen.value.map,
       "the car's exit warp is rewritten to the chosen floor's map")
    check(#ow.walkSteps >= 1, "the player walks out of the car (scriptMove, not a jump-cut)")
    eq(#warpCalls, 1, "the rewritten warp fires exactly once, after the walk-out")
    if warpCalls[1] then
      eq(warpCalls[1].map, chosen.value.map, "walk-out lands on the chosen floor's map")
      eq(warpCalls[1].x, chosen.value.x, "walk-out lands on the chosen floor's x")
      eq(warpCalls[1].y, chosen.value.y, "walk-out lands on the chosen floor's y")
    end
  end
end

-- ===================================================================
-- Celadon Mart elevator: 5 floors, single-digit control (should already
-- have passed lexicographically -- non-regression check)
-- ===================================================================
do
  local menu, warpCalls, stack, ow = openElevator("CELADON_MART_ELEVATOR")
  check(menu ~= nil and getmetatable(menu) == ListMenu, "CELADON_MART_ELEVATOR opens a ListMenu")
  if menu then
    eq(#menu.items, 5, "Celadon Mart elevator lists all 5 floors")
    local wantOrder = { "1F", "2F", "3F", "4F", "5F" }
    for i, want in ipairs(wantOrder) do
      eq(menu.items[i] and menu.items[i].label, want, "Celadon Mart floor " .. i .. " label/order")
    end

    clear(warpCalls)
    menu.onCancel()
    eq(#warpCalls, 0, "Celadon Mart cancel does not warp")

    -- CeladonMartElevatorShakeScript farjps straight into ShakeElevator:
    -- no extra Delay3, so the lead-in is only ShakeElevator's own 9 frames
    clear(warpCalls)
    sfxCalls = {}
    local chosen = menu.items[3] -- "3F"
    menu.onChoose(chosen, menu)
    eq(#warpCalls, 0, "Celadon Mart choose does not warp on the spot")
    local shake = stack:top()
    local steps, firstFrame = rideOut(stack, shake, ow)
    eq(steps, 9 + 200 + 1, "Celadon ride: 9 lead-in frames (farjp, no extra Delay3) + shake + PA poll")
    eq(firstFrame, 10, "Celadon first scroll write follows the 9-frame lead-in")
    eq(countSfx("Collision"), 100, "Celadon Mart shake thuds 100 times")
    eq(sfxCalls[#sfxCalls], "Safari_Zone_PA", "Celadon Mart ride ends on the PA chime")
    eq(ow.map.def.warps[1].destMap, chosen.value.map,
       "Celadon Mart car exit warp rewritten to the chosen floor")
    check(#ow.walkSteps >= 1, "Celadon Mart player walks out (scriptMove, not a jump-cut)")
    eq(#warpCalls, 1, "Celadon Mart rewritten warp fires once, after the walk-out")
    if warpCalls[1] then
      eq(warpCalls[1].map, chosen.value.map, "Celadon Mart walk-out lands on the chosen floor map")
      eq(warpCalls[1].x, chosen.value.x, "Celadon Mart walk-out lands on the chosen floor x")
      eq(warpCalls[1].y, chosen.value.y, "Celadon Mart walk-out lands on the chosen floor y")
    end
  end
end

-- ===================================================================
-- Rocket Hideout elevator: B1F/B2F/B4F ordering (numeric-not-lexical on
-- the digit only), plus the LIFT_KEY gate.
-- ===================================================================
do
  -- without the key: text-only, no floor menu
  local gated = openElevator("ROCKET_HIDEOUT_ELEVATOR", {})
  check(gated ~= nil, "Rocket Hideout without LIFT_KEY still pushes something")
  check(gated ~= nil and getmetatable(gated) ~= ListMenu,
        "Rocket Hideout without LIFT_KEY does not open the floor menu")

  -- with the key: full B1F/B2F/B4F menu, same as the other elevators
  local menu, warpCalls, stack, ow = openElevator("ROCKET_HIDEOUT_ELEVATOR", { LIFT_KEY = 1 })
  check(menu ~= nil and getmetatable(menu) == ListMenu,
        "Rocket Hideout with LIFT_KEY opens a ListMenu")
  if menu then
    eq(#menu.items, 3, "Rocket Hideout elevator lists all 3 floors")
    local wantOrder = { "B1F", "B2F", "B4F" }
    for i, want in ipairs(wantOrder) do
      eq(menu.items[i] and menu.items[i].label, want, "Rocket Hideout floor " .. i .. " label/order")
    end

    clear(warpCalls)
    menu.onCancel()
    eq(#warpCalls, 0, "Rocket Hideout cancel does not warp")

    -- RocketHideoutElevatorShakeScript is `call Delay3 / farcall
    -- ShakeElevator` like Silph's: 12 lead-in frames
    clear(warpCalls)
    sfxCalls = {}
    local chosen = menu.items[2] -- "B2F"
    menu.onChoose(chosen, menu)
    eq(#warpCalls, 0, "Rocket Hideout choose does not warp on the spot")
    local shake = stack:top()
    local steps = rideOut(stack, shake, ow)
    eq(steps, 12 + 200 + 1, "Rocket Hideout ride: 12 lead-in frames + shake + PA poll")
    eq(countSfx("Collision"), 100, "Rocket Hideout shake thuds 100 times")
    eq(sfxCalls[#sfxCalls], "Safari_Zone_PA", "Rocket Hideout ride ends on the PA chime")
    eq(ow.map.def.warps[1].destMap, chosen.value.map,
       "Rocket Hideout car exit warp rewritten to the chosen floor")
    check(#ow.walkSteps >= 1, "Rocket Hideout player walks out (scriptMove, not a jump-cut)")
    eq(#warpCalls, 1, "Rocket Hideout rewritten warp fires once, after the walk-out")
    if warpCalls[1] then
      eq(warpCalls[1].map, chosen.value.map, "Rocket Hideout walk-out lands on the chosen floor map")
      eq(warpCalls[1].x, chosen.value.x, "Rocket Hideout walk-out lands on the chosen floor x")
      eq(warpCalls[1].y, chosen.value.y, "Rocket Hideout walk-out lands on the chosen floor y")
    end
  end
end

Sound.play = origSoundPlay

S.finish()
