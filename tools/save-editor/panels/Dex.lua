-- Pokédex panel: seen/owned checkboxes for every species in the catalog,
-- plus bulk actions to stamp the dex from the current party/boxes, mark
-- everything seen, or wipe it.

local M = {}

local ROW_H = 22
local VISIBLE_ROWS = 12

local function mark(S)
  S.dirty = true
end

local function ensureDex(S)
  S.save.pokedex = S.save.pokedex or { seen = {}, owned = {} }
  return S.save.pokedex
end

local function stampOwnedFromSave(S)
  local dex = ensureDex(S)
  local function markMon(mon)
    dex.seen[mon.species] = true
    dex.owned[mon.species] = true
  end
  for _, m in ipairs(S.save.party) do markMon(m) end
  for _, box in ipairs(S.save.boxes or {}) do
    for _, m in ipairs(box) do markMon(m) end
  end
  mark(S)
end

local function seeAll(S)
  local dex = ensureDex(S)
  for _, species in ipairs(S.cat.species) do
    dex.seen[species] = true
  end
  mark(S)
end

local function clearDex(S)
  S.save.pokedex = { seen = {}, owned = {} }
  mark(S)
end

local function clampScroll(S, total)
  S.dexScroll = S.dexScroll or 0
  local maxScroll = math.max(0, total - VISIBLE_ROWS)
  if S.dexScroll > maxScroll then S.dexScroll = maxScroll end
  if S.dexScroll < 0 then S.dexScroll = 0 end
  return S.dexScroll
end

function M.draw(S, Kit, x, y)
  local dex = ensureDex(S)
  local species = S.cat.species

  Kit.label(x, y, string.format("Pokedex (%d species)", #species))

  if Kit.button(x, y + 24, 180, 28, "Own party+boxes") then
    stampOwnedFromSave(S)
  end
  if Kit.button(x + 190, y + 24, 110, 28, "See all") then
    seeAll(S)
  end
  if Kit.button(x + 310, y + 24, 110, 28, "Clear") then
    clearDex(S)
  end

  local headerY = y + 64
  Kit.label(x + 220, headerY, "Seen")
  Kit.label(x + 300, headerY, "Owned")

  local listY = headerY + 24
  local scroll = clampScroll(S, #species)
  for i = 1, math.min(VISIBLE_ROWS, #species - scroll) do
    local mon = species[scroll + i]
    local ry = listY + (i - 1) * ROW_H
    Kit.label(x, ry + 4, mon)

    local seen, seenChanged = Kit.checkbox(x + 220, ry, dex.seen[mon] == true, "")
    if seenChanged then
      dex.seen[mon] = seen or nil
      if not seen then dex.owned[mon] = nil end -- can't own what you haven't seen
      mark(S)
    end

    local owned, ownedChanged = Kit.checkbox(x + 300, ry, dex.owned[mon] == true, "")
    if ownedChanged then
      dex.owned[mon] = owned or nil
      if owned then dex.seen[mon] = true end -- owning implies having seen it
      mark(S)
    end
  end

  local pagerY = listY + VISIBLE_ROWS * ROW_H + 8
  local maxScroll = math.max(0, #species - VISIBLE_ROWS)
  if Kit.button(x, pagerY, 90, 26, "Prev") then
    S.dexScroll = math.max(0, scroll - VISIBLE_ROWS)
  end
  if Kit.button(x + 100, pagerY, 90, 26, "Next") then
    S.dexScroll = math.min(maxScroll, scroll + VISIBLE_ROWS)
  end
  local shown = math.min(VISIBLE_ROWS, math.max(0, #species - scroll))
  Kit.label(x + 210, pagerY + 5, string.format("%d-%d of %d",
    #species > 0 and scroll + 1 or 0, scroll + shown, #species))
end

return M
