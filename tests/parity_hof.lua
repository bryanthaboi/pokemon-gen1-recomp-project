-- Parity test,  Hall of Fame credits, autosave and post-credits reset
-- (engine/movie/credits.asm HallOfFamePC/Credits, scripts/HallOfFame.asm
-- HallOfFameResetEventsAndSaveScript).
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end
local Font = require("src.render.Font")
if not pcall(Font.encode, "A") then Font.load(Data) end
local S = require("tests.harness").suite("parity HOF")
local check, eq = S.check, S.eq

-- === (1) extracted credits data matches CreditsOrder/CreditsMons ===

local credits = Data.field and Data.field.credits
check(credits ~= nil, "field.credits extracted")
credits = credits or { screens = {}, mons = {} }
eq(#credits.screens, 35, "CreditsOrder: 35 screens")
eq(#credits.mons, 15, "CreditsMons: 15 entries")
local s1 = credits.screens[1] or {}
check(s1.fade == true and s1.mon == "VENUSAUR",
      "screen 1 is CRED_TEXT_FADE_MON with VENUSAUR")
local last = credits.screens[#credits.screens] or {}
check(last.copyright == true and last.fade == true and last.mon == "PARASECT",
      "last screen is CRED_COPYRIGHT + CRED_TEXT_FADE_MON with PARASECT")
-- after every mon wipe BGP is left at %11000000 (text invisible), so the
-- following screen must be a FADE variant -- true of the extracted order
local fadeAfterWipe = true
local prevMon = true -- HallOfFamePC enters with BGP %11000000
for _, s in ipairs(credits.screens) do
  if prevMon and not s.fade then fadeAfterWipe = false end
  prevMon = s.mon ~= nil
end
check(fadeAfterWipe, "every screen after a mon wipe fades in")

-- === (2) Credits state machine: pokered's exact frame timing ===

local Credits = require("src.ui.Credits")
local pressed = {}
local fakeInput = { wasPressed = function(_, b) return pressed[b] or false end,
                    isDown = function() return false end }
local function newStack()
  local stack = { states = {} }
  function stack:push(s, ...) table.insert(self.states, s) if s.enter then s:enter(...) end end
  function stack:pop() local s = table.remove(self.states) if s and s.exit then s:exit() end return s end
  function stack:top() return self.states[#self.states] end
  return stack
end

local stack = newStack()
local game = { data = Data, input = fakeInput, stack = stack, save = {} }
local theEndAt, doneRan = nil, false
local frame = 0
local roll = Credits.new(game, function() doneRan = true end,
                         function() theEndAt = frame end)
stack:push(roll)

-- HallOfFamePC lead-in (100 blank + 128 after music starts) + per-screen
-- fade/hold/wipe + THE END (16 blank + 20 fade) + the script's 5x120
-- DelayFrames before WaitForTextScrollButtonPress
local expected = 100 + 128 + 16 + 20 + 600
for _, s in ipairs(credits.screens) do
  expected = expected + (s.fade and 20 or 0)
    + (s.mon and (s.fade and 90 or 110) or (s.fade and 120 or 140))
    + (s.mon and 27 or 0)
end
while roll.phase ~= "end_wait" and frame < expected + 120 do
  frame = frame + 1
  roll:update(1 / 60)
  roll:draw() -- exercise every draw path headless
end
eq(frame, expected, "credits reach the A/B wait after the exact frame count")
eq(theEndAt, expected - 600,
   "onTheEnd (the SaveGameData point) fires when THE END finishes fading")
check(not doneRan, "onDone waits for the button press")
roll:update(1 / 60) -- unpressed frame: still waiting
check(roll.phase == "end_wait" and #stack.states == 1, "credits hold on THE END")
pressed.b = true -- WaitForTextScrollButtonPress takes A or B
roll:update(1 / 60)
pressed.b = nil
check(doneRan, "B on THE END pops the credits and calls onDone")
eq(#stack.states, 0, "credits popped itself")

-- === (3) record_hall_of_fame: induction -> credits -> autosave -> Init ===

local Commands = require("src.script.Commands")
local SaveData = require("src.core.SaveData")
local stack2 = newStack()
local game2 = { data = Data, input = fakeInput, stack = stack2,
                save = SaveData.newGame() }
-- battered party: record_hall_of_fame must heal before the autosave (#103)
game2.save.party = { { species = "PIKACHU", level = 81, hp = 1,
                       stats = { hp = 100 }, status = "PAR",
                       moves = { { id = "THUNDERBOLT", pp = 0 } } } }
game2.save.player.map = "HALL_OF_FAME"
game2.save.lastOutdoor = { id = "INDIGO_PLATEAU", x = 9, y = 5 }
local wrote = false
function game2:writeSave() wrote = true; SaveData.save(self.save) end

local co
local runner = {}
function runner:yield() coroutine.yield() end
function runner:resume()
  local ok, err = coroutine.resume(co)
  if not ok then error(err) end
end
local ctx = { game = game2, save = game2.save, runner = runner }
co = coroutine.create(function() Commands.record_hall_of_fame(ctx) end)
local ok, err = coroutine.resume(co)
check(ok, "record_hall_of_fame starts: " .. tostring(err))

eq(#game2.save.hallOfFame, 1, "winning team recorded (SaveHallOfFameTeams)")
local HallOfFame = require("src.ui.HallOfFame")
check(getmetatable(stack2:top()) == HallOfFame, "induction showcase pushed")

-- drive induction + full credits with A held (pages are unskippable; A
-- only advances the induction and the final THE END wait)
pressed.a = true
local guard = 0
while coroutine.status(co) ~= "dead" and stack2:top() and guard < 30000 do
  guard = guard + 1
  local top = stack2:top()
  if top.update then top:update(1 / 60) end
end
pressed.a = nil
eq(coroutine.status(co), "dead", "HoF script command runs to completion")
check(guard > expected, "credits pages were not skippable by holding A")

-- the autosave (SaveGameData while THE END is up)
check(wrote, "autosave ran during THE END")
local savedRaw = love.filesystem.read("save.lua")
local saved = savedRaw and SaveData.decode(savedRaw) or nil
check(saved ~= nil, "save.lua written and decodable")
eq(saved and saved.lastHeal and saved.lastHeal.map, "PALLET_TOWN",
   "wLastBlackoutMap := PALLET_TOWN before the save")
eq(saved and saved.player and saved.player.map, "REDS_HOUSE_2F",
   "CONTINUE lands in the bedroom (post-game home, #103)")
eq(saved and saved.player and saved.player.x, 3, "bedroom spawn x")
eq(saved and saved.player and saved.player.y, 6, "bedroom spawn y")
eq(saved and saved.lastOutdoor and saved.lastOutdoor.id, "PALLET_TOWN",
   "LAST_MAP exits aim at Pallet Town, not Indigo")
check(saved and saved.postGameHomeOk, "postGameHomeOk marks the relocate done")
eq(saved and #(saved.hallOfFame or {}), 1, "hall of fame team persisted")
local healed = saved and saved.party and saved.party[1]
local thunderPp = Data.moves and Data.moves.THUNDERBOLT and Data.moves.THUNDERBOLT.pp
check(healed and healed.hp == healed.stats.hp and healed.status == nil
        and healed.moves[1].pp == thunderPp,
      "party is fully healed in the post-credits save")

-- house exit mats resolve to Pallet's door, not Indigo
local Warp = require("src.world.Warp")
local houseExit = { destMap = "LAST_MAP", destWarp = 1, x = 2, y = 7 }
local destMap, dx, dy = Warp.destination(Data, houseExit, saved.lastOutdoor)
eq(destMap, "PALLET_TOWN", "Red's house LAST_MAP -> PALLET_TOWN")
eq(dx, 5, "Pallet door x")
eq(dy, 5, "Pallet door y")

-- stuck-save rescue: HoF + hallOfFame + no postGameHomeOk -> bedroom
local stuck = SaveData.newGame()
stuck.player.map = "HALL_OF_FAME"
stuck.player.x, stuck.player.y = 4, 2
stuck.lastOutdoor = { id = "INDIGO_PLATEAU", x = 9, y = 5 }
stuck.hallOfFame = { { { species = "PIKACHU", level = 81 } } }
check(SaveData.needsPostGameRescue(stuck), "pre-fix softlock save needs rescue")
SaveData.applyPostGameHome(stuck, Data.field.boot)
check(not SaveData.needsPostGameRescue(stuck), "rescue is one-shot")
eq(stuck.player.map, "REDS_HOUSE_2F", "rescue warps home")
eq(stuck.lastOutdoor.id, "PALLET_TOWN", "rescue retargets LAST_MAP")

-- `jp Init`: everything popped, boot sequence pushed (intro -> title)
eq(#stack2.states, 1, "soft reset leaves exactly the boot state")
local IntroMovie = require("src.ui.IntroMovie")
check(getmetatable(stack2:top()) == IntroMovie,
      "post-credits state is the IntroMovie (jp Init boot path)")
local Game = require("src.core.Game")
check(type(Game.makeTitleState) == "function",
      "Game:makeTitleState exists for the intro's title handoff")

S.finish()
