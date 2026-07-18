-- The 20-slot bag (BAG_ITEM_CAPACITY, constants/menu_constants.asm):
-- a distinct item id occupies one slot regardless of quantity; badges
-- live in the inventory table but are not bag items.  save.bagOrder
-- keeps acquisition order like wBagItems (SELECT can reorder it).

local Bag = {}

Bag.CAPACITY = 20

local function isBadge(id)
  return id:find("BADGE", 1, true) ~= nil
end

function Bag.slots(save)
  local n = 0
  for id in pairs(save.inventory) do
    if not isBadge(id) then n = n + 1 end
  end
  return n
end

-- Acquisition-ordered id list (wBagItems).  Rebuilt sorted once for
-- saves from before the order existed, then maintained incrementally.
function Bag.order(save)
  local order = save.bagOrder
  if not order then
    order = {}
    for id in pairs(save.inventory) do
      if not isBadge(id) then table.insert(order, id) end
    end
    table.sort(order)
    save.bagOrder = order
  end
  -- drop stale ids, append unknown ones (defensive against direct
  -- inventory writes)
  local seen = {}
  for i = #order, 1, -1 do
    local id = order[i]
    if not save.inventory[id] or seen[id] then
      table.remove(order, i)
    else
      seen[id] = true
    end
  end
  for id in pairs(save.inventory) do
    if not isBadge(id) and not seen[id] then table.insert(order, id) end
  end
  return order
end

-- Add qty of an item; returns false (and adds nothing) when a new slot
-- is needed and the bag is full, or when the stack would pass 99
-- (AddItemToInventory's per-slot quantity cap).
function Bag.add(save, id, qty)
  local inv = save.inventory
  if not inv[id] and not isBadge(id) and Bag.slots(save) >= Bag.CAPACITY then
    return false
  end
  if not isBadge(id) and (inv[id] or 0) + (qty or 1) > 99 then
    return false
  end
  local isNew = not inv[id]
  inv[id] = (inv[id] or 0) + (qty or 1)
  if isNew and not isBadge(id) then
    table.insert(Bag.order(save), id)
  end
  return true
end

-- Remove qty (default 1); clears the slot and its order entry at zero.
function Bag.remove(save, id, qty)
  local inv = save.inventory
  inv[id] = (inv[id] or 0) - (qty or 1)
  if inv[id] <= 0 then
    inv[id] = nil
    local order = save.bagOrder
    if order then
      for i, oid in ipairs(order) do
        if oid == id then table.remove(order, i) break end
      end
    end
  end
end

return Bag
