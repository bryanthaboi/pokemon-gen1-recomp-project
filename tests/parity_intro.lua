-- Parity test,  the Pallet Town intro cutscene (Oak escort) and the
-- Oak-speech shrink assets.
-- Self-contained: run via `luajit tests/parity_intro.lua`; also dofile'd
-- by tests/run_tests.lua's aggregator.
--
-- Sources: scripts/PalletTown.asm, engine/overworld/auto_movement.asm
-- (PalletMovementScriptPointerTable, RLEList_ProfOakWalkToLab,
-- RLEList_PlayerWalkToLab), engine/overworld/pathfinding.asm
-- (FindPathToPlayer), engine/movie/oak_speech/oak_speech.asm.
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end
local fails, total = 0, 0
local function check(c, m) total = total + 1; if c then print("ok   " .. m) else fails = fails + 1; print("FAIL " .. m) end end
local function eq(g, w, m) check(g == w, ("%s (got %s, want %s)"):format(m, tostring(g), tostring(w))) end

local mapScripts = require("data.scripts.init")
local pallet = mapScripts.get("PALLET_TOWN")
check(pallet and pallet.escort, "PALLET_TOWN exposes the escort tables")
local escort = pallet.escort

local function joined(t) return table.concat(t, ",") end

-- =====================================================================
-- (A) Oak's walk to the player: FindPathToPlayer from his object spot
-- (8,5) to one tile below the player (hNPCPlayerYDistance decremented
-- before the predef).  Reducing the greater remaining axis each step
-- (ties go to X) yields a strict zigzag.
-- =====================================================================
eq(joined(escort.oakApproach(10)), "up,right,up,right,up",
   "Oak approach to the left tile (player at 10,1)")
eq(joined(escort.oakApproach(11)), "right,up,right,up,right,up",
   "Oak approach to the right tile (player at 11,1)")

-- walking the approach from (8,5) must land exactly on (playerX, 2)
for _, px in ipairs({ 10, 11 }) do
  local cx, cy = 8, 5
  local D = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }
  for _, dir in ipairs(escort.oakApproach(px)) do
    cx, cy = cx + D[dir][1], cy + D[dir][2]
  end
  check(cx == px and cy == 2,
        ("Oak's approach ends below the player at (%d,2)"):format(px))
end

-- =====================================================================
-- (B) The escort to the lab.  Oak: RLEList_ProfOakWalkToLab = DOWN x5,
-- LEFT, DOWN x5, RIGHT x3, UP (the NPC_CHANGE_FACING tail is a march-
-- in-place beat, not a step).  Player: RLEList_PlayerWalkToLab plays in
-- reverse buffer order = DOWN x6, LEFT, DOWN x5, RIGHT x3, UP x2, and
-- the last UP is consumed by the door-warp frame -- so the realized
-- player path is Oak's path with one extra leading DOWN.
-- =====================================================================
eq(joined(escort.oakSteps),
   "down,down,down,down,down,left,down,down,down,down,down,right,right,right,up",
   "Oak's walk-to-lab movement (RLEList_ProfOakWalkToLab)")
