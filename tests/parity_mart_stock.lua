-- Parity test: mart inventories match pokered, and every item the route
-- driver tries to buy is actually on that mart's shelf.
--
-- Two failures in one, and the second is the one that bit.
--
-- Our extracted mart data was right all along -- VermilionMartClerkText is
-- POKE_BALL, SUPER_POTION, ICE_HEAL, AWAKENING, PARLYZ_HEAL, REPEL
-- (data/items/marts.asm:17), and that is exactly what we import. The route
-- driver's shopping list asked for plain POTION there, which Vermilion has
-- never sold. buyItem logged "shop: no POTION @ VERMILION_MART" into the
-- end-of-run summary and returned, so the bot left town with no healing at
-- all and then died nine times in Surge's gym and five more around
-- Cerulean, every fight taken at whatever HP the last nurse had left it.
--
-- A shopping list that names an unstocked item cannot work, and nothing
-- else in the run reports it loudly enough to notice. This asserts the
-- lists against the data instead.
--
-- Self-contained; run via `luajit tests/parity_mart_stock.lua`.
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
local S = require("tests.harness").suite("parity mart stock")
local check, eq = S.check, S.eq

local T = dofile("data/generated/text_pointers.lua")

-- MAP_NAME -> text-pointer group ("CELADON_MART_4F" -> "CeladonMart4F")
local function groupOf(map)
  local s = ""
  for part in tostring(map):gmatch("[^_]+") do
    if part:match("^%d") then
      s = s .. part:upper()
    else
      s = s .. part:sub(1, 1):upper() .. part:sub(2):lower()
    end
  end
  return s
end

-- every item sold on a map, across all its clerks
local function stockFor(map)
  local group = T[groupOf(map)]
  if not group then return nil end
  local set, any = {}, false
  for _, v in pairs(group) do
    if type(v) == "table" and v.mart then
      for _, id in ipairs(v.mart) do set[id] = true; any = true end
    end
  end
  return any and set or nil
end

-- ---- 1. our extracted stock matches pokered's marts.asm -----------------
-- Spot-checks transcribed from data/items/marts.asm; the Vermilion row is
-- the one the driver got wrong, so it is pinned exactly.
local POKERED = {
  VERMILION_MART = { "POKE_BALL", "SUPER_POTION", "ICE_HEAL", "AWAKENING",
                     "PARLYZ_HEAL", "REPEL" },
  PEWTER_MART = { "POKE_BALL", "POTION", "ESCAPE_ROPE", "ANTIDOTE",
                  "BURN_HEAL", "AWAKENING", "PARLYZ_HEAL" },
  LAVENDER_MART = { "GREAT_BALL", "SUPER_POTION", "REVIVE", "ESCAPE_ROPE",
                    "SUPER_REPEL", "ANTIDOTE", "BURN_HEAL", "ICE_HEAL",
                    "PARLYZ_HEAL" },
}
for map, want in pairs(POKERED) do
  local sold = stockFor(map)
  check(sold ~= nil, map .. " has mart data")
  if sold then
    for _, id in ipairs(want) do
      check(sold[id], ("%s stocks %s (marts.asm)"):format(map, id))
    end
  end
end
-- and the absence that caused the bug
check(not (stockFor("VERMILION_MART") or {}).POTION,
      "VERMILION_MART sells SUPER_POTION and NOT plain POTION")

-- ---- 2. every driver shopping list is actually stocked ------------------
-- Mirrors SHOP_STOCK in tests/drivers/route.lua. Kept as a literal rather
-- than reached into the driver, which needs a live Game to load.
local SHOP_STOCK = {
  viridianBalls = { "POKE_BALL", "ANTIDOTE", "PARLYZ_HEAL" },
  pewter        = { "ESCAPE_ROPE", "POTION" },
  vermilion     = { "SUPER_POTION", "POKE_BALL" },
  repels        = { "SUPER_POTION" },
  buffs         = {},
  pokeDoll      = { "POKE_DOLL" },
  tm07 = {}, vending = {}, water = {},
}

local R = dofile("tests/drivers/bot_route.lua")
local checked = 0
for i, seg in ipairs(R) do
  for _, step in ipairs(seg.steps) do
    if step.op == "shop" then
      local list = SHOP_STOCK[step.list]
      -- an unknown list name would silently fall back to POTION at runtime
      check(list ~= nil,
            ("segment %d: shop list %q is known to the driver")
              :format(i, tostring(step.list)))
      local sold = stockFor(seg.map)
      for _, id in ipairs(list or {}) do
        checked = checked + 1
        check(sold and sold[id],
              ("segment %d: %s sells %s"):format(i, seg.map, id))
      end
    end
  end
end
check(checked > 0, "the route actually contains shop steps to check")

S.finish()
