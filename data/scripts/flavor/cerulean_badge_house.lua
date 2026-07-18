-- CeruleanBadgeHouse (pokered/scripts/CeruleanBadgeHouse.asm)
--
-- CeruleanBadgeHouseMiddleAgedManText is a text_asm: it prints a
-- greeting, then loops a badge-description menu (LoadItemList /
-- DisplayListMenuID over CeruleanBadgeHouseBadgeTextPointers) until the
-- player backs out with B, then prints a goodbye line.  The badge list
-- is the fixed set of all 8 badges (not filtered by what the player
-- owns) -- it's an explanatory menu, not a real item pick.

local function push(game, s, done)
  local TextBox = require("src.render.TextBox")
  game.stack:push(TextBox.new(game, s, done))
end

-- CeruleanBadgeHouseBadgeTextPointers / .BadgeItemList
local BADGE_ORDER = {
  "BOULDERBADGE", "CASCADEBADGE", "THUNDERBADGE", "RAINBOWBADGE",
  "SOULBADGE", "MARSHBADGE", "VOLCANOBADGE", "EARTHBADGE",
}
local BADGE_TEXT = {
  BOULDERBADGE = "_CeruleanBadgeHouseBoulderBadgeText",
  CASCADEBADGE = "_CeruleanBadgeHouseCascadeBadgeText",
  THUNDERBADGE = "_CeruleanBadgeHouseThunderBadgeText",
  RAINBOWBADGE = "_CeruleanBadgeHouseRainbowBadgeText",
  SOULBADGE = "_CeruleanBadgeHouseSoulBadgeText",
  MARSHBADGE = "_CeruleanBadgeHouseMarshBadgeText",
  VOLCANOBADGE = "_CeruleanBadgeHouseVolcanoBadgeText",
  EARTHBADGE = "_CeruleanBadgeHouseEarthBadgeText",
}

local function middleAgedMan(game, ow, npc, done)
  local t = game.data.text

  local function loop()
    -- .loop: print WhichBadgeText, then show the badge list menu again
    push(game, t._CeruleanBadgeHouseMiddleAgedManWhichBadgeText, function()
      local ListMenu = require("src.ui.ListMenu")
      local items = {}
      for _, id in ipairs(BADGE_ORDER) do
        local idef = game.data.items[id]
        items[#items + 1] = { label = idef and idef.name or id, value = id }
      end
      local menu = ListMenu.new(game, "", items, {
        onChoose = function(item)
          push(game, t[BADGE_TEXT[item.value]], loop)
        end,
        onCancel = function()
          -- .done: VisitAnyTimeText, then TextScriptEnd
          push(game, t._CeruleanBadgeHouseMiddleAgedManVisitAnyTimeText, done)
        end,
      })
      game.stack:push(menu)
    end)
  end

  push(game, t._CeruleanBadgeHouseMiddleAgedManText, loop)
end

return {
  CERULEAN_BADGE_HOUSE = {
    talk = {
      TEXT_CERULEANBADGEHOUSE_MIDDLE_AGED_MAN = middleAgedMan,
    },
  },
}
