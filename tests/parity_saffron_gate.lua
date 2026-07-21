-- Parity test: the Saffron gate guards take the drink from the COORD
-- TRIGGER, not only when talked to.
--
-- Route5GateDefaultScript (scripts/Route5Gate.asm) runs
--
--     farcall RemoveGuardDrink
--     ldh a, [hItemToRemoveID]
--     and a
--     jr nz, .have_drink
--
-- before it decides anything, so simply stepping onto the trigger while
-- carrying FRESH_WATER / SODA_POP / LEMONADE hands it over and sets
-- BIT_GAVE_SAFFRON_GUARDS_DRINK.  Only a player carrying none of the three
-- gets the "Gee, I'm thirsty" line and the walk-back.
--
-- Our port had the removal on the guard's talk handler alone, so walking up
-- with a drink in the bag was turned away and all four gates stayed shut
-- unless the player happened to talk to him -- which vanilla never asks
-- for.  Saffron is the middle of the map, so this sealed the city: Celadon
-- <-> Lavender and the short Vermilion <-> Cerulean crossing both route
-- through it, and the route bot could not reach Lavender for the POKE_FLUTE
-- at all ("travelTo: no route to MR_FUJIS_HOUSE").
--
-- Self-contained; run via `luajit tests/parity_saffron_gate.lua`.
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
local S = require("tests.harness").suite("parity saffron gate")
local check, eq = S.check, S.eq

-- The gate pushes real TextBoxes, which want a loaded Font atlas; the
-- decision under test is which branch runs, not how the text renders.
package.loaded["src.render.TextBox"] = {
  new = function(_, text, done) return { text = text, done = done } end,
}

local M = dofile("data/scripts/story2.lua")

-- Enough of a game for the gate's onStep: an inventory, flags, a stack that
-- records what was pushed, and a player that records being shoved back.
local function gameWith(inventory)
  local pushed, moved = {}, {}
  return {
    save = { inventory = inventory, flags = {} },
    data = { text = {} },
    stack = { push = function(_, box) pushed[#pushed + 1] = box end },
    _pushed = pushed,
    _moved = moved,
  }, pushed, moved
end

local function owWith(moved)
  return {
    player = { facing = "up" },
    scriptMove = function(_, _, dir, n) moved[#moved + 1] = { dir, n } end,
  }
end

-- ROUTE_5_GATE's trigger cells are (3,3) and (4,3) (.PlayerInCoordsArray).
local gate = M.ROUTE_5_GATE
check(gate ~= nil and gate.onStep ~= nil, "ROUTE_5_GATE has a coord trigger")

-- Carrying a drink: the trigger takes it and lets us through.
for _, drink in ipairs({ "FRESH_WATER", "SODA_POP", "LEMONADE" }) do
  local game, pushed, moved = gameWith({ [drink] = 1 })
  local ow = owWith(moved)
  local handled = gate.onStep(game, ow, 3, 3)
  check(handled, drink .. ": stepping on the trigger is handled")
  check(game.save.flags.EVENT_GAVE_GUARDS_DRINK,
        drink .. ": the guards are marked as having been given a drink")
  eq(game.save.inventory[drink], nil, drink .. ": exactly one was removed")
  check(#pushed == 1, drink .. ": the thanks text is shown")
  check(#moved == 0, drink .. ": we are NOT walked back")
end

-- Only ONE drink is taken, even holding several.
do
  local game = gameWith({ FRESH_WATER = 2, LEMONADE = 1 })
  gate.onStep(game, owWith({}), 3, 3)
  eq(game.save.inventory.FRESH_WATER, 1, "only one drink is consumed")
  eq(game.save.inventory.LEMONADE, 1, "the other drinks are untouched")
end

-- Carrying nothing: thirsty line, and we get walked back the way we came.
do
  local game, pushed, moved = gameWith({})
  local ow = owWith(moved)
  local handled = gate.onStep(game, ow, 3, 3)
  check(handled, "no drink: the trigger still fires")
  check(not game.save.flags.EVENT_GAVE_GUARDS_DRINK,
        "no drink: the flag is NOT set")
  check(#pushed == 1, "no drink: the thirsty text is shown")
  -- the shove happens when the text box closes, not while it is up
  if pushed[1] and pushed[1].done then pushed[1].done() end
  check(#moved == 1 and moved[1][1] == "down",
        "no drink: we are walked back the way we came")
end

-- Once given, the gate is open for good and stops triggering.
do
  local game, pushed = gameWith({})
  game.save.flags.EVENT_GAVE_GUARDS_DRINK = true
  eq(gate.onStep(game, owWith({}), 3, 3), false,
     "after the drink the trigger no longer blocks")
  check(#pushed == 0, "and shows nothing")
end

-- Cells that are not trigger cells are ignored.
do
  local game = gameWith({ FRESH_WATER = 1 })
  eq(gate.onStep(game, owWith({}), 9, 9), false, "a non-trigger cell is ignored")
  eq(game.save.inventory.FRESH_WATER, 1, "and takes no drink")
end

-- All four gates carry the same behaviour -- one drink opens every one.
for _, id in ipairs({ "ROUTE_5_GATE", "ROUTE_6_GATE",
                      "ROUTE_7_GATE", "ROUTE_8_GATE" }) do
  check(M[id] and M[id].onStep, id .. " has the guard trigger")
end

S.finish()
