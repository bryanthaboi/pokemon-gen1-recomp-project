-- The START menu (engine/menus/start_menu.asm): entries appear as they
-- become usable -- POKéDEX once Oak gives it, POKéMON once you have any,
-- SAVE with a confirmation, plus ITEM / OPTION / LINK / QUIT.

local Menu = require("src.ui.Menu")

local StartMenu = {}

function StartMenu.new(game)
  local flags = game.save.flags or {}
  local items = {}

  -- POKéDEX: only after Oak hands it over
  if flags.EVENT_GOT_POKEDEX then
    table.insert(items, { label = "POKéDEX", onSelect = function()
      local PokedexMenu = require("src.ui.PokedexMenu")
      game.stack:push(PokedexMenu.new(game))
    end })
  end

  -- POKéMON is always listed (draw_start_menu.asm prints it even with
  -- an empty party; selecting it then just no-ops)
  table.insert(items, { label = "POKéMON", onSelect = function()
    if #game.save.party == 0 then return end
    local PartyMenu = require("src.ui.PartyMenu")
    game.stack:push(PartyMenu.new(game))
  end })

  table.insert(items, { label = "ITEM", onSelect = function()
    local BagMenu = require("src.ui.BagMenu")
    game.stack:push(BagMenu.new(game))
  end })

  -- the player's name opens the trainer card (StartMenu_TrainerInfo)
  table.insert(items, { label = game.save.player.name or "RED",
    onSelect = function()
      local TrainerCard = require("src.ui.TrainerCard")
      game.stack:push(TrainerCard.new(game))
    end })

  -- SAVE shows the player/badges/dex/time panel then asks to confirm
  -- (PrintSaveScreenText)
  table.insert(items, { label = "SAVE", onSelect = function()
    local TextBox = require("src.render.TextBox")
    local ChoiceBox = require("src.ui.ChoiceBox")
    local badges = 0
    for _, b in ipairs({ "BOULDERBADGE", "CASCADEBADGE", "THUNDERBADGE",
                         "RAINBOWBADGE", "SOULBADGE", "MARSHBADGE",
                         "VOLCANOBADGE", "EARTHBADGE" }) do
      if game.save.inventory[b] then badges = badges + 1 end
    end
    local owned = 0
    for _ in pairs(game.save.pokedex and game.save.pokedex.owned or {}) do
      owned = owned + 1
    end
    local t = math.floor(game.save.playTime or 0)
    local panel = ("PLAYER %s\nBADGES    %d\nPOKéDEX %3d\nTIME %6d:%02d")
      :format(game.save.player.name or "RED", badges, owned,
              math.floor(t / 3600), math.floor(t / 60) % 60)
    game.stack:push(TextBox.new(game,
      panel .. "\fWould you like to\nSAVE the game?", function()
      game.stack:push(ChoiceBox.new(game, function(yes)
        if not yes then return end
        -- "Now saving..." beat before the write (save.asm
        -- NowSavingString), then GameSavedText + SFX_SAVE
        game.stack:push(TextBox.new(game, "Now saving...", function()
          game:writeSave()
          require("src.core.Sound").play(game.data, "Save")
          game.stack:push(TextBox.new(game,
            (game.save.player.name or "RED") .. " saved\nthe game!"))
        end))
      end))
    end))
  end })

  table.insert(items, { label = "OPTION", onSelect = function()
    local OptionsMenu = require("src.ui.OptionsMenu")
    game.stack:push(OptionsMenu.new(game))
  end })

  -- LINK needs a party
  if #game.save.party > 0 then
    table.insert(items, { label = "LINK", onSelect = function()
      local LinkState = require("src.link.LinkState")
      game.stack:push(LinkState.new(game))
    end })
  end

  -- the original's EXIT just closed the menu (CloseStartMenu); with a
  -- window close button covering that, QUIT instead power-cycles back
  -- to the title after a confirm (defaultNo guards accidental quits)
  table.insert(items, { label = "QUIT", onSelect = function()
    local TextBox = require("src.render.TextBox")
    local ChoiceBox = require("src.ui.ChoiceBox")
    game.stack:push(TextBox.new(game, "RETURN TO MAIN\nMENU?", function()
      game.stack:push(ChoiceBox.new(game, function(yes)
        if yes then game:returnToTitle() end
      end, { defaultNo = true }))
    end))
  end })
  -- the start menu's mask is PAD_DOWN | PAD_UP | PAD_START | PAD_B | PAD_A
  -- (engine/menus/draw_start_menu.asm), so START closes it back to the
  -- overworld -- unlike most menus, whose masks omit PAD_START.
  local menu = Menu.new(game, items,
    { tx = 9, ty = 0, tw = 11, th = #items * 2 + 2, startCloses = true })
  -- the cursor position survives closing the menu
  -- (wBattleAndStartSavedMenuItem, home/start_menu.asm)
  menu.index = math.min(game.save.startMenuIndex or 1, #items)
  local baseUpdate = menu.update
  menu.update = function(self, dt)
    baseUpdate(self, dt)
    game.save.startMenuIndex = self.index
  end
  return menu
end

return StartMenu
