-- Parity test,  trainer sight-line walk-up timing.
-- Oracle: home/trainers.asm CheckFightingMapTrainers + CheckForEngagingTrainers,
-- engine/overworld/trainer_sight.asm TrainerEngage/TrainerWalkUpToPlayer,
-- home/overworld.asm OverworldLoop/JoypadOverworld.
--
-- In pokered, map scripts (and thus trainer detection) only run when
-- wWalkCounter == 0 -- i.e. the exact frame the player stands aligned on a
-- tile -- and they run inside JoypadOverworld BEFORE the loop's direction
-- handling.  On detection, CheckFightingMapTrainers zeroes hJoyHeld and sets
-- wJoyIgnore = PAD_CTRL_PAD, so a held direction can never start another
-- step: the player freezes on the tile where they were spotted, the "!"
-- bubble shows (EmotionBubble, 60 frames), then the trainer walks
-- (distance - 1) steps and stops on the adjacent tile (TrainerWalkUpToPlayer
-- returns without a walk script when the pixel gap is exactly $10 = 1 tile).
--
-- The port bug this guards against: on the detection frame, handleInput()
-- still ran (the `scripted` flag ignored self.engaging), so a held direction
-- bought the player one extra step during the "!" pause, landing the trainer
-- walk-up off by a block.
--
-- Scenario map: ROUTE_3.  Object 2 = SPRITE_YOUNGSTER at (10,6), STAY,
-- facing RIGHT, OPP_BUG_CATCHER (data/maps/objects/Route3.asm:22); its
-- header has sight range 2 (scripts/Route3.asm Route3TrainerHeader0).
-- Sight line: (11,6) and (12,6).
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end
local fails, total = 0, 0
local function check(c, m) total = total + 1; if c then print("ok   " .. m) else fails = fails + 1; print("FAIL " .. m) end end
local function eq(g, w, m) check(g == w, ("%s (got %s, want %s)"):format(m, tostring(g), tostring(w))) end

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

local TRAINER_INDEX = 2 -- Route 3 Youngster1, (10,6) facing right, range 2

local function freshOverworld(px, py, facing)
  while Game.stack:top() do Game.stack:pop() end
  Game.save = SaveData.newGame()
  Input:init() -- clear held state between scenarios
  -- OW is a singleton state table (StateStack:push(OW, ...) re-enters the
  -- same instance); in the game an engagement always resolves through the
  -- battle's onDone, but these scenarios abandon it at the text box, so
  -- scrub the in-flight engagement between scenarios
  OW.engaging = false
  OW.emote = nil
  Game.stack:push(OW, "ROUTE_3", px, py, facing)
  local ow = Game.stack:top()
  local trainer
  for _, npc in ipairs(ow.npcs) do
    if npc.def.index == TRAINER_INDEX then trainer = npc end
  end
  return ow, trainer
end

local function frame(ow)
  Input:step()
  ow:update(1 / 60)
end

