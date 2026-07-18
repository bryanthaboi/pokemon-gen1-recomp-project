-- Headless tests for the Task 6 Boxes + Items save-editor panels.
-- Run from repo root: lua5.4 tests/save_editor_task6_tests.lua
-- (Standalone: does not require editing tests/run_save_editor_tests.lua.)

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

print("== save editor task 6 tests (Boxes + Items) ==")

local Data = require("src.core.Data")
Data:load()

local Catalog = require("Catalog")
local MonOps = require("MonOps")
local State = require("State")
local SaveData = require("src.core.SaveData")
local Kit = require("Kit")
local BoxesMod = require("src.pokemon.Boxes")
local PartyMod = require("src.pokemon.Party")
local Bag = require("src.inventory.Bag")

local Boxes = require("Boxes")
local Items = require("Items")

local function newState()
  local S = State.new()
  S.data = Data
  S.cat = Catalog.build(Data)
  S.save = SaveData.newGame()
  BoxesMod.ensure(S.save)
  return S
end

-- Boxes panel ---------------------------------------------------------

do
  local S = newState()
  local px, py = 12, 80

  -- Add new mon to box 1
  local listH = BoxesMod.CAPACITY * 18
  local actionsY = py + 34 + listH + 10
  Kit.beginFrame(px + 220 + 10, actionsY + 10, true) -- "Add new mon" button
  Boxes.draw(S, Kit, px, py)
  eq(#S.save.boxes[1], 1, "Boxes Add new mon appends to box 1")
  check(S.dirty == true, "Boxes Add new mon marks dirty")
  S.dirty = false

  -- Select the mon in the box list (row 1) to set editingMon
  Kit.beginFrame(px + 10, py + 34 + 5, true) -- row 1 of the box list
  Boxes.draw(S, Kit, px, py)
  eq(S.selectedBoxSlot, 1, "Boxes list click selects slot")
  check(S.editingMon == S.save.boxes[1][1], "Boxes list click sets editingMon")

  -- Withdraw the selected box mon into the (empty) party
  Kit.beginFrame(px + 10, actionsY + 10, true) -- "Withdraw" button
  Boxes.draw(S, Kit, px, py)
  eq(#S.save.party, 1, "Boxes Withdraw moves mon into party")
  eq(#S.save.boxes[1], 0, "Boxes Withdraw removes mon from box")

  -- Deposit that party mon back into the box
  local depositY = actionsY + 40
  Kit.beginFrame(px + 440 + 10, depositY + 10, true) -- "Deposit" button
  Boxes.draw(S, Kit, px, py)
  eq(#S.save.party, 0, "Boxes Deposit removes mon from party")
  eq(#S.save.boxes[1], 1, "Boxes Deposit places mon back in box 1")

  -- Release the mon from the box
  Kit.beginFrame(px + 110 + 10, actionsY + 10, true) -- "Release" button
  Boxes.draw(S, Kit, px, py)
  eq(#S.save.boxes[1], 0, "Boxes Release removes mon from box")
  check(S.editingMon == nil, "Boxes Release clears editingMon for released mon")

  -- Box navigation with "<" / ">"
  eq(S.selectedBox, 1, "starts on box 1")
  Kit.beginFrame(px + 230 + 10, py + 10, true) -- ">" button
  Boxes.draw(S, Kit, px, py)
  eq(S.selectedBox, 2, "Boxes '>' advances to box 2")
  Kit.beginFrame(px + 10, py + 10, true) -- "<" button
  Boxes.draw(S, Kit, px, py)
  eq(S.selectedBox, 1, "Boxes '<' returns to box 1")
end

do
  -- Withdraw refuses when the party is full
  local S = newState()
  for i = 1, PartyMod.MAX do
    table.insert(S.save.party, MonOps.create(Data, "RATTATA", 5))
  end
  table.insert(S.save.boxes[1], MonOps.create(Data, "PIDGEY", 5))

  local px, py = 12, 80
  local listH = BoxesMod.CAPACITY * 18
  local actionsY = py + 34 + listH + 10
  Kit.beginFrame(px + 10, actionsY + 10, true) -- "Withdraw" button
  Boxes.draw(S, Kit, px, py)
  eq(#S.save.party, PartyMod.MAX, "Boxes Withdraw is a no-op when party is full")
  eq(#S.save.boxes[1], 1, "Boxes Withdraw leaves mon in box when party is full")
end

-- Items panel -----------------------------------------------------------

do
  local S = newState()
  local px, py = 12, 80

  local moneyBefore = S.save.money
  local moneyBtnY = py + 22
  Kit.beginFrame(px + 132 + 10, moneyBtnY + 10, true) -- "+10" button
  Items.draw(S, Kit, px, py)
  eq(S.save.money, moneyBefore + 10, "Items +10 money button")
  check(S.dirty == true, "Items money change marks dirty")
  S.dirty = false

  Kit.beginFrame(px + 10, moneyBtnY + 10, true) -- "-100" button (money >= 0 clamp)
  Items.draw(S, Kit, px, py)
  eq(S.save.money, moneyBefore + 10 - 100 < 0 and 0 or moneyBefore + 10 - 100,
    "Items -100 money button clamps at 0")

  -- Item picker cycles and adds to bag / PC
  local pickerY = moneyBtnY + 40
  local pickIdBefore = S.cat.items[S.itemPickerIdx or 1]
  Kit.beginFrame(px + 280 + 10, pickerY + 10, true) -- ">" cycles picker
  Items.draw(S, Kit, px, py)
  check(S.cat.items[S.itemPickerIdx] ~= pickIdBefore or #S.cat.items == 1,
    "Items picker '>' advances selection")

  -- point the picker at a known item id for deterministic add/remove checks
  for i, id in ipairs(S.cat.items) do
    if id == "MASTER_BALL" then S.itemPickerIdx = i break end
  end
  Kit.beginFrame(px + 320 + 10, pickerY + 10, true) -- "Add to Bag"
  Items.draw(S, Kit, px, py)
  eq(S.save.inventory.MASTER_BALL, 1, "Items Add to Bag adds MASTER_BALL to inventory")
  check(S.dirty == true, "Items Add to Bag marks dirty")
  S.dirty = false

  Kit.beginFrame(px + 440 + 10, pickerY + 10, true) -- "Add to PC"
  Items.draw(S, Kit, px, py)
  eq(S.save.pcItems.MASTER_BALL, 1, "Items Add to PC adds MASTER_BALL to pcItems")

  -- Bag list remove
  local bagLabelY = pickerY + 40
  local bagListY = bagLabelY + 20
  local bagPagerY = bagListY + 200 + 8
  local bagActionsY = bagPagerY + 34
  local order = Bag.order(S.save)
  local idx = nil
  for i, id in ipairs(order) do if id == "MASTER_BALL" then idx = i end end
  check(idx ~= nil, "MASTER_BALL present in bag order")
  S.selectedBagIdx = idx
  Kit.beginFrame(px + 10, bagActionsY + 10, true) -- "Remove 1"
  Items.draw(S, Kit, px, py)
  check(S.save.inventory.MASTER_BALL == nil, "Items bag Remove 1 clears single-qty MASTER_BALL")

  -- PC list remove all
  S.save.pcItems.MASTER_BALL = 5
  local pcLabelY = bagActionsY + 40
  local pcListY = pcLabelY + 20
  local pcPagerY = pcListY + 200 + 8
  local pcActionsY = pcPagerY + 34
  local pcOrder = {}
  for id in pairs(S.save.pcItems) do table.insert(pcOrder, id) end
  table.sort(pcOrder)
  local pidx = nil
  for i, id in ipairs(pcOrder) do if id == "MASTER_BALL" then pidx = i end end
  S.selectedPcIdx = pidx
  Kit.beginFrame(px + 110 + 10, pcActionsY + 10, true) -- "Remove all"
  Items.draw(S, Kit, px, py)
  check(S.save.pcItems.MASTER_BALL == nil, "Items PC Remove all clears MASTER_BALL")

  -- Badges toggle directly on inventory
  local badgeLabelY = pcActionsY + 40
  local badgeY = badgeLabelY + 20
  check(S.save.inventory.BOULDERBADGE == nil, "BOULDERBADGE starts unset")
  Kit.beginFrame(px + 10, badgeY + 10, true) -- first badge button
  Items.draw(S, Kit, px, py)
  check(S.save.inventory.BOULDERBADGE == true, "Items badge toggle sets inventory flag")
  Kit.beginFrame(px + 10, badgeY + 10, true) -- toggle again
  Items.draw(S, Kit, px, py)
  check(S.save.inventory.BOULDERBADGE == nil, "Items badge toggle clears inventory flag")
end

do
  -- Bag cap: 20 distinct slots max (Bag.add returns false past capacity)
  local S = newState()
  local px, py = 12, 80
  local pickerY = py + 22 + 40
  for i = 1, Bag.CAPACITY do
    S.save.inventory["FILLER_ITEM_" .. i] = 1
    table.insert(Bag.order(S.save), "FILLER_ITEM_" .. i)
  end
  eq(Bag.slots(S.save), Bag.CAPACITY, "bag pre-filled to capacity")

  for i, id in ipairs(S.cat.items) do
    if id == "MASTER_BALL" then S.itemPickerIdx = i break end
  end
  Kit.beginFrame(px + 320 + 10, pickerY + 10, true) -- "Add to Bag"
  Items.draw(S, Kit, px, py)
  check(S.save.inventory.MASTER_BALL == nil, "Items Add to Bag refuses a new slot past capacity")
end

do
  -- Bag/PC pagination: Prev/Next reach slots beyond the first VISIBLE_ROWS
  -- (10), so all 20 bag slots stay selectable (Important fix #1).
  local S = newState()
  local px, py = 12, 80
  local moneyBtnY = py + 22
  local pickerY = moneyBtnY + 40
  local bagLabelY = pickerY + 40
  local bagListY = bagLabelY + 20
  local bagPagerY = bagListY + 200 + 8

  for i = 1, Bag.CAPACITY do
    local id = "FILLER_ITEM_" .. i
    S.save.inventory[id] = 1
    table.insert(Bag.order(S.save), id)
  end

  Kit.beginFrame(0, 0, false)
  Items.draw(S, Kit, px, py)
  eq(S.bagScroll, 0, "Bag list starts on page 1 (unscrolled)")

  Kit.beginFrame(px + 100 + 10, bagPagerY + 10, true) -- "Next"
  Items.draw(S, Kit, px, py)
  eq(S.bagScroll, 10, "Bag 'Next' pager advances by VISIBLE_ROWS")

  -- Row 10 of page 2 (scroll=10) is absolute slot 20, the last bag slot.
  Kit.beginFrame(px + 10, bagListY + 9 * 20 + 5, true)
  Items.draw(S, Kit, px, py)
  eq(S.selectedBagIdx, 20, "Bag list click on page 2 reaches slot 20")

  Kit.beginFrame(px + 10, bagPagerY + 34 + 10, true) -- "Remove 1" on slot 20
  Items.draw(S, Kit, px, py)
  check(S.save.inventory.FILLER_ITEM_20 == nil, "Bag Remove 1 clears the paged-to slot")

  Kit.beginFrame(px + 10, bagPagerY + 10, true) -- "Prev"
  Items.draw(S, Kit, px, py)
  eq(S.bagScroll, 0, "Bag 'Prev' pager returns to page 1")
end

print(string.format("save editor task 6 tests: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
