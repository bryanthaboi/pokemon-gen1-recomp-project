-- Parity test, Bill's House PC + Route25ToggleBillsScript (#120).
--
-- asm sources:
--   engine/events/hidden_events/bills_house_pc.asm (BillsHousePC /
--     BillsHousePokemonList: after EVENT_LEFT_BILLS_HOUSE_AFTER_HELPING
--     the PC opens EEVEE/FLAREON/JOLTEON/VAPOREON; before that the
--     teleporter monitor text or cell-separator cutscene)
--   scripts/Route25.asm (Route25ToggleBillsScript: first Route 25 load
--     after EVENT_MET_BILL_2 + EVENT_GOT_SS_TICKET sets
--     EVENT_LEFT_BILLS_HOUSE_AFTER_HELPING, hides BILL1 / nugget-bridge
--     guy, shows BILL2; mid-quest leave resets the separator flag)
--
-- Self-contained: run via `luajit tests/parity_bills_pc.lua`; also
-- dofile'd by tests/run_tests.lua's aggregator.
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end
local S = require("tests.harness").suite("parity bills pc")
local check, eq = S.check, S.eq

local OW = require("src.world.OverworldController")
local SaveData = require("src.core.SaveData")
local story = require("data.scripts.story")

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

local pushed = {}
local stackStub = {
  push = function(_, item)
    pushed[#pushed + 1] = item
  end,
}
local textBoxStub = {
  new = function(_, text, onDone)
    local box = { kind = "text", text = text, onDone = onDone }
    if onDone then onDone() end
    return box
  end,
}
local menuStub = {
  new = function(_, items, opts)
    return { kind = "menu", items = items, opts = opts or {} }
  end,
}
local screensStub = {
  push = function(_, id, species)
    pushed[#pushed + 1] = { kind = "screen", id = id, species = species }
  end,
}

local fakeGame = {
  data = Data,
  save = SaveData.newGame(),
  stack = stackStub,
}
check(setUpvalue(OW.billsHousePC, "TextBox", textBoxStub), "TextBox upvalue")
check(setUpvalue(OW.billsHousePC, "Game", fakeGame), "Game upvalue for PC")
-- Screens is only referenced from billsHousePokemonList
check(setUpvalue(OW.billsHousePokemonList, "Screens", screensStub),
      "Screens upvalue on pokemon list")
check(setUpvalue(OW.billsHousePokemonList, "Game", fakeGame),
      "Game upvalue on pokemon list")
check(setUpvalue(OW.billsHousePokemonList, "TextBox", textBoxStub),
      "TextBox upvalue on pokemon list")

-- Menu is required inside billsHousePokemonList; stub via package.loaded
local realMenu = package.loaded["src.ui.Menu"]
package.loaded["src.ui.Menu"] = menuStub

local fakeSelf = setmetatable({
  queueScript = function() end,
  billsHouseBillExits = function() end,
}, { __index = OW })

local function resetFlags()
  fakeGame.save = SaveData.newGame()
  setUpvalue(OW.billsHousePC, "Game", fakeGame)
  pushed = {}
end

local function lastPush()
  return pushed[#pushed]
end

local function runPC()
  pushed = {}
  fakeSelf:billsHousePC()
end

-- === 1) default: teleporter monitor text ===
resetFlags()
runPC()
eq(lastPush() and lastPush().kind, "text", "default PC is a text box")
check(tostring(lastPush().text):find("TELEPORTER", 1, true)
      or tostring(lastPush().text):find("displayed on the", 1, true),
      "default PC shows monitor text")

-- === 2) Bill in machine, separator not used yet: initiated text ===
resetFlags()
fakeGame.save.flags.EVENT_BILL_SAID_USE_CELL_SEPARATOR = true
local musicStopped = false
local realMusic = package.loaded["src.core.Music"]
package.loaded["src.core.Music"] = {
  stop = function() musicStopped = true end,
  playMap = function() end,
}
local realSound = package.loaded["src.core.Sound"]
package.loaded["src.core.Sound"] = {
  play = function() end,
  playCry = function() end,
}
runPC()
check(musicStopped, "cell separator stops map music")
check(tostring(lastPush().text):find("Cell", 1, true)
      or tostring(lastPush().text):find("TELEPORTER", 1, true),
      "separator path prints initiated text")
check(fakeGame.save.flags.EVENT_USED_CELL_SEPARATOR_ON_BILL,
      "separator path sets EVENT_USED_CELL_SEPARATOR_ON_BILL")

-- === 3) after separator, before leaving: monitor text again ===
resetFlags()
fakeGame.save.flags.EVENT_BILL_SAID_USE_CELL_SEPARATOR = true
fakeGame.save.flags.EVENT_USED_CELL_SEPARATOR_ON_BILL = true
fakeGame.save.flags.EVENT_MET_BILL = true
runPC()
check(tostring(lastPush().text):find("TELEPORTER", 1, true)
      or tostring(lastPush().text):find("displayed on the", 1, true),
      "post-separator pre-leave PC shows monitor text")