-- === (1) walk across the sight line with the d-pad held ===
-- Player starts at (13,6) -- one tile OUTSIDE the range-2 line -- facing
-- left, and holds left.  pokered: the step onto (12,6) completes, the very
-- next frame's map script spots the player and kills the held input; the
-- player must never leave (12,6).
do
  local ow, trainer = freshOverworld(13, 6, "left")
  check(trainer ~= nil and trainer.cellX == 10 and trainer.cellY == 6,
        "Route 3 Youngster1 stands at (10,6)")
  eq(trainer.facing, "right", "trainer faces right (STAY RIGHT)")

  -- range boundary: standing at distance 3 with range 2 must not engage
  for _ = 1, 5 do frame(ow) end
  check(not ow.engaging, "distance 3 > range 2: no engagement while standing")

  Input.state.left = true
  -- walk one step onto (12,6); detection fires on the first standing frame
  local guard = 0
  while not ow.engaging and guard < 60 do
    guard = guard + 1
    frame(ow)
  end
  check(ow.engaging, "trainer engages once the player stands at distance 2")
  eq(ow.player.cellX, 12, "detection tile X (spotted on (12,6))")
  eq(ow.player.cellY, 6, "detection tile Y")
  check(not ow.player.moving, "player is tile-aligned when spotted")
  check(ow.emote ~= nil and ow.emote.npc == trainer,
        "the ! bubble shows over the trainer on the detection frame")
  eq(ow.emote and ow.emote.frames, 60,
     "! bubble holds 60 frames (EmotionBubble DelayFrames 60)")

  -- keep holding left through the bubble + walk-up: the input lock
  -- (wJoyIgnore = PAD_CTRL_PAD) means the player never moves again
  local everMoved = false
  guard = 0
  while Game.stack:top() == ow and guard < 400 do
    guard = guard + 1
    frame(ow)
    if ow.player.moving or ow.player.cellX ~= 12 or ow.player.cellY ~= 6 then
      everMoved = true
    end
  end
  check(not everMoved,
        "held d-pad never buys another step after detection (input locked)")
  check(Game.stack:top() ~= ow, "engagement reaches the pre-battle text box")
  eq(ow.player.cellX, 12, "player still on the detection tile after walk-up")
  -- TrainerWalkUpToPlayer: distance 2 -> (2 - 1) = 1 step, stop adjacent
  eq(trainer.cellX, 11, "trainer walked distance-1 steps (10 -> 11)")
  eq(trainer.cellY, 6, "trainer stayed on the sight row")
  check(not trainer.moving, "trainer is tile-aligned next to the player")
  eq(trainer.facing, "right", "trainer still faces the player")
end

-- === (2) player already adjacent: no walk-up at all ===
-- TrainerWalkUpToPlayer returns without writing a movement script when the
-- trainer is exactly one tile away (`cp $10 / ret z`).
do
  local ow, trainer = freshOverworld(11, 6, "down")
  local guard = 0
  while not ow.engaging and guard < 10 do
    guard = guard + 1
    frame(ow)
  end
  check(ow.engaging, "adjacent player (distance 1) is spotted while standing")
  guard = 0
  while Game.stack:top() == ow and guard < 200 do
    guard = guard + 1
    frame(ow)
  end
  check(Game.stack:top() ~= ow, "adjacent engagement reaches the text box")
  check(trainer.cellX == 10 and trainer.cellY == 6 and not trainer.moving,
        "trainer never moves when the player is already adjacent")
  check(ow.player.cellX == 11 and ow.player.cellY == 6,
        "player unmoved in the adjacent case")
end

-- === (3) whole-line engagement + range counting ===
-- Standing anywhere on the line within range engages; range 2 means
-- exactly 2 tiles (CheckSpriteCanSeePlayer: distance <= range * 16 px).
do
  local ow = freshOverworld(11, 6, "down") -- distance 1: in range
  local guard = 0
  while not ow.engaging and guard < 10 do guard = guard + 1; frame(ow) end
  check(ow.engaging, "distance 1 engages (line covers every tile up to range)")

  local ow2 = freshOverworld(12, 6, "down") -- distance 2: still in range
  guard = 0
  while not ow2.engaging and guard < 10 do guard = guard + 1; frame(ow2) end
  check(ow2.engaging, "distance 2 engages (inclusive range)")

  local ow3 = freshOverworld(12, 5, "down") -- off the row: not aligned
  for _ = 1, 10 do frame(ow3) end
  check(not ow3.engaging, "off-row tile never engages (must be lined up)")

  local ow4 = freshOverworld(9, 6, "down") -- wrong side would be (9,6)...
  for _ = 1, 10 do frame(ow4) end
  check(not ow4.engaging,
        "tile behind the trainer never engages (CheckPlayerIsInFrontOfSprite)")
end

print(("parity trainer_sight: %d/%d passed"):format(total - fails, total))
if fails > 0 then error(fails .. " trainer-sight assertion(s) failed") end
