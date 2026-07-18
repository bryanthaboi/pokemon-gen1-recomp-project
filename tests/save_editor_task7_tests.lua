-- Headless tests for the Task 7 Events + Dex panels.
-- Run from repo root: /opt/homebrew/Cellar/lua@5.4/5.4.8/bin/lua tests/save_editor_task7_tests.lua
--
-- Mirrors tests/run_save_editor_tests.lua's approach: drive Kit's
-- immediate-mode hit-testing by placing the "mouse" at the exact
-- coordinates each panel draws its widgets at (see the layout comments in
-- panels/Events.lua and panels/Dex.lua), so click handlers run for real
-- without a live LOVE window.

package.path = package.path .. ";./?.lua;./?/init.lua;./tools/save-editor/?.lua"
  .. ";./tools/save-editor/panels/?.lua"

local love_stub = require("tests.love_stub")
love = love_stub

local passed, failed = 0, 0

local function check(cond, msg)
  if cond then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL: " .. msg)
  end
end

local function eq(a, b, msg)
  check(a == b, msg .. string.format(" (got %s, want %s)", tostring(a), tostring(b)))
end

print("== save editor task 7 tests (Events + Dex) ==")

local Kit = require("Kit")
local State = require("State")
local SaveIO = require("SaveIO")
local SaveData = require("src.core.SaveData")
local Events = require("Events")
local Dex = require("Dex")

local px, py = 12, 80

-- ===== Events: Flags tab =====
do
  local S = State.new()
  S.events = { "EVENT_ALPHA", "EVENT_BEAT_BROCK", "EVENT_ZETA" }
  S.save = {
    flags = {}, defeatedTrainers = {}, itemsTaken = {}, objectToggles = {},
    party = {}, boxes = {},
  }

  Kit.beginFrame(0, 0, false)
  Events.draw(S, Kit, px, py)
  eq(S.eventFilter, "", "Events.draw defaults eventFilter to empty string")
  eq(S.eventsTab, "flags", "Events.draw defaults eventsTab to flags")

  local listY = py + 64 + 32 -- contentY(+64) + list offset(+32)

  Kit.beginFrame(px + 10, listY + 10, true) -- row 1: EVENT_ALPHA
  Events.draw(S, Kit, px, py)
  check(S.save.flags.EVENT_ALPHA == true, "Flags row1 checkbox sets EVENT_ALPHA")
  check(S.dirty == true, "Flags checkbox toggle marks dirty")
  S.dirty = false

  Kit.beginFrame(px + 10, listY + 22 + 10, true) -- row 2: EVENT_BEAT_BROCK
  Events.draw(S, Kit, px, py)
  check(S.save.flags.EVENT_BEAT_BROCK == true, "Flags row2 checkbox sets EVENT_BEAT_BROCK")

  Kit.beginFrame(px + 10, listY + 22 + 10, true) -- click row 2 again to uncheck
  Events.draw(S, Kit, px, py)
  check(S.save.flags.EVENT_BEAT_BROCK == nil, "Unchecking a flag clears the key (not just false)")

  -- re-check it, then persist through SaveIO to confirm it round-trips to disk
  Kit.beginFrame(px + 10, listY + 22 + 10, true)
  Events.draw(S, Kit, px, py)
  check(S.save.flags.EVENT_BEAT_BROCK == true, "Flags row2 re-checked")

  local path = os.tmpname() .. "-task7-events.lua"
  local ok, err = SaveIO.save(path, S.save)
  check(ok, "SaveIO.save ok: " .. tostring(err))
  local f = io.open(path, "r")
  local raw = f:read("*a")
  f:close()
  check(raw:find("EVENT_BEAT_BROCK") ~= nil, "saved file contains EVENT_BEAT_BROCK key")
  local loaded = SaveData.decode(raw)
  check(loaded ~= nil and loaded.flags.EVENT_BEAT_BROCK == true,
    "reloaded save confirms EVENT_BEAT_BROCK = true")
  os.remove(path)
end

-- ===== Events: filter field + Clear filter =====
do
  local S = State.new()
  S.events = { "EVENT_ALPHA", "EVENT_BEAT_BROCK", "EVENT_ZETA" }
  S.save = {
    flags = {}, defeatedTrainers = {}, itemsTaken = {}, objectToggles = {},
    party = {}, boxes = {},
  }
  S.eventFilter = "beat" -- love.keyboard.isDown always false in love_stub,
                         -- so setting this directly stands in for typing

  local listY = py + 64 + 32
  Kit.beginFrame(px + 10, listY + 10, true) -- only visible row under the filter
  Events.draw(S, Kit, px, py)
  check(S.save.flags.EVENT_BEAT_BROCK == true, "Filtered row1 toggles the filtered-in event")
  check(S.save.flags.EVENT_ALPHA == nil, "Filter hides EVENT_ALPHA from row1's slot")

  local clearBtnX, clearBtnY = px + 320, py + 64
  Kit.beginFrame(clearBtnX + 10, clearBtnY + 10, true) -- Clear filter button
  Events.draw(S, Kit, px, py)
  eq(S.eventFilter, "", "Clear filter button resets eventFilter")
