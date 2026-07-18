-- Modal-ish inspector for S.editingMon (set by Party/Boxes): level, DVs,
-- moves and species, all recalculated through MonOps so stats stay in sync
-- with the Gen1 formulas.

local Pokemon = require("src.pokemon.Pokemon")
local MonOps = require("MonOps")

local MonEditor = {}

local DV_KEYS = { "attack", "defense", "speed", "special" }

local function mark(S)
  S.dirty = true
end

local function findIndex(list, value)
  for i, v in ipairs(list) do
    if v == value then return i end
  end
  return nil
end

local function setLevel(S, mon, level)
  MonOps.setLevel(S.data, mon, level)
  mark(S)
end

local function adjustDv(S, mon, key, delta)
  MonOps.setDv(S.data, mon, key, mon.dvs[key] + delta)
  mark(S)
end

local function cycleMove(S, mon, slot)
  local moves = S.cat.moves
  local current = mon.moves[slot] and mon.moves[slot].id
  local idx = (current and findIndex(moves, current)) or 0
  local nextId = moves[(idx % #moves) + 1]
  MonOps.setMove(S.data, mon, slot, nextId)
  mark(S)
end

function MonEditor.draw(S, Kit, x, y)
  local mon = S.editingMon
  if not mon then return end
  local def = S.data.pokemon[mon.species]

  love.graphics.setColor(0.05, 0.05, 0.07)
  love.graphics.rectangle("fill", x - 8, y - 8, 604, 700)

  local ok, img = pcall(love.graphics.newImage, def.spriteFront)
  if ok then
    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(img, x, y, 0, 2, 2)
  end

  Kit.label(x + 140, y, mon.species)
  Kit.label(x + 140, y + 18, string.format("Lv %d   Exp %d", mon.level, mon.exp))
  Kit.label(x + 140, y + 36, string.format("HP %d/%d", mon.hp, mon.stats.hp))
  Kit.label(x + 140, y + 54, string.format("Atk %d Def %d Spd %d Spc %d",
    mon.stats.attack, mon.stats.defense, mon.stats.speed, mon.stats.special))

  Kit.label(x, y + 90, "Level")
  if Kit.button(x + 60, y + 84, 40, 26, "-5") then setLevel(S, mon, mon.level - 5) end
  if Kit.button(x + 104, y + 84, 40, 26, "-1") then setLevel(S, mon, mon.level - 1) end
  if Kit.button(x + 148, y + 84, 40, 26, "+1") then setLevel(S, mon, mon.level + 1) end
  if Kit.button(x + 192, y + 84, 40, 26, "+5") then setLevel(S, mon, mon.level + 5) end

  if Kit.button(x + 250, y + 84, 130, 26, "Next species") then
    local idx = findIndex(S.cat.species, mon.species) or 0
    MonOps.setSpecies(S.data, mon, S.cat.species[(idx % #S.cat.species) + 1])
    mark(S)
  end

  Kit.label(x, y + 130, "DVs (HP DV auto-derived)")
  local dvY = y + 154
  for i, key in ipairs(DV_KEYS) do
    local ry = dvY + (i - 1) * 30
    Kit.label(x, ry + 5, key .. ": " .. mon.dvs[key])
    if Kit.button(x + 130, ry, 26, 26, "-") then adjustDv(S, mon, key, -1) end
    if Kit.button(x + 160, ry, 26, 26, "+") then adjustDv(S, mon, key, 1) end
  end
  local hpDvY = dvY + #DV_KEYS * 30 + 6
  Kit.label(x, hpDvY, "hp: " .. mon.dvs.hp)

  local movesY = hpDvY + 34
  Kit.label(x, movesY, "Moves (click a slot to cycle)")
  for slot = 1, 4 do
    local ry = movesY + 24 + (slot - 1) * 30
    local mv = mon.moves[slot]
    local text = mv and string.format("%d. %s  PP %d", slot, mv.id, mv.pp)
      or (slot .. ". --")
    if Kit.button(x, ry, 320, 26, text) then
      cycleMove(S, mon, slot)
    end
  end

  local actionsY = movesY + 24 + 4 * 30 + 10
  if Kit.button(x, actionsY, 220, 28, "Reset moves to learnset") then
    local learned = Pokemon.movesAtLevel(def, mon.level)
    mon.moves = {}
    for slot, id in ipairs(learned) do
      MonOps.setMove(S.data, mon, slot, id)
    end
    mark(S)
  end

  if Kit.button(x, actionsY + 38, 100, 28, "Close") then
    S.editingMon = nil
  end
end

return MonEditor
