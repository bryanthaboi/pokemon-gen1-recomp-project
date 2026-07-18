-- Parity test,  Workstream B.
-- Champions Room -> Hall of Fame cutscene: Oak walk-in/congratulate/
-- disappoint/come-with-me, warp up into HALL_OF_FAME, then the room script
-- drives the HoF Oak speech + induction (scripts/ChampionsRoom.asm,
-- scripts/HallOfFame.asm).
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end
local fails, total = 0, 0
local function check(c, m) total = total + 1; if c then print("ok   " .. m) else fails = fails + 1; print("FAIL " .. m) end end
local function eq(g, w, m) check(g == w, ("%s (got %s, want %s)"):format(m, tostring(g), tostring(w))) end

-- === assertions ===

local init = require("data.scripts.init")

-- (1) both map-script hooks are registered
local hof = init.get("HALL_OF_FAME")
check(hof ~= nil, "HALL_OF_FAME map script registered")
check(hof and type(hof.onEnter) == "function", "HALL_OF_FAME.onEnter is a function")

local champ = init.get("CHAMPIONS_ROOM")
check(champ ~= nil, "CHAMPIONS_ROOM map script registered")
local rows = champ and champ.talk and champ.talk.TEXT_CHAMPIONSROOM_RIVAL
check(type(rows) == "table", "CHAMPIONS_ROOM.talk.TEXT_CHAMPIONSROOM_RIVAL exists")

-- (2) the rival cutscene rows contain the pokered beats in order
rows = rows or {}
local preds = {
  { "show_object CHAMPIONSROOM_OAK",
    function(r) return r[1] == "show_object" and r[3] == "CHAMPIONSROOM_OAK" end },
  { "move_npc(2,'up',5) OakEntranceAfterVictoryMovement",
    function(r) return r[1] == "move_npc" and r[2] == 2 and r[3] == "up" and r[4] == 5 end },
  { "show_text _ChampionsRoomOakDisappointedWithRivalText",
    function(r) return r[1] == "show_text" and r[2] == "_ChampionsRoomOakDisappointedWithRivalText" end },
  { "move_npc(2,'up',2) OakExitChampionsRoomMovement",
    function(r) return r[1] == "move_npc" and r[2] == 2 and r[3] == "up" and r[4] == 2 end },
  { "hide_object CHAMPIONSROOM_OAK",
    function(r) return r[1] == "hide_object" and r[3] == "CHAMPIONSROOM_OAK" end },
  { "warp HALL_OF_FAME",
    function(r) return r[1] == "warp" and r[2] == "HALL_OF_FAME" end },
}
local pi = 1
for _, r in ipairs(rows) do
  if pi <= #preds and preds[pi][2](r) then pi = pi + 1 end
end
for i = 1, #preds do
  check(i < pi, "rival cutscene has, in order: " .. preds[i][1])
end

-- the induction must NOT run mid-Champions-Room anymore
local hasRecord = false
for _, r in ipairs(rows) do
  if r[1] == "record_hall_of_fame" then hasRecord = true end
end
check(not hasRecord, "CHAMPIONS_ROOM rival script no longer calls record_hall_of_fame")

-- (3) Commands.face_player_dir sets the player's facing
local Commands = require("src.script.Commands")
check(type(Commands.face_player_dir) == "function", "Commands.face_player_dir is a function")
local ctx = { overworld = { player = {} } }
Commands.face_player_dir(ctx, "right")
eq(ctx.overworld.player.facing, "right", "face_player_dir sets player.facing")

-- (4) the two maps warp into each other
local hofMap = Data.maps.HALL_OF_FAME
check(hofMap ~= nil, "Data.maps.HALL_OF_FAME exists")
local hofToChamp = false
for _, w in ipairs(hofMap and hofMap.warps or {}) do
  if w.destMap == "CHAMPIONS_ROOM" then hofToChamp = true end
end
check(hofToChamp, "HALL_OF_FAME has a warp back to CHAMPIONS_ROOM")

local champMap = Data.maps.CHAMPIONS_ROOM
check(champMap ~= nil, "Data.maps.CHAMPIONS_ROOM exists")
local champToHof = false
for _, w in ipairs(champMap and champMap.warps or {}) do
  if w.destMap == "HALL_OF_FAME" then champToHof = true end
end
check(champToHof, "CHAMPIONS_ROOM has a warp up into HALL_OF_FAME")

-- (5) functional: HALL_OF_FAME.onEnter consumes the one-shot marker and
-- queues (does not directly run) the room cutscene.
local queued
local fakeOw = { queueScript = function(self, script, extra) queued = script; self.pendingScript = { script = script } end }
local fakeGame = { save = { pendingHallOfFame = true } }
hof.onEnter(fakeGame, fakeOw)
check(queued ~= nil, "HALL_OF_FAME.onEnter queues a cutscene script when marker set")
eq(fakeGame.save.pendingHallOfFame, false, "HALL_OF_FAME.onEnter clears the one-shot marker")
check(fakeOw.pendingScript ~= nil, "queued script stored on ow.pendingScript")
-- and the queued script drives the room beats
if queued then
  local first, last = queued[1], queued[#queued]
  check(first[1] == "move_player" and first[2] == "up" and first[3] == 5,
        "HoF cutscene starts with move_player up 5")
  check(last[1] == "record_hall_of_fame",
        "HoF cutscene ends with record_hall_of_fame (induction from the room)")
end
-- a second entry with the marker cleared must NOT replay the induction
queued = nil
fakeGame.save.pendingHallOfFame = false
hof.onEnter(fakeGame, fakeOw)
check(queued == nil, "HALL_OF_FAME.onEnter does not replay once the marker is consumed")

print(("parity B: %d/%d passed"):format(total - fails, total))
if fails > 0 then error(fails .. " parity-B assertion(s) failed") end
