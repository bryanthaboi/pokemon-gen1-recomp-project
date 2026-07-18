-- Boxes panel: browse the 12 PC boxes (Boxes.ensure/deposit), move mons
-- between the active box and the party, and select a box mon for the
-- MonEditor overlay (App.lua draws that when S.editingMon is set).

local Boxes = require("src.pokemon.Boxes")
local PartyMod = require("src.pokemon.Party")
local MonOps = require("MonOps")

local M = {}

local ROW_H = 18
local LIST_H = Boxes.CAPACITY * ROW_H

local function mark(S)
  S.dirty = true
end

local function clamp(n, lo, hi)
  if n < lo then return lo end
  if n > hi then return hi end
  return n
end

local function boxLines(box)
  local lines = {}
  for i, mon in ipairs(box) do
    lines[i] = string.format("%d. %-12s Lv%-3d HP %d/%d",
      i, mon.species, mon.level, mon.hp, mon.stats.hp)
  end
  return lines
end

function M.draw(S, Kit, x, y)
  local boxes = Boxes.ensure(S.save)
  S.selectedBox = clamp(S.selectedBox or 1, 1, Boxes.COUNT)
  S.save.currentBox = S.selectedBox
  local box = boxes[S.selectedBox]

  if Kit.button(x, y, 30, 26, "<") then
    S.selectedBox = ((S.selectedBox - 2) % Boxes.COUNT) + 1
    S.selectedBoxSlot = 1
  end
  Kit.label(x + 40, y + 5, string.format("Box %d/%d  (%d/%d)",
    S.selectedBox, Boxes.COUNT, #box, Boxes.CAPACITY))
  if Kit.button(x + 230, y, 30, 26, ">") then
    S.selectedBox = (S.selectedBox % Boxes.COUNT) + 1
    S.selectedBoxSlot = 1
  end

  local listY = y + 34
  S.selectedBoxSlot = clamp(S.selectedBoxSlot or 1, 1, math.max(#box, 1))
  local click = Kit.list(x, listY, 360, LIST_H, boxLines(box), S.selectedBoxSlot, ROW_H)
  if click then
    S.selectedBoxSlot = click
    S.editingMon = box[click]
  end

  local actionsY = listY + LIST_H + 10
  if Kit.button(x, actionsY, 100, 28, "Withdraw") then
    local mon = box[S.selectedBoxSlot]
    if mon and #S.save.party < PartyMod.MAX then
      table.remove(box, S.selectedBoxSlot)
      table.insert(S.save.party, mon)
      S.selectedBoxSlot = clamp(S.selectedBoxSlot, 1, math.max(#box, 1))
      mark(S)
    end
  end

  if Kit.button(x + 110, actionsY, 100, 28, "Release") then
    local mon = box[S.selectedBoxSlot]
    if mon then
      table.remove(box, S.selectedBoxSlot)
      if S.editingMon == mon then S.editingMon = nil end
      S.selectedBoxSlot = clamp(S.selectedBoxSlot, 1, math.max(#box, 1))
      mark(S)
    end
  end

  if Kit.button(x + 220, actionsY, 140, 28, "Add new mon") then
    if #box < Boxes.CAPACITY then
      local species = S.cat.species[1]
      local mon = MonOps.create(S.data, species, 5)
      mon.ot = S.save.player.name
      mon.otId = S.save.player.id
      table.insert(box, mon)
      S.selectedBoxSlot = #box
      mark(S)
    end
  end

  local depositY = actionsY + 40
  S.selectedParty = clamp(S.selectedParty or 1, 1, math.max(#S.save.party, 1))
  local partyMon = S.save.party[S.selectedParty]
  Kit.label(x, depositY + 5, "Deposit party slot:")
  if Kit.button(x + 160, depositY, 26, 26, "<") then
    if #S.save.party > 0 then
      S.selectedParty = ((S.selectedParty - 2) % #S.save.party) + 1
    end
  end
  Kit.label(x + 196, depositY + 5, partyMon
    and string.format("%d. %s Lv%d", S.selectedParty, partyMon.species, partyMon.level)
    or "(party empty)")
  if Kit.button(x + 400, depositY, 26, 26, ">") then
    if #S.save.party > 0 then
      S.selectedParty = (S.selectedParty % #S.save.party) + 1
    end
  end
  if Kit.button(x + 440, depositY, 110, 28, "Deposit") then
    local i = S.selectedParty
    local mon = S.save.party[i]
    if mon then
      local boxNum = Boxes.deposit(S.save, mon)
      if boxNum then
        table.remove(S.save.party, i)
        S.selectedParty = clamp(i, 1, math.max(#S.save.party, 1))
        S.selectedBox = boxNum
        mark(S)
      end
    end
  end
end

return M
