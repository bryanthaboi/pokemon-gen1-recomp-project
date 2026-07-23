-- Parity: Rocket Hideout B4F Lift Key drop (#90 / #105).
--
-- Oracle: scripts/RocketHideoutB4F.asm RocketHideoutB4FRocket3AfterBattleText
-- (PrintText + CheckAndSetEvent EVENT_ROCKET_DROPPED_LIFT_KEY / ShowObject
-- TOGGLE_ROCKET_HIDEOUT_B4F_ITEM_5).  The LIFT_KEY object_event starts
-- hidden; talking to Rocket3 after his defeat reveals it.
--
-- Self-contained: `luajit tests/parity_lift_key.lua`; also dofile'd by
-- tests/run_tests.lua.
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end

local S = require("tests.harness").suite("parity lift key")
local check, eq = S.check, S.eq

local mapScripts = require("data.scripts.init")
local OverworldState = require("src.world.OverworldController")

local liftKeyObj
for _, o in ipairs(Data.maps.ROCKET_HIDEOUT_B4F.objects) do
  if o.name == "ROCKETHIDEOUTB4F_LIFT_KEY" then liftKeyObj = o break end
end
check(liftKeyObj and liftKeyObj.hidden == true,
      "LIFT_KEY object_event is extracted as hidden")

local script = mapScripts.talkScript("ROCKET_HIDEOUT_B4F",
                                     "TEXT_ROCKETHIDEOUTB4F_ROCKET3")
check(type(script) == "function",
      "Rocket3 after-battle drop is a hand-ported talk handler")

-- Capture TextBox payloads without driving the typewriter / font path.
local realTB = package.loaded["src.render.TextBox"]
package.loaded["src.render.TextBox"] = {
  new = function(game, text, done) return { text = text, onDone = done } end,
}

-- Drive the defeated-talk path headless: show after text, then ShowObject.
do
  local pushed, engaged
  local save = {
    flags = {},
    inventory = {},
    defeatedTrainers = { ROCKET_HIDEOUT_B4F_obj_4 = true },
    objectToggles = {},
  }
  local game = {
    data = Data,
    save = save,
    stack = {
      push = function(_, box) pushed = box end,
    },
  }
  local ow = {
    map = { id = "ROCKET_HIDEOUT_B4F", def = Data.maps.ROCKET_HIDEOUT_B4F },
    npcs = {},
    entities = {},
    trainerDefeated = function(_, npc)
      return save.defeatedTrainers[npc.id] == true
    end,
    engageTrainer = function() engaged = true end,
  }
  local npc = {
    id = "ROCKET_HIDEOUT_B4F_obj_4",
    def = { name = "ROCKETHIDEOUTB4F_ROCKET3", index = 4,
            text = "TEXT_ROCKETHIDEOUTB4F_ROCKET3",
            trainerClass = "OPP_ROCKET", trainerParty = 18 },
  }
  local doneCalled = false
  script(game, ow, npc, function() doneCalled = true end)

  check(not engaged, "defeated Rocket3 talk does not re-engage battle")
  check(pushed ~= nil, "defeated Rocket3 talk pushes the after-battle text")
  eq(pushed and pushed.text, Data.text._RocketHideoutB4FRocket3AfterBattleText,
     "after-battle text is the dropped-key line")
  check(not save.flags.EVENT_ROCKET_DROPPED_LIFT_KEY,
        "drop flag unset until the text box closes")
  check(not OverworldState.objectVisible(save, "ROCKET_HIDEOUT_B4F", liftKeyObj),
        "LIFT_KEY still hidden before the after-battle text finishes")

  -- dismiss the box: CheckAndSetEvent + ShowObject
  pushed.onDone()
  check(doneCalled, "talk done() runs after ShowObject")
  check(save.flags.EVENT_ROCKET_DROPPED_LIFT_KEY == true,
        "EVENT_ROCKET_DROPPED_LIFT_KEY set on first after-battle talk")
  check(save.objectToggles.ROCKET_HIDEOUT_B4F
        and save.objectToggles.ROCKET_HIDEOUT_B4F.ROCKETHIDEOUTB4F_LIFT_KEY == true,
        "ShowObject toggles ROCKETHIDEOUTB4F_LIFT_KEY visible")
  check(OverworldState.objectVisible(save, "ROCKET_HIDEOUT_B4F", liftKeyObj),
        "LIFT_KEY objectVisible after ShowObject")

  -- second talk: reprint only, no double-toggle churn
  pushed, doneCalled = nil, false
  local togglesBefore = save.objectToggles.ROCKET_HIDEOUT_B4F.ROCKETHIDEOUTB4F_LIFT_KEY
  script(game, ow, npc, function() doneCalled = true end)
  check(pushed ~= nil, "second after-battle talk still shows text")
  pushed.onDone()
  check(doneCalled, "second talk done() runs")
  eq(save.objectToggles.ROCKET_HIDEOUT_B4F.ROCKETHIDEOUTB4F_LIFT_KEY, togglesBefore,
     "second talk does not re-ShowObject")
end

-- Undefeated path still engages the trainer (TalkToTrainer).
do
  local engaged = false
  local save = { flags = {}, inventory = {}, defeatedTrainers = {} }
  local game = {
    data = Data, save = save,
    stack = { push = function() end },
  }
  local ow = {
    map = { id = "ROCKET_HIDEOUT_B4F" },
    trainerDefeated = function() return false end,
    engageTrainer = function(_, npc, done)
      engaged = true
      if done then done() end
    end,
  }
  local npc = {
    id = "ROCKET_HIDEOUT_B4F_obj_4",
    def = { name = "ROCKETHIDEOUTB4F_ROCKET3", index = 4 },
  }
  script(game, ow, npc, function() end)
  check(engaged, "undefeated Rocket3 talk engages the trainer battle")
end

package.loaded["src.render.TextBox"] = realTB
S.finish()
