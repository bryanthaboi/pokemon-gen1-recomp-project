-- Parity test,  Workstream E.
-- Self-contained: run via `luajit tests/parity_E.lua`; also dofile'd by
-- tests/run_tests.lua's aggregator.
--
-- Covers: Cinnabar Lab fossil revival delay -- scripts/
-- CinnabarLabFossilRoom.asm (CinnabarLabFossilRoomScientist1Text),
-- engine/events/cinnabar_lab.asm (GiveFossilToCinnabarLab), and
-- scripts/CinnabarIsland.asm line 6 (ResetEvent
-- EVENT_LAB_STILL_REVIVING_FOSSIL on every map load).  Deposit a fossil
-- through the fossil-select menu (every carried fossil in FossilsList
-- order, Yes/No confirm, ComeAgainText on either cancel) -> pending for
-- the rest of the visit -> ready once CINNABAR_ISLAND's onEnter has run
-- again -> grant the mon and reset the quest, ported in
-- data/scripts/story2.lua (the talk handler) and data/scripts/story5.lua
-- (M.CINNABAR_ISLAND.onEnter).
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end
local S = require("tests.harness").suite("parity E")
local check, eq = S.check, S.eq

-- The real TextBox needs a loaded font plus frame-stepped input to type
-- and dismiss pages -- unrelated to what this workstream verifies (flag /
-- inventory / party state transitions).  Stub it to fire its onDone
-- callback immediately, exactly like the real box does once the player
-- has mashed through it, and record the shown strings for the
-- text-content assertions below.  opts.choice boxes (SeesFossilText's
-- YesNoChoice) resolve with the scripted `choiceAnswer`.  Restored at
-- the end of this file so suites that dofile after this one (the
-- run_tests.lua aggregator) still get the real TextBox.
local realTextBox = package.loaded["src.render.TextBox"]
local shownTexts = {}
local choiceAnswer = true -- scripted YES/NO for opts.choice boxes
package.loaded["src.render.TextBox"] = {
  new = function(game, text, onDone, opts)
    table.insert(shownTexts, text)
    if opts and opts.choice then
      opts.choice(choiceAnswer)
    elseif onDone then
      onDone()
    end
    return { text = text }
  end,
}

-- The fossil-select menu (GiveFossilToCinnabarLab's bordered list,
-- src/ui/Menu.lua) selects from frame-stepped input; stub it to pick
-- the scripted entry immediately (or back out with B when menuPick is
-- "cancel"), recording the labels for the order assertions.
local realMenu = package.loaded["src.ui.Menu"]
local menuPick = 1
local menuLabels = nil
package.loaded["src.ui.Menu"] = {
  new = function(game, items, opts)
    menuLabels = {}
    for i, it in ipairs(items) do menuLabels[i] = it.label end
    if menuPick == "cancel" then
      if opts and opts.onCancel then opts.onCancel() end
    else
      items[menuPick].onSelect()
    end
    return {}
  end,
}

local SaveData = require("src.core.SaveData")
local story2 = require("data.scripts.story2")
local story5 = require("data.scripts.story5")

check(story2.CINNABAR_LAB_FOSSIL_ROOM ~= nil, "CINNABAR_LAB_FOSSIL_ROOM registered")
check(story2.CINNABAR_LAB_FOSSIL_ROOM
      and story2.CINNABAR_LAB_FOSSIL_ROOM.talk.TEXT_CINNABARLABFOSSILROOM_SCIENTIST1 ~= nil,
      "scientist1 talk handler registered")
check(story5.CINNABAR_ISLAND ~= nil and story5.CINNABAR_ISLAND.onEnter ~= nil,
      "CINNABAR_ISLAND.onEnter registered")

local talkScientist1 = story2.CINNABAR_LAB_FOSSIL_ROOM.talk.TEXT_CINNABARLABFOSSILROOM_SCIENTIST1

local function newGame()
  local save = SaveData.newGame()
  local game = { data = Data, save = save, stack = { push = function() end } }
  return game
end

local function talk(game)
  shownTexts = {}
  local doneCalled = false
  talkScientist1(game, {}, nil, function() doneCalled = true end)
  return doneCalled
end