end

-- ===== Events: Flags pagination =====
do
  local S = State.new()
  S.events = {}
  for i = 1, 25 do
    S.events[i] = string.format("EVENT_%02d", i)
  end
  S.save = {
    flags = {}, defeatedTrainers = {}, itemsTaken = {}, objectToggles = {},
    party = {}, boxes = {},
  }

  local listY = py + 64 + 32
  local pagerY = listY + 10 * 22 + 8

  Kit.beginFrame(px + 100 + 10, pagerY + 10, true) -- Next button
  Events.draw(S, Kit, px, py)
  eq(S.eventsScroll, 10, "Next button scrolls by VISIBLE_ROWS")

  Kit.beginFrame(px + 10, listY + 10, true) -- row1 now maps to EVENT_11
  Events.draw(S, Kit, px, py)
  check(S.save.flags.EVENT_11 == true, "Row1 after scrolling toggles the 11th event")
  check(S.save.flags.EVENT_01 == nil, "First event untouched after scrolling")

  Kit.beginFrame(px + 10, pagerY + 10, true) -- Prev button
  Events.draw(S, Kit, px, py)
  eq(S.eventsScroll, 0, "Prev button scrolls back")
end

-- ===== Events: Trainers tab =====
do
  local S = State.new()
  S.events = {}
  S.save = {
    flags = {},
    defeatedTrainers = { PALLET_TOWN_obj_0 = true, ROUTE1_obj_2 = false },
    itemsTaken = {}, objectToggles = {}, party = {}, boxes = {},
  }

  local tabsY = py + 24
  local trainersTabX = px + 64 + 4 -- after the "Flags" tab (w = 8*5+24 = 64)
  Kit.beginFrame(trainersTabX + 10, tabsY + 10, true)
  Events.draw(S, Kit, px, py)
  eq(S.eventsTab, "trainers", "Trainers tab click switches sub-tab")

  local listY = py + 64 + 32
  Kit.beginFrame(px + 10, listY + 22 + 10, true) -- row2: ROUTE1_obj_2 (sorted after PALLET_TOWN_obj_0)
  Events.draw(S, Kit, px, py)
  check(S.save.defeatedTrainers.ROUTE1_obj_2 == true, "Trainers checkbox sets known key true")

  local pagerY = listY + 10 * 22 + 8
  local clearAllX = px + 400
  Kit.beginFrame(clearAllX + 10, pagerY + 10, true) -- Clear all trainers
  Events.draw(S, Kit, px, py)
  check(next(S.save.defeatedTrainers) == nil, "Clear all trainers empties the table")
end

-- ===== Events: Items taken tab =====
do
  local S = State.new()
  S.events = {}
  S.save = {
    flags = {}, defeatedTrainers = {},
    itemsTaken = { PALLET_TOWN_obj_1 = false },
    objectToggles = {}, party = {}, boxes = {},
  }

  local tabsY = py + 24
  local trainersTabX = px + 64 + 4
  local itemsTabX = trainersTabX + 88 + 4 -- after "Trainers" (w = 8*8+24 = 88)
  Kit.beginFrame(itemsTabX + 10, tabsY + 10, true)
  Events.draw(S, Kit, px, py)
  eq(S.eventsTab, "items", "Items taken tab click switches sub-tab")

  local listY = py + 64 + 32
  Kit.beginFrame(px + 10, listY + 10, true) -- row1: PALLET_TOWN_obj_1
  Events.draw(S, Kit, px, py)
  check(S.save.itemsTaken.PALLET_TOWN_obj_1 == true, "Items checkbox sets known key true")
end

