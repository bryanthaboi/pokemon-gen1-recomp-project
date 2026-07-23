-- PC storage: 12 boxes of 20 (engine/pokemon/bills_pc.asm semantics via
-- src/pokemon/Boxes.lua): withdraw from / deposit to the current box,
-- plus CHANGE BOX.

local Boxes = require("src.pokemon.Boxes")
local ListMenu = require("src.ui.ListMenu")
local Menu = require("src.ui.Menu")
local Party = require("src.pokemon.Party")

local BoxMenu = {}

local function monLabel(game, mon)
  local def = game.data.pokemon[mon.species]
  return ("%s :L%d"):format(mon.nickname or def.name, mon.level)
end

-- Per-mon submenu (bills_pc.asm DisplayDepositWithdrawMenu): the chosen
-- action + STATS + CANCEL.  STATS shows the status screen and returns
-- here; CANCEL/B goes back to the list.
local function monSubmenu(game, action, mon, onAction)
  game.stack:push(Menu.new(game, {
    { label = action, onSelect = onAction },
    {
      label = "STATS",
      keepOpen = true,
      onSelect = function()
        require("src.ui.Screens").push(game, "SummaryMenu", mon)
      end,
    },
    { label = "CANCEL" },
  }, { tx = 9, ty = 10, tw = 11, th = 8, noSound = true }))
end

local function withdraw(game)
  local box = Boxes.active(game.save)
  local items = {}
  for i, mon in ipairs(box) do
    table.insert(items, { label = monLabel(game, mon), value = i })
  end
  game.stack:push(ListMenu.new(game,
    ("BOX %d (WITHDRAW)"):format(game.save.currentBox), items, {
    onChoose = function(item, list)
      local mon = box[item.value]
      if not mon then return end
      monSubmenu(game, "WITHDRAW", mon, function()
        if #game.save.party >= Party.MAX then
          list.footer = "The party is full!"
          return
        end
        table.remove(box, item.value)
        table.insert(game.save.party, mon)
        list:close()
      end)
    end,
  }))
end

local function deposit(game)
  local items = {}
  for i, mon in ipairs(game.save.party) do
    table.insert(items, { label = monLabel(game, mon), value = i })
  end
  game.stack:push(ListMenu.new(game, "PARTY (DEPOSIT)", items, {
    onChoose = function(item, list)
      local mon = game.save.party[item.value]
      if not mon then return end
      monSubmenu(game, "DEPOSIT", mon, function()
        if #game.save.party <= 1 then
          list.footer = "You need at least\none POKéMON!"
          return
        end
        local box = Boxes.active(game.save)
        if #box >= Boxes.CAPACITY then
          list.footer = ("BOX %d is full!"):format(game.save.currentBox)
          return
        end
        table.remove(game.save.party, item.value)
        table.insert(box, mon)
        list:close()
      end)
    end,
  }))
end

-- RELEASE POKéMON (bills_pc.asm .release): confirm, then "Bye [MON]!"
local function release(game)
  local box = Boxes.active(game.save)
  local items = {}
  for i, mon in ipairs(box) do
    table.insert(items, { label = monLabel(game, mon), value = i })
  end
  game.stack:push(ListMenu.new(game,
    ("BOX %d (RELEASE)"):format(game.save.currentBox), items, {
    onChoose = function(item, list)
      local mon = box[item.value]
      if not mon then return end
      local def = game.data.pokemon[mon.species]
      local name = mon.nickname or def.name
      local ChoiceBox = require("src.ui.ChoiceBox")
      local TextBox = require("src.render.TextBox")
      game.stack:push(TextBox.new(game,
        "Once released,\n" .. name .. " is\ngone forever. OK?", function()
        game.stack:push(ChoiceBox.new(game, function(yes)
          if not yes then return end
          table.remove(box, item.value)
          require("src.core.Sound").playCry(game.data, mon.species)
          game.stack:push(TextBox.new(game,
            ("%s was\nreleased outside.\fBye %s!"):format(name, name)))
          list:removeCurrent()
        end, { defaultNo = true, noSound = true }))
      end))
    end,
  }))
end

local function changeBox(game)
  local boxes = Boxes.ensure(game.save)
  local items = {}
  for i = 1, Boxes.COUNT do
    local mark = i == game.save.currentBox and "*" or " "
    table.insert(items, {
      label = ("%sBOX %2d"):format(mark, i),
      right = ("%d/%d"):format(#boxes[i], Boxes.CAPACITY),
      value = i,
    })
  end
  game.stack:push(ListMenu.new(game, "CHANGE BOX", items, {
    onChoose = function(item, list)
      -- the original asks BEFORE switching ("When you change a #MON
      -- BOX, data will be saved. OK?"); declining aborts the change
      local ChoiceBox = require("src.ui.ChoiceBox")
      local TextBox = require("src.render.TextBox")
      game.stack:push(TextBox.new(game,
        "When you change a\nPOKéMON BOX, data\nwill be saved. OK?", function()
        game.stack:push(ChoiceBox.new(game, function(yes)
          if not yes then return end
          game.save.currentBox = item.value
          if game.writeSave then game:writeSave() end
          list:close()
        end, { noSound = true }))
      end))
    end,
  }))
end

function BoxMenu.new(game)
  Boxes.ensure(game.save)
  -- bills_pc.asm BillsPCMenu: TextBoxBorder at (0,0) with interior
  -- 12x10 → total 14x12.  "CHANGE BOX" is 10 tiles and needs the
  -- full interior (cursor col + label); the old tw=12 right-side box
  -- drew the final glyph on the border.
  return Menu.new(game, {
    { label = "WITHDRAW", onSelect = function() withdraw(game) end },
    { label = "DEPOSIT", onSelect = function() deposit(game) end },
    { label = "RELEASE", onSelect = function() release(game) end },
    { label = "CHANGE BOX", onSelect = function() changeBox(game) end },
    { label = "SEE YA!" },
    -- Bill's PC runs silent end to end (BIT_NO_MENU_BUTTON_SOUND,
    -- engine/menus/pokemon_pc.asm)
  }, { tx = 0, ty = 0, tw = 14, th = 12, noSound = true })
end

return BoxMenu