-- === 4) after leaving: Eevee collection menu ===
resetFlags()
fakeGame.save.flags.EVENT_LEFT_BILLS_HOUSE_AFTER_HELPING = true
runPC()
local menu
for _, p in ipairs(pushed) do
  if p.kind == "menu" then menu = p break end
end
check(menu ~= nil, "post-leave PC opens a menu")
local labels = {}
for _, item in ipairs(menu.items) do labels[#labels + 1] = item.label end
eq(table.concat(labels, ","), "EEVEE,FLAREON,JOLTEON,VAPOREON,CANCEL",
   "Eevee collection lists the four mons + CANCEL")

-- selecting EEVEE marks seen and opens DexEntryMenu without closing list
fakeGame.save.pokedex = { seen = {}, owned = {} }
menu.items[1].onSelect()
check(fakeGame.save.pokedex.seen.EEVEE, "viewing marks EEVEE seen")
local dexPush
for i = #pushed, 1, -1 do
  if pushed[i].kind == "screen" then dexPush = pushed[i] break end
end
eq(dexPush and dexPush.id, "DexEntryMenu", "selection opens DexEntryMenu")
eq(dexPush and dexPush.species, "EEVEE", "DexEntryMenu gets EEVEE")
check(menu.items[1].keepOpen, "dex pick keeps the list open")

-- === 5) Route25ToggleBillsScript ===
local toggles = {}
local Commands = require("src.script.Commands")
local realHide, realShow = Commands.hide_object, Commands.show_object
Commands.hide_object = function(_, mapId, name)
  toggles[mapId .. ":" .. name] = false
end
Commands.show_object = function(_, mapId, name)
  toggles[mapId .. ":" .. name] = true
end

local function runRoute25(flags)
  toggles = {}
  local save = SaveData.newGame()
  for k, v in pairs(flags) do save.flags[k] = v end
  story.ROUTE_25.onEnter({ save = save }, {})
  return save.flags, toggles
end

local f, t = runRoute25({})
check(not f.EVENT_LEFT_BILLS_HOUSE_AFTER_HELPING,
      "no leave flag before meeting Bill")
check(t["BILLS_HOUSE:BILLSHOUSE_BILL_POKEMON"] == true,
      "mid-quest leave restores monster Bill")
check(f.EVENT_BILL_SAID_USE_CELL_SEPARATOR == nil,
      "mid-quest leave clears separator arming flag")

f, t = runRoute25({ EVENT_MET_BILL_2 = true })
check(not f.EVENT_LEFT_BILLS_HOUSE_AFTER_HELPING,
      "MET_BILL_2 without ticket does not arm leave flag")

f, t = runRoute25({
  EVENT_MET_BILL_2 = true,
  EVENT_GOT_SS_TICKET = true,
})
check(f.EVENT_LEFT_BILLS_HOUSE_AFTER_HELPING,
      "ticket + MET_BILL_2 arms EVENT_LEFT_BILLS_HOUSE_AFTER_HELPING")
eq(t["BILLS_HOUSE:BILLSHOUSE_BILL1"], false, "hides SS-Ticket Bill")
eq(t["BILLS_HOUSE:BILLSHOUSE_BILL2"], true, "shows rare-POKéMON Bill")
eq(t["ROUTE_24:ROUTE24_COOLTRAINER_M1"], false, "hides nugget-bridge guy")

f, t = runRoute25({
  EVENT_LEFT_BILLS_HOUSE_AFTER_HELPING = true,
  EVENT_MET_BILL_2 = true,
  EVENT_GOT_SS_TICKET = true,
})
eq(next(t), nil, "already-left Route 25 enter is a no-op")

Commands.hide_object = realHide
Commands.show_object = realShow
package.loaded["src.ui.Menu"] = realMenu
if realMusic ~= nil then package.loaded["src.core.Music"] = realMusic end
if realSound ~= nil then package.loaded["src.core.Sound"] = realSound end

S.finish()