-- === 1) no fossil in inventory: no-fossils text, no flags set ===
do
  local game = newGame()
  check(talk(game), "no-fossil talk completes")
  check(not game.save.flags.EVENT_GAVE_FOSSIL_TO_LAB, "no fossil: GAVE_FOSSIL_TO_LAB not set")
  check(not game.save.flags.EVENT_LAB_STILL_REVIVING_FOSSIL, "no fossil: STILL_REVIVING not set")
  eq(#game.save.party, 0, "no fossil: party unchanged")
  eq(shownTexts[#shownTexts], "No! Is too bad!", "no fossil shows NoFossilsText")
end

-- === 2)-5) full deposit -> pending -> re-entry -> grant cycle ===
do
  local game = newGame()
  game.save.inventory.OLD_AMBER = 1

  -- 2) depositing OLD_AMBER through the menu + YES confirm: cleared
  -- from the bag, quest flags set, AERODACTYL not granted yet (same
  -- conversation as the deposit).
  menuPick, choiceAnswer = 1, true
  check(talk(game), "deposit talk completes")
  eq(menuLabels and #menuLabels, 1, "fossil menu lists the one carried fossil")
  eq(menuLabels and menuLabels[1], "OLD AMBER", "fossil menu shows the item name")
  local sees
  for _, s in ipairs(shownTexts) do
    if s:find("Resurrection") then sees = s end
  end
  check(sees and sees:find("OLD AMBER", 1, true) and sees:find("AERODACTYL", 1, true),
        "SeesFossilText names both the fossil (wNameBuffer) and the mon (wStringBuffer)")
  eq(game.save.inventory.OLD_AMBER, nil, "OLD_AMBER cleared from inventory on deposit")
  check(game.save.flags.EVENT_GAVE_FOSSIL_TO_LAB == true, "GAVE_FOSSIL_TO_LAB set on deposit")
  check(game.save.flags.EVENT_LAB_STILL_REVIVING_FOSSIL == true, "STILL_REVIVING set on deposit")
  eq(#game.save.party, 0, "AERODACTYL not granted in the deposit conversation")
  eq(game.save.labFossilMon, "AERODACTYL", "pending species (AERODACTYL) remembered")

  -- 3) re-talking within the same visit: still pending, no grant
  check(talk(game), "same-visit re-talk completes")
  check(game.save.flags.EVENT_GAVE_FOSSIL_TO_LAB == true,
        "same-visit re-talk: GAVE_FOSSIL_TO_LAB still set")
  check(game.save.flags.EVENT_LAB_STILL_REVIVING_FOSSIL == true,
        "same-visit re-talk: STILL_REVIVING still set")
  eq(#game.save.party, 0, "same-visit re-talk: still no mon granted")
  eq(shownTexts[#shownTexts], "I take a little\ntime!\fYou go for walk a\nlittle while!",
     "same-visit re-talk shows GoForAWalkText")

  -- 4) leaving and re-entering CINNABAR_ISLAND (its onEnter) clears
  -- STILL_REVIVING but leaves GAVE_FOSSIL_TO_LAB set
  story5.CINNABAR_ISLAND.onEnter(game, {})
  check(game.save.flags.EVENT_GAVE_FOSSIL_TO_LAB == true,
        "CINNABAR_ISLAND onEnter: GAVE_FOSSIL_TO_LAB survives the reload")
  check(not game.save.flags.EVENT_LAB_STILL_REVIVING_FOSSIL,
        "CINNABAR_ISLAND onEnter clears STILL_REVIVING")

  -- 5) talking again grants AERODACTYL at level 30 and resets the whole
  -- quest (all three EVENT_ flags, and the transient species field) so
  -- a second fossil can be deposited later
  check(talk(game), "ready talk completes")
  eq(#game.save.party, 1, "AERODACTYL granted into the party after re-entry")
  eq(game.save.party[1] and game.save.party[1].species, "AERODACTYL",
     "granted species is AERODACTYL")
  eq(game.save.party[1] and game.save.party[1].level, 30, "AERODACTYL granted at level 30")
  check(not game.save.flags.EVENT_GAVE_FOSSIL_TO_LAB, "grant resets GAVE_FOSSIL_TO_LAB")
  check(not game.save.flags.EVENT_LAB_STILL_REVIVING_FOSSIL, "grant resets STILL_REVIVING")
  check(not game.save.flags.EVENT_LAB_HANDING_OVER_FOSSIL_MON, "grant resets HANDING_OVER_FOSSIL_MON")
  eq(game.save.labFossilMon, nil, "pending species cleared after grant")
end

-- === the menu lists every carried fossil in FossilsList scan order
-- (DOME_FOSSIL, HELIX_FOSSIL, OLD_AMBER) and deposits the chosen one ===
do
  local game = newGame()
  game.save.inventory.OLD_AMBER = 1
  game.save.inventory.HELIX_FOSSIL = 1
  menuPick, choiceAnswer = 1, true
  check(talk(game), "multi-fossil deposit talk completes")
  eq(menuLabels and #menuLabels, 2, "menu lists both carried fossils")
  eq(menuLabels and menuLabels[1], "HELIX FOSSIL", "HELIX FOSSIL listed first (FossilsList order)")
  eq(menuLabels and menuLabels[2], "OLD AMBER", "OLD AMBER listed second")
  eq(game.save.labFossilMon, "OMANYTE", "choosing HELIX FOSSIL deposits it")
  eq(game.save.inventory.HELIX_FOSSIL, nil, "HELIX_FOSSIL cleared from inventory")
  eq(game.save.inventory.OLD_AMBER, 1, "OLD_AMBER left untouched for a later visit")
end

-- === backing out of the menu with B: ComeAgainText, nothing taken
-- (GiveFossilToCinnabarLab .cancelledGivingFossil) ===
do
  local game = newGame()
  game.save.inventory.DOME_FOSSIL = 1
  menuPick = "cancel"
  check(talk(game), "menu-cancel talk completes")
  eq(shownTexts[#shownTexts], "Aiyah! You come\nagain!", "menu B-out shows ComeAgainText")
  eq(game.save.inventory.DOME_FOSSIL, 1, "fossil kept after menu cancel")
  check(not game.save.flags.EVENT_GAVE_FOSSIL_TO_LAB, "menu cancel sets no quest flags")
  eq(game.save.labFossilMon, nil, "menu cancel leaves no pending species")
end

-- === answering NO on the SeesFossilText confirm: same cancel path ===
do
  local game = newGame()
  game.save.inventory.DOME_FOSSIL = 1
  menuPick, choiceAnswer = 1, false
  check(talk(game), "confirm-NO talk completes")
  eq(shownTexts[#shownTexts], "Aiyah! You come\nagain!", "NO on the confirm shows ComeAgainText")
  eq(game.save.inventory.DOME_FOSSIL, 1, "fossil kept after NO")
  check(not game.save.flags.EVENT_GAVE_FOSSIL_TO_LAB, "NO sets no quest flags")
  eq(game.save.labFossilMon, nil, "NO leaves no pending species")
end

package.loaded["src.render.TextBox"] = realTextBox
package.loaded["src.ui.Menu"] = realMenu

S.finish()