eq(#escort.oakSteps, 15, "Oak takes 15 steps")
eq(joined(escort.playerSteps),
   "down," ..
   "down,down,down,down,down,left,down,down,down,down,down,right,right,right,up",
   "player's realized walk (RLEList_PlayerWalkToLab reversed, warp eats the 17th press)")
eq(#escort.playerSteps, 16, "player takes 16 real steps")

-- both start one apart and stay in lockstep; both paths end on the lab
-- door at (12,11)
do
  local D = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }
  local ox, oy = 10, 2   -- Oak, below the player on the left tile
  local px, py = 10, 1   -- player
  for i = 1, #escort.playerSteps do
    local od = escort.oakSteps[i]
    if od then ox, oy = ox + D[od][1], oy + D[od][2] end
    local pd = escort.playerSteps[i]
    px, py = px + D[pd][1], py + D[pd][2]
    if i < #escort.playerSteps then
      check(math.abs(ox - px) + math.abs(oy - py) == 1,
            ("beat %d: player stays exactly one tile behind Oak"):format(i))
    end
  end
  check(ox == 12 and oy == 11, "Oak's walk ends on the lab door (12,11)")
  check(px == 12 and py == 11, "player's walk ends on the lab door (12,11)")
end

-- the door tile is the real Pallet lab door and resolves to the lab's
-- second warp, the (5,11) mat the walk-in starts from
local MapLoader = require("src.world.MapLoader")
local Warp = require("src.world.Warp")
local town = MapLoader.load(Data, "PALLET_TOWN")
local w = town:warpAtCell(12, 11)
check(w and w.def.destMap == "OAKS_LAB", "(12,11) is the Oak's Lab door warp")
local dm, dx, dy = Warp.destination(Data, { destMap = "OAKS_LAB", destWarp = 2 })
check(dm == "OAKS_LAB" and dx == 5 and dy == 11,
      "the door warps onto the lab mat at (5,11)")

-- the walk-in cast: door Oak at (5,10), desk Oak at (5,2), both
-- initially hidden; Pallet's Oak object at (8,5), initially hidden
local function obj(mapId, name)
  for _, o in ipairs(Data.maps[mapId].objects) do
    if o.name == name then return o end
  end
end
local oak2 = obj("OAKS_LAB", "OAKSLAB_OAK2")
check(oak2 and oak2.x == 5 and oak2.y == 10 and oak2.hidden and oak2.index == 8,
      "OAKSLAB_OAK2 hides at the door (5,10)")
local oak1 = obj("OAKS_LAB", "OAKSLAB_OAK1")
check(oak1 and oak1.x == 5 and oak1.y == 2 and oak1.hidden and oak1.index == 5,
      "OAKSLAB_OAK1 hides behind the desk (5,2)")
local poak = obj("PALLET_TOWN", "PALLETTOWN_OAK")
check(poak and poak.x == 8 and poak.y == 5 and poak.hidden and poak.index == 1,
      "PALLETTOWN_OAK hides at (8,5)")

-- =====================================================================
-- (C) Oak speech shrink: the extracted ShrinkPic1/ShrinkPic2 manifest
-- and the sounds/music the sequence uses.
-- =====================================================================
local oakGfx = Data.field.oakSpeech
check(oakGfx and oakGfx.shrink1 and oakGfx.shrink2,
      "field.oakSpeech lists both shrink frames")
if oakGfx then
  for _, key in ipairs({ "shrink1", "shrink2" }) do
    local fh = io.open(oakGfx[key], "rb")
    check(fh ~= nil, ("%s exists on disk (%s)"):format(key, tostring(oakGfx[key])))
    if fh then fh:close() end
  end
end
check(Data.audio.sfx and Data.audio.sfx.Shrink ~= nil, "SFX_SHRINK is extracted")
check(Data.audio.songs and Data.audio.songs.Music_Routes2 ~= nil
      and Data.audio.songs.Music_MeetProfOak ~= nil,
      "Routes2 + MeetProfOak songs are extracted")

-- =====================================================================
-- (D) Lab walk-in with UP held: a Delay3 emote queued from Oak's entry
-- onDone must not leave a one-frame handleInput gap, or the held press
-- walks an extra tile and PlayerEntryMovementRLE (up x8) lands on desk
-- Oak at (5,2) instead of (5,3).
-- =====================================================================
do
  local SaveData = require("src.core.SaveData")
  local Game = require("src.core.Game")
  local StateStack = require("src.core.StateStack")
  local OverworldState = require("src.world.OverworldController")
  local Commands = require("src.script.Commands")
  local prev = { data = Game.data, save = Game.save, stack = Game.stack,
                 input = Game.input, renderer = Game.renderer,
                 overworld = Game.overworld }
  Game.data = Data
  Game.save = SaveData.newGame(Data)
  Game.save.player.name = "RED"
  Game.save.objectToggles = { OAKS_LAB = { OAKSLAB_OAK2 = true } }
  StateStack:init()
  Game.stack = StateStack
  Game.input = {
    isDown = function(_, b) return b == "up" end,
    wasPressed = function() return false end,
    step = function() end, state = {}, pressQueue = {},
  }
  Game.renderer = {
    beginWorldPass = function() end, endWorldPass = function() end,
    beginUIPass = function() end, endUIPass = function() end,
    worldViewSize = function() return 160, 144 end,
    setSGBZones = function() end,
  }
  StateStack:push(OverworldState, "OAKS_LAB", 5, 11, "up")
  local ow = OverworldState
  Game.overworld = ow
  local ctx = { save = Game.save, game = Game, overworld = ow }
  local finished = false
  local function swapOaks()
    Commands.hide_object(ctx, "OAKS_LAB", "OAKSLAB_OAK2")
    Commands.show_object(ctx, "OAKS_LAB", "OAKSLAB_OAK1")
    ow.emote = { frames = 3, onDone = function()
      ow:scriptMove(ow.player, "up", 8, function() finished = true end)
    end }
  end
  ow:scriptMove(ow:npcByIndex(8), "up", 3, swapOaks)
  for _ = 1, 600 do
    ow:update(1)
    if finished then break end
  end
  check(finished, "held-UP lab walk-in completes")
  eq(ow.player.cellX, 5, "held-UP walk-in x stays in the aisle")
  eq(ow.player.cellY, 3, "held-UP walk-in ends at (5,3), not on desk Oak")
  local oak1 = ow:npcByIndex(5)
  check(oak1 and not (oak1.cellX == ow.player.cellX and oak1.cellY == ow.player.cellY),
        "player does not stack on desk Oak after walk-in")
  for k, v in pairs(prev) do Game[k] = v end
end

if fails > 0 then error(("parity_intro: %d/%d checks failed"):format(fails, total)) end
print(("parity_intro: %d checks passed"):format(total))