-- ===== Events: Object toggles tab =====
do
  local S = State.new()
  S.events = {}
  S.save = {
    flags = {}, defeatedTrainers = {}, itemsTaken = {},
    objectToggles = { PALLET_TOWN = { OAK = false, SIGN = true } },
    party = {}, boxes = {},
  }

  local tabsY = py + 24
  local trainersTabX = px + 64 + 4
  local itemsTabX = trainersTabX + 88 + 4
  local togglesTabX = itemsTabX + 112 + 4 -- after "Items taken" (w = 8*11+24 = 112)
  Kit.beginFrame(togglesTabX + 10, tabsY + 10, true)
  Events.draw(S, Kit, px, py)
  eq(S.eventsTab, "toggles", "Object toggles tab click switches sub-tab")

  local listY = py + 64 + 32
  -- row1 is the "[PALLET_TOWN]" header (not clickable); row2/3 are OAK, SIGN (sorted)
  Kit.beginFrame(px + 10, listY + 22 + 10, true) -- row2: OAK (false -> true)
  Events.draw(S, Kit, px, py)
  check(S.save.objectToggles.PALLET_TOWN.OAK == true, "Toggle row flips OAK to true")

  Kit.beginFrame(px + 10, listY + 44 + 10, true) -- row3: SIGN (true -> false)
  Events.draw(S, Kit, px, py)
  check(S.save.objectToggles.PALLET_TOWN.SIGN == false, "Toggle row flips SIGN to false")

  -- clicking the header row (row1) must not error and must not touch data
  Kit.beginFrame(px + 10, listY + 10, true)
  local ok = pcall(Events.draw, S, Kit, px, py)
  check(ok, "Clicking the map header row does not error")
end

-- ===== Dex panel =====
do
  local S = State.new()
  S.cat = { species = { "BULBASAUR", "CHARMANDER", "SQUIRTLE" } }
  S.save = { party = {}, boxes = {}, pokedex = { seen = {}, owned = {} } }

  Kit.beginFrame(0, 0, false)
  Dex.draw(S, Kit, px, py)

  local seenX, ownedX = px + 220, px + 300
  local listY = py + 64 + 24

  Kit.beginFrame(seenX + 10, listY + 10, true) -- row1 seen: BULBASAUR
  Dex.draw(S, Kit, px, py)
  check(S.save.pokedex.seen.BULBASAUR == true, "Dex row1 seen checkbox sets BULBASAUR seen")

  Kit.beginFrame(ownedX + 10, listY + 10, true) -- row1 owned: BULBASAUR
  Dex.draw(S, Kit, px, py)
  check(S.save.pokedex.owned.BULBASAUR == true, "Dex row1 owned checkbox sets BULBASAUR owned")

  Kit.beginFrame(seenX + 10, listY + 10, true) -- uncheck seen
  Dex.draw(S, Kit, px, py)
  check(S.save.pokedex.seen.BULBASAUR == nil, "Unchecking seen clears BULBASAUR")
  check(S.save.pokedex.owned.BULBASAUR == nil, "Unchecking seen also clears owned (can't own unseen)")

  S.save.party = { { species = "CHARMANDER" } }
  S.save.boxes = { { { species = "SQUIRTLE" } } }
  Kit.beginFrame(px + 10, py + 24 + 10, true) -- Own party+boxes
  Dex.draw(S, Kit, px, py)
  check(S.save.pokedex.owned.CHARMANDER == true, "Own party+boxes marks party mon owned")
  check(S.save.pokedex.owned.SQUIRTLE == true, "Own party+boxes marks boxed mon owned")

  Kit.beginFrame(px + 190 + 10, py + 24 + 10, true) -- See all
  Dex.draw(S, Kit, px, py)
  check(S.save.pokedex.seen.BULBASAUR == true, "See all marks every species seen")

  Kit.beginFrame(px + 310 + 10, py + 24 + 10, true) -- Clear
  Dex.draw(S, Kit, px, py)
  check(next(S.save.pokedex.seen) == nil, "Clear empties seen")
  check(next(S.save.pokedex.owned) == nil, "Clear empties owned")
end

-- ===== Dex pagination =====
do
  local S = State.new()
  S.cat = { species = {} }
  for i = 1, 25 do
    S.cat.species[i] = string.format("SPECIES_%02d", i)
  end
  S.save = { party = {}, boxes = {}, pokedex = { seen = {}, owned = {} } }

  local seenX = px + 220
  local listY = py + 64 + 24
  local pagerY = listY + 12 * 22 + 8

  Kit.beginFrame(px + 100 + 10, pagerY + 10, true) -- Next
  Dex.draw(S, Kit, px, py)
  eq(S.dexScroll, 12, "Dex Next button scrolls by VISIBLE_ROWS")

  Kit.beginFrame(seenX + 10, listY + 10, true) -- row1 -> SPECIES_13
  Dex.draw(S, Kit, px, py)
  check(S.save.pokedex.seen.SPECIES_13 == true, "Row1 after scrolling toggles the 13th species")
  check(S.save.pokedex.seen.SPECIES_01 == nil, "First species untouched after scrolling")

  Kit.beginFrame(px + 10, pagerY + 10, true) -- Prev
  Dex.draw(S, Kit, px, py)
  eq(S.dexScroll, 0, "Dex Prev button scrolls back")
end

print(string.format("save editor task 7 tests: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
