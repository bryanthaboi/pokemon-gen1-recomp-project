-- Driver: Cinnabar Lab fossil-select menu (engine/events/cinnabar_lab.asm
-- GiveFossilToCinnabarLab): talk to scientist 1 carrying two fossils,
-- screenshot the fossil menu, pick one, answer YES on the confirm, and
-- confirm the deposit flags/inventory.  Then re-talk and back out with B
-- (ComeAgainText path) to prove nothing is taken on cancel.
return function(game)
  local U = dofile("tests/drivers/util.lua")
  local DIR = os.getenv("SHOT_DIR") or "/tmp/shots"
  local Menu = require("src.ui.Menu")
  local ChoiceBox = require("src.ui.ChoiceBox")
  local Bag = require("src.inventory.Bag")

  Bag.add(game.save, "DOME_FOSSIL", 1)
  Bag.add(game.save, "OLD_AMBER", 1)

  U.teleport(game, "CINNABAR_LAB_FOSSIL_ROOM", 5, 3, "up")
  local ow = game.overworld

  -- scientist 1 wanders LEFT_RIGHT along row 2: pin him right above us
  for _, npc in ipairs(ow.npcs) do
    if npc.def and npc.def.text == "TEXT_CINNABARLABFOSSILROOM_SCIENTIST1" then
      npc.wanders, npc.moving = false, false
      npc.cellX, npc.cellY = 5, 2
      npc.px, npc.py = npc.cellX * 16, npc.cellY * 16
      npc.facing = "down"
    end
  end
  U.wait(5)
  U.shot(game, DIR .. "/fossil_0_room.png")

  local function topIs(cls) return getmetatable(game.stack:top()) == cls end
  local function mash(btn, cond)
    for _ = 1, 200 do
      if cond() then return true end
      U.tap(game, btn)
      U.wait(3)
    end
    return false
  end

  -- deposit run: intro -> menu -> pick DOME FOSSIL -> YES -> walk texts
  U.tap(game, "a")
  U.wait(20)
  U.shot(game, DIR .. "/fossil_1_intro.png")
  U.log("menu reached:", mash("a", function() return topIs(Menu) end))
  U.shot(game, DIR .. "/fossil_2_menu.png")
  U.tap(game, "a") -- choose the first entry (DOME FOSSIL)
  U.log("confirm reached:", mash("a", function() return topIs(ChoiceBox) end))
  U.shot(game, DIR .. "/fossil_3_confirm.png")
  U.tap(game, "a") -- YES
  U.log("deposit texts done:", mash("a", function()
    return game.stack:top() == ow
  end))
  U.shot(game, DIR .. "/fossil_4_done.png")
  U.log("GAVE_FOSSIL_TO_LAB:", tostring(game.save.flags.EVENT_GAVE_FOSSIL_TO_LAB),
        "STILL_REVIVING:", tostring(game.save.flags.EVENT_LAB_STILL_REVIVING_FOSSIL),
        "labFossilMon:", tostring(game.save.labFossilMon))
  U.log("bag DOME_FOSSIL:", tostring(game.save.inventory.DOME_FOSSIL),
        "OLD_AMBER:", tostring(game.save.inventory.OLD_AMBER))

  -- cancel run after the quest resets would need a full revive cycle;
  -- instead prove the B-out path on a fresh quest state
  game.save.flags.EVENT_GAVE_FOSSIL_TO_LAB = nil
  game.save.flags.EVENT_LAB_STILL_REVIVING_FOSSIL = nil
  game.save.labFossilMon = nil
  U.tap(game, "a")
  U.wait(20)
  U.log("menu reached again:", mash("a", function() return topIs(Menu) end))
  U.shot(game, DIR .. "/fossil_5_menu_again.png")
  U.tap(game, "b") -- back out
  U.log("cancel text done:", mash("a", function()
    return game.stack:top() == ow
  end))
  U.shot(game, DIR .. "/fossil_6_cancelled.png")
  U.log("after cancel OLD_AMBER:", tostring(game.save.inventory.OLD_AMBER),
        "GAVE_FOSSIL_TO_LAB:", tostring(game.save.flags.EVENT_GAVE_FOSSIL_TO_LAB))
  U.log("DONE")
  love.event.quit()
end
