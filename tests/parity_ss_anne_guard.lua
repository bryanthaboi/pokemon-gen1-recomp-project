-- Parity test: Vermilion City S.S. Anne sailor (#122).
--
-- pokered VermilionCityDefaultScript (scripts/VermilionCity.asm):
-- stepping onto SSAnneTicketCheckCoords (18,30) facing down always
-- DisplayTextID's the sailor.  With a ticket and the ship still docked,
-- FlashedTicket plays and the player may continue; without a ticket, or
-- after EVENT_SS_ANNE_LEFT, they are walked back up.
--
-- The port used to early-return when the ticket was in the bag, skipping
-- the flash dialog entirely.
--
-- Self-contained; run via `luajit tests/parity_ss_anne_guard.lua`.
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
local S = require("tests.harness").suite("parity ss anne guard")
local check, eq = S.check, S.eq

package.loaded["src.render.TextBox"] = {
  new = function(_, text, done) return { text = text, done = done } end,
}

local musicCalls = {}
package.loaded["src.core.Music"] = {
  stop = function() musicCalls[#musicCalls + 1] = { "stop" } end,
  play = function(_, song)
    musicCalls[#musicCalls + 1] = { "play", song }
  end,
  playOnce = function(_, song)
    musicCalls[#musicCalls + 1] = { "playOnce", song }
    return true
  end,
}

local soundCalls = {}
package.loaded["src.core.Sound"] = {
  play = function(_, id) soundCalls[#soundCalls + 1] = id end,
}

local story = dofile("data/scripts/story.lua")
local story3 = dofile("data/scripts/story3.lua")
local Flags = require("src.script.Flags")

local function gameWith(opts)
  local pushed, moved = {}, {}
  local game = {
    save = {
      inventory = opts.inventory or {},
      flags = opts.flags or {},
    },
    data = {
      text = {
        _VermilionCitySailor1DoYouHaveATicketText =
          "Welcome to S.S.\nANNE!\fExcuse me, do you\nhave a ticket?",
        _VermilionCitySailor1FlashedTicketText =
          "PLAYER flashed\nthe S.S.TICKET!",
        _VermilionCitySailor1YouNeedATicketText =
          "You need a ticket\nto get aboard.",
        _VermilionCitySailor1ShipSetSailText = "The ship set sail.",
        _SSAnneCaptainsRoomRubCaptainsBackText = "Rub-rub...",
        _SSAnneCaptainsRoomCaptainIFeelMuchBetterText = "I feel better!",
        _SSAnneCaptainsRoomCaptainReceivedHM01Text = "Got HM01!",
        _SSAnneCaptainsRoomCaptainNotSickAnymoreText = "Not sick.",
      },
    },
    stack = { push = function(_, box) pushed[#pushed + 1] = box end },
    _pushed = pushed,
    _moved = moved,
  }
  return game, pushed, moved
end

local function owWith(moved)
  return {
    player = { facing = "down", cellY = 2 },
    scriptMove = function(_, _, dir, n) moved[#moved + 1] = { dir, n } end,
    queueScript = function(self, rows) self._queued = rows end,
    startDustAnim = function() end,
    map = {
      setBlock = function() end,
      renderer = { rebuild = function() end },
    },
  }
end

local city = story.VERMILION_CITY
check(city and city.onStep, "VERMILION_CITY has the sailor coord trigger")

-- With ticket, ship still docked: flash dialog, do NOT walk back.
do
  local game, pushed, moved = gameWith({ inventory = { S_S_TICKET = 1 } })
  local ow = owWith(moved)
  check(city.onStep(game, ow, 18, 30), "ticket: walk-past trigger consumes the step")
  check(#pushed == 1, "ticket: auto dialog is shown")
  check(pushed[1].text:find("flashed", 1, true)
        or pushed[1].text:find("ticket", 1, true),
        "ticket: flash / ticket-check dialog text")
  check(#moved == 0, "ticket: player is not walked back")
end

-- Without ticket: dialog + walk back.
do
  local game, pushed, moved = gameWith({})
  local ow = owWith(moved)
  check(city.onStep(game, ow, 18, 30), "no ticket: trigger fires")
  check(#pushed == 1, "no ticket: dialog shown")
  if pushed[1] and pushed[1].done then pushed[1].done() end
  check(#moved == 1 and moved[1][1] == "up",
        "no ticket: walked back up after dialog")
end

-- After the ship leaves: ShipSetSail + walk back, even with a ticket.
do
  local game, pushed, moved = gameWith({
    inventory = { S_S_TICKET = 1 },
    flags = { EVENT_SS_ANNE_LEFT = true },
  })
  local ow = owWith(moved)
  check(city.onStep(game, ow, 18, 30), "ship left: trigger still fires")
  eq(pushed[1] and pushed[1].text, "The ship set sail.",
     "ship left: dialog updates to ShipSetSail")
  if pushed[1] and pushed[1].done then pushed[1].done() end
  check(#moved == 1 and moved[1][1] == "up",
        "ship left: walked back up")
end

-- Off-tile / wrong facing: no trigger.
do
  local game, pushed = gameWith({ inventory = { S_S_TICKET = 1 } })
  local ow = owWith({})
  eq(city.onStep(game, ow, 18, 29), false, "wrong Y: no trigger")
  ow.player.facing = "up"
  eq(city.onStep(game, ow, 18, 30), false, "facing up: no trigger")
  check(#pushed == 0, "no spurious dialog off the check")
end

-- Sailor talk after ship left: ShipSetSail branch (row script).
do
  local ScriptRunner = require("src.script.ScriptRunner")
  local game = gameWith({ flags = { EVENT_SS_ANNE_LEFT = true } })
  local rows = city.talk.TEXT_VERMILIONCITY_SAILOR1
  local runner = ScriptRunner.new(game, nil)
  runner:run(rows, {})
  local guard = 0
  while runner:isRunning() and guard < 200 do
    guard = guard + 1
    if game.stack and game._pushed then
      local box = game._pushed[#game._pushed]
      if box and box.done then box.done() end
    end
    runner:update()
  end
  local last = game._pushed[#game._pushed]
  eq(last and last.text, "The ship set sail.",
     "talk after ship left shows ShipSetSail")
end

-- Departure cutscene: Music_Surfing + EVENT_SS_ANNE_LEFT via Flags.set.
do
  for i = #musicCalls, 1, -1 do musicCalls[i] = nil end
  local game, _, moved = gameWith({ flags = { EVENT_GOT_HM01 = true } })
  local ow = owWith(moved)
  story3.VERMILION_DOCK.onEnter(game, ow)
  check(Flags.get(game.save, "EVENT_SS_ANNE_LEFT"),
        "departure sets EVENT_SS_ANNE_LEFT")
  local sawSurf = false
  for _, c in ipairs(musicCalls) do
    if c[1] == "play" and c[2] == "Music_Surfing" then sawSurf = true end
  end
  check(sawSurf, "departure plays Music_Surfing")
  check(ow._queued ~= nil, "departure queues the sail-away script")
  local kept, horn = false, false
  for _, row in ipairs(ow._queued or {}) do
    if row[1] == "play_music" and row[2] == "Music_Surfing"
        and row[3] and row[3].keep then
      kept = true
    end
    if row[1] == "play_sound" and row[2] == "SS_Anne_Horn" then
      horn = true
    end
  end
  check(kept, "departure keeps Music_Surfing across the city warp")
  check(horn, "departure queues SS_Anne_Horn")
end

-- Captain rub jingle: play_once Music_PkmnHealed sits after the rub text.
do
  local rows = story.SS_ANNE_CAPTAINS_ROOM.talk.TEXT_SSANNECAPTAINSROOM_CAPTAIN
  local found = false
  for i, row in ipairs(rows) do
    if row[1] == "play_once" and row[2] == "Music_PkmnHealed" then
      found = true
      check(rows[i - 1] and rows[i - 1][2] == "_SSAnneCaptainsRoomRubCaptainsBackText",
            "play_once follows the rub-back text")
    end
  end
  check(found, "captain script plays Music_PkmnHealed after the rub")
end

S.finish()
