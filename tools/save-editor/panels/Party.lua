-- Party panel: lists the active party with add/remove/reorder controls and
-- selects a mon for the MonEditor overlay (App.lua draws that when
-- S.editingMon is set).

local MonOps = require("MonOps")
local PartyMod = require("src.pokemon.Party")

local Party = {}

local function mark(S)
  S.dirty = true
end

function Party.draw(S, Kit, x, y)
  local lines = {}
  for i, mon in ipairs(S.save.party) do
    lines[i] = string.format("%d. %-12s Lv%-3d HP %d/%d",
      i, mon.species, mon.level, mon.hp, mon.stats.hp)
  end

  Kit.label(x, y, string.format("Party (%d/%d)", #S.save.party, PartyMod.MAX))
  local click = Kit.list(x, y + 24, 360, 160, lines, S.selectedParty)
  if click then
    S.selectedParty = click
    S.editingMon = S.save.party[click]
  end

  if Kit.button(x, y + 200, 100, 28, "Add") then
    if #S.save.party < PartyMod.MAX then
      local species = S.cat.species[1]
      local mon = MonOps.create(S.data, species, 5)
      mon.ot = S.save.player.name
      mon.otId = S.save.player.id
      table.insert(S.save.party, mon)
      S.selectedParty = #S.save.party
      mark(S)
    end
  end

  if Kit.button(x + 110, y + 200, 100, 28, "Remove") then
    local mon = S.save.party[S.selectedParty]
    if mon then
      table.remove(S.save.party, S.selectedParty)
      if S.editingMon == mon then S.editingMon = nil end
      S.selectedParty = math.min(S.selectedParty, #S.save.party)
      if S.selectedParty < 1 then S.selectedParty = 1 end
      mark(S)
    end
  end

  if Kit.button(x + 220, y + 200, 90, 28, "Move Up") then
    local i = S.selectedParty
    if i and i > 1 and S.save.party[i] then
      S.save.party[i], S.save.party[i - 1] = S.save.party[i - 1], S.save.party[i]
      S.selectedParty = i - 1
      mark(S)
    end
  end

  if Kit.button(x + 320, y + 200, 100, 28, "Move Down") then
    local i = S.selectedParty
    if i and S.save.party[i] and S.save.party[i + 1] then
      S.save.party[i], S.save.party[i + 1] = S.save.party[i + 1], S.save.party[i]
      S.selectedParty = i + 1
      mark(S)
    end
  end
end

return Party
