-- Mart shop (engine/events/pokemart.asm DisplayPokemartDialogue_):
-- the BUY/SELL/QUIT menu loops until QUIT -- BUY and SELL keep it on
-- the stack underneath their list, and QUIT hands control back to the
-- caller (open_mart resumes its yielded script runner there).  Both
-- lists run in dialogue mode: the clerk speaks the real _Pokemart*
-- strings in the bottom text box with the money box top-right, then
-- the 1-99 quantity selector (DisplayChooseQuantityMenu) and a YES/NO
-- price confirm.  Key items and HMs can't be sold (.unsellableItem).

local Bag = require("src.inventory.Bag")
local ChoiceBox = require("src.ui.ChoiceBox")
local ListMenu = require("src.ui.ListMenu")
local Menu = require("src.ui.Menu")
local QuantityBox = require("src.ui.QuantityBox")

local ShopMenu = {}

local function txt(game, key, fallback)
  return game.data.text[key] or fallback
end

local function buy(game, stock)
  local items = {}
  for _, id in ipairs(stock) do
    local def = game.data.items[id]
    if def then
      table.insert(items, {
        value = id,
        label = def.name,
        right = ("¥%d"):format(def.price),
      })
    end
  end
  local greet = txt(game, "_PokemartBuyingGreetingText", "Take your time.")
  local notEnough = txt(game, "_PokemartNotEnoughMoneyText",
                        "You don't have\nenough money.")
  local list
  list = ListMenu.new(game, "BUY", items, {
    dialogue = true,
    money = function() return game.save.money end,
    footer = greet,
    onChoose = function(item)
      local def = game.data.items[item.value]
      if game.save.money < def.price then
        list.footer = notEnough
        return
      end
      local affordable = math.min(99, math.floor(game.save.money / math.max(1, def.price)))
      game.stack:push(QuantityBox.new(game, {
        max = affordable,
        unitPrice = def.price,
        onDone = function(qty)
          if not qty then
            list.footer = greet
            return
          end
          local cost = qty * def.price
          -- _PokemartTellBuyPriceText + yes/no confirm
          list.footer = ("%s?\nThat will be\n¥%d. OK?"):format(def.name, cost)
          game.stack:push(ChoiceBox.new(game, function(yes)
            if not yes then
              list.footer = greet
              return
            end
            if game.save.money < cost then
              list.footer = notEnough
              return
            end
            if not Bag.add(game.save, item.value, qty) then
              list.footer = txt(game, "_PokemartItemBagFullText",
                                "You can't carry\nany more items.")
              return
            end
            require("src.core.Sound").play(game.data, "Purchase")
            game.save.money = game.save.money - cost
            list.footer = txt(game, "_PokemartBoughtItemText",
                              "Here you are!\nThank you!")
          end))
        end,
      }))
    end,
  })
  game.stack:push(list)
end

local function sell(game)
  -- Sell list is ITEMLISTMENU with wPrintItemPrices cleared
  -- (pokemart.asm .sellMenuLoop): name + quantity only.  Price shows
  -- in the quantity chooser.  Stuffing "xN" into the label next to a
  -- right-aligned ¥ price made long names overlap (issue #116).
  local items = {}
  for _, id in ipairs(Bag.order(game.save)) do
    local def = game.data.items[id]
    table.insert(items, {
      value = id,
      label = def and def.name or id,
      right = "x" .. game.save.inventory[id],
    })
  end
  local greet = txt(game, "_PokemartBuyingGreetingText", "Take your time.")
  local list
  list = ListMenu.new(game, "SELL", items, {
    dialogue = true,
    money = function() return game.save.money end,
    footer = greet,
    onChoose = function(item)
      local def = game.data.items[item.value]
      -- only key items and HMs are unsellable (pokemart.asm IsKeyItem /
      -- IsItemHM); zero-price items like ETHER sell for ¥0
      if (def and def.keyItem) or item.value:find("^HM_") then
        list.footer = txt(game, "_PokemartUnsellableItemText",
                          "I can't put a\nprice on that.")
        return
      end
      local unit = math.floor(def.price / 2)
      game.stack:push(QuantityBox.new(game, {
        max = game.save.inventory[item.value] or 1,
        unitPrice = unit,
        onDone = function(qty)
          if not qty then
            list.footer = greet
            return
          end
          -- _PokemartTellSellPriceText + yes/no confirm
          list.footer = ("I can pay you\n¥%d for that."):format(unit * qty)
          game.stack:push(ChoiceBox.new(game, function(yes)
            if not yes then
              list.footer = greet
              return
            end
            game.save.money = game.save.money + unit * qty
            Bag.remove(game.save, item.value, qty)
            local left = game.save.inventory[item.value]
            if left then
              item.right = "x" .. left
            else
              list:removeCurrent()
            end
            list.footer = txt(game, "_PokemartThankYouText", "Thank you!")
          end))
        end,
      }))
    end,
  })
  game.stack:push(list)
end

function ShopMenu.new(game, stock, onQuit)
  -- keepOpen: the mart menu stays underneath its list so closing the
  -- list lands back here; only QUIT (or B) leaves and fires onQuit
  local menu = Menu.new(game, {
    { label = "BUY", keepOpen = true, onSelect = function() buy(game, stock) end },
    { label = "SELL", keepOpen = true, onSelect = function() sell(game) end },
    { label = "QUIT", onSelect = onQuit },
  }, { tx = 0, ty = 0, tw = 8, th = 8 })
  menu.onCancel = onQuit
  return menu
end

return ShopMenu
