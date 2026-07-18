-- Party helpers (max 6, like the original).

local Party = {}

Party.MAX = 6

function Party.add(party, mon)
  if #party >= Party.MAX then
    return false -- box system comes later
  end
  table.insert(party, mon)
  return true
end

function Party.firstHealthy(party)
  for i, mon in ipairs(party) do
    if mon.hp > 0 then return mon, i end
  end
  return nil
end

return Party
