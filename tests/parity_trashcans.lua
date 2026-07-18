-- Parity test,  Vermilion Gym trash can puzzle.
-- Self-contained: run via `luajit tests/parity_trashcans.lua`; also
-- dofile'd by tests/run_tests.lua's aggregator.
--
-- Covers engine/events/hidden_events/vermilion_gym_trash.asm
-- (GymTrashScript + the GymTrashCans table, bug included) and
-- scripts/VermilionCity.asm (VermilionCity_Script
-- .setFirstLockTrashCanIndex):
--   * the first-lock can is rolled on EVERY Vermilion City map load
--     (Random & $0e -> a random even can), not lazily in the gym
--   * the second-lock can comes from the GymTrashCans row for the
--     first can: `mask AND random-byte` minus 1 indexes the candidate
--     bytes, so a zero AND underflows ($ff) into the bank's zero
--     padding and lands the switch in can 0 regardless (the documented
--     bug); mask 2 can only reach candidate 2, mask 4 only candidate 4
--   * a wrong second can resets EVENT_1ST_LOCK_OPENED and immediately
--     re-rolls the first can
--   * opening the second lock prints only VermilionGymTrashSuccessText3
--     (SuccessText2 is unused in pokered) and opens the door block
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end
local fails, total = 0, 0
local function check(c, m) total = total + 1; if c then print("ok   " .. m) else fails = fails + 1; print("FAIL " .. m) end end
local function eq(g, w, m) check(g == w, ("%s (got %s, want %s)"):format(m, tostring(g), tostring(w))) end

local OW = require("src.world.OverworldController")
local SaveData = require("src.core.SaveData")
local story = require("data.scripts.story")

-- trashCanSwitch closes over the module-locals `Game` and `TextBox`
-- (set during real boot); rewire them through the debug library, the
-- same trick as parity_D.lua.
local function getUpvalue(fn, name)
  local i = 1
  while true do
    local n, v = debug.getupvalue(fn, i)
    if not n then return nil end
    if n == name then return v end
    i = i + 1
  end
end
local function setUpvalue(fn, name, val)
  local i = 1
  while true do
    local n = debug.getupvalue(fn, i)
    if not n then return false end
    if n == name then debug.setupvalue(fn, i, val); return true end
    i = i + 1
  end
end

