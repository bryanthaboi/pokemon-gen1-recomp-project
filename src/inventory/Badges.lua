-- The badge set as data (constants.badges): an ordered list of
-- { id, name?, icon?, item? } records where list position is the badge
-- number.  Every screen that used to carry its own copy of the gym order
-- reads it from here; the literal survives only as the fallback for caches
-- imported before the constant existed.

local Badges = {}

-- gym order (data/scripts/victories.lua)
local VANILLA = {
  { id = "BOULDERBADGE" }, { id = "CASCADEBADGE" }, { id = "THUNDERBADGE" },
  { id = "RAINBOWBADGE" }, { id = "SOULBADGE" },    { id = "MARSHBADGE" },
  { id = "VOLCANOBADGE" }, { id = "EARTHBADGE" },
}

function Badges.list(data)
  local list = data and data.constants and data.constants.badges
  if type(list) == "table" and #list > 0 then return list end
  return VANILLA
end

-- badges are stored under an inventory key, which is the badge id unless
-- the record names a different item
function Badges.itemFor(entry)
  return entry.item or entry.id
end

function Badges.count(data, save)
  local inventory = save and save.inventory
  if not inventory then return 0 end
  local n = 0
  for _, entry in ipairs(Badges.list(data)) do
    if inventory[Badges.itemFor(entry)] then n = n + 1 end
  end
  return n
end

return Badges