local shown = {}
local textBoxStub = {
  new = function(_, text, onDone)
    shown[#shown + 1] = text
    if onDone then onDone() end
    return { text = text }
  end,
}
local realTextBox = getUpvalue(OW.trashCanSwitch, "TextBox")
local fakeGame = { data = Data, save = SaveData.newGame(), stack = { push = function() end } }
check(setUpvalue(OW.trashCanSwitch, "TextBox", textBoxStub), "TextBox upvalue rewired")
check(setUpvalue(OW.trashCanSwitch, "Game", fakeGame), "Game upvalue rewired")

-- scripted love.math.random: feed(...) queues the next return values
local realRandom = love.math.random
local queue = {}
local function feed(...) queue = { ... } end
love.math.random = function(a, b)
  if #queue > 0 then return table.remove(queue, 1) end
  return realRandom(a, b)
end

local replaced = {}
local fakeSelf = setmetatable({
  map = { id = "VERMILION_GYM" },
  replaceBlock = function(_, x, y, b) replaced[#replaced + 1] = { x = x, y = y, b = b } end,
}, { __index = OW })

local function fresh()
  fakeGame.save = SaveData.newGame()
  shown = {}
  replaced = {}
end

local t = Data.text

-- === Vermilion City map load rolls (and re-rolls) the first-lock can ===
do
  fresh()
  check(story.VERMILION_CITY.onEnter ~= nil, "VERMILION_CITY.onEnter registered")
  feed(3) -- Random & $0e ported as random(0,7)*2
  story.VERMILION_CITY.onEnter(fakeGame, {})
  eq(fakeGame.save.trashPuzzle.first, 6, "map load rolls the first-lock can (even index)")
  feed(0)
  story.VERMILION_CITY.onEnter(fakeGame, {})
  eq(fakeGame.save.trashPuzzle.first, 0, "every map load re-rolls, not just the first")
  -- the roll is unconditional: mid-second-stage state survives, only
  -- the (unread) first index changes
  fakeGame.save.flags.EVENT_1ST_LOCK_OPENED = true
  fakeGame.save.trashPuzzle.second = 3
  feed(5)
  story.VERMILION_CITY.onEnter(fakeGame, {})
  eq(fakeGame.save.trashPuzzle.first, 10, "re-roll happens even after the 1st lock opened")
  check(fakeGame.save.flags.EVENT_1ST_LOCK_OPENED, "map load leaves EVENT_1ST_LOCK_OPENED alone")
  eq(fakeGame.save.trashPuzzle.second, 3, "map load leaves the second-lock can alone")
end

-- === wrong first can: plain trash text, nothing opens ===
do
  fresh()
  fakeGame.save.trashPuzzle = { first = 0 }
  fakeSelf:trashCanSwitch(2)
  check(not fakeGame.save.flags.EVENT_1ST_LOCK_OPENED, "wrong first can opens nothing")
  eq(shown[#shown], t._VermilionGymTrashText, "wrong first can shows VermilionGymTrashText")
end

-- === right first can: EVENT_1ST_LOCK_OPENED + GymTrashCans second roll ===
-- can 0's row is `mask 2, candidates 1,3`: AND result 2 -> byte offset 1
-- -> candidate 2 (=can 3); candidate 1 is unreachable with mask 2
do
  fresh()
  fakeGame.save.trashPuzzle = { first = 0 }
  feed(2) -- random byte: band(2, mask 2) = 2
  fakeSelf:trashCanSwitch(0)
  check(fakeGame.save.flags.EVENT_1ST_LOCK_OPENED == true, "right can sets EVENT_1ST_LOCK_OPENED")
  eq(fakeGame.save.trashPuzzle.second, 3, "mask 2 reaches only the 2nd candidate (can 3)")
  eq(shown[#shown], t._VermilionGymTrashSuccessText1, "first lock shows SuccessText1")
end

-- zero AND result: `dec a` underflows and the read lands in zero
-- padding -> the second switch is can 0 regardless of adjacency
do
  fresh()
  fakeGame.save.trashPuzzle = { first = 0 }
  feed(13) -- band(13, mask 2) = 0
  fakeSelf:trashCanSwitch(0)
  eq(fakeGame.save.trashPuzzle.second, 0, "zero AND puts the second switch in can 0 (the bug)")
end

-- can 4's row is `mask 4, candidates 1,3,5,7`: only AND result 4
-- (-> 4th candidate, can 7) or the can-0 bug are possible
do
  fresh()
  fakeGame.save.trashPuzzle = { first = 4 }
  feed(4) -- band(4, mask 4) = 4
  fakeSelf:trashCanSwitch(4)
  eq(fakeGame.save.trashPuzzle.second, 7, "mask 4 reaches only the 4th candidate (can 7)")
  fresh()
  fakeGame.save.trashPuzzle = { first = 4 }
  feed(3) -- band(3, mask 4) = 0
  fakeSelf:trashCanSwitch(4)
  eq(fakeGame.save.trashPuzzle.second, 0, "mask 4 with a zero AND falls into can 0")
end

-- can 6's row is `mask 3, candidates 3,7,9`: results 1-3 map onto all
-- three candidates
do
  for _, case in ipairs({ { 1, 3 }, { 2, 7 }, { 3, 9 }, { 4, 0 } }) do
    fresh()
    fakeGame.save.trashPuzzle = { first = 6 }
    feed(case[1]) -- band(case[1], mask 3): 4 -> 0 (bug), else itself
    fakeSelf:trashCanSwitch(6)
    eq(fakeGame.save.trashPuzzle.second, case[2],
       ("mask 3, AND=%d -> second can %d"):format(case[1] % 4, case[2]))
  end
end

-- === wrong second can: relock + IMMEDIATE first-can re-roll ===
do
  fresh()
  fakeGame.save.flags.EVENT_1ST_LOCK_OPENED = true
  fakeGame.save.trashPuzzle = { first = 0, second = 3 }
  feed(5) -- the fail path's Random & $e -> can 10
  fakeSelf:trashCanSwitch(1)
  check(not fakeGame.save.flags.EVENT_1ST_LOCK_OPENED, "fail resets EVENT_1ST_LOCK_OPENED")
  eq(fakeGame.save.trashPuzzle.first, 10, "fail immediately re-rolls the first can")
  eq(fakeGame.save.trashPuzzle.second, nil, "fail clears the second-lock can")
  eq(shown[#shown], t._VermilionGymTrashFailText, "fail shows VermilionGymTrashFailText")
end

-- === right second can: puzzle done, door block opens, only Text3 ===
do
  fresh()
  fakeGame.save.flags.EVENT_1ST_LOCK_OPENED = true
  fakeGame.save.trashPuzzle = { first = 0, second = 3 }
  fakeSelf:trashCanSwitch(3)
  check(fakeGame.save.flags.EVENT_2ND_LOCK_OPENED == true, "second lock sets EVENT_2ND_LOCK_OPENED")
  eq(shown[#shown], t._VermilionGymTrashSuccessText3,
     "only SuccessText3 prints (SuccessText2 is unused in pokered)")
  check(replaced[1] and replaced[1].x == 2 and replaced[1].y == 2 and replaced[1].b == 5,
        "door block (2,2) replaced with the clear floor block")
  -- solved puzzle: every can is plain trash from now on
  fakeSelf:trashCanSwitch(0)
  eq(shown[#shown], t._VermilionGymTrashText, "solved puzzle shows plain trash text")
end

-- === legacy saves: pre-rewrite `opened1` migrates to the event flag ===
do
  fresh()
  fakeGame.save.trashPuzzle = { first = 0, opened1 = true, second = 3 }
  fakeSelf:trashCanSwitch(3)
  check(fakeGame.save.flags.EVENT_2ND_LOCK_OPENED == true,
        "legacy opened1 save still completes the puzzle")
end

love.math.random = realRandom
setUpvalue(OW.trashCanSwitch, "TextBox", realTextBox)

print(("parity trashcans: %d/%d passed"):format(total - fails, total))
if fails > 0 then error(fails .. " parity-trashcans assertion(s) failed") end
