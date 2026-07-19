-- The START menu (engine/menus/start_menu.asm): entries appear as they
-- become usable -- POKéDEX once Oak gives it, POKéMON once you have any,
-- SAVE with a confirmation, plus ITEM / OPTION / LINK / QUIT.  The built
-- item list runs through the ui.start_menu.items hook before the menu
-- opens, so mods insert or remove rows without patching this file.

local Logger = require("src.core.Logger")
local Menu = require("src.ui.Menu")
local Runtime = require("src.mods.Runtime")
local Screens = require("src.ui.Screens")

local StartMenu = {}

local function sameItems(_, items) return items end

function StartMenu.new(game)
  local flags = game.save.flags or {}
  local items = {}

  -- POKéDEX: only after Oak hands it over
  if flags.EVENT_GOT_POKEDEX then
    table.insert(items, { label = "POKéDEX", onSelect = function()
      Screens.push(game, "PokedexMenu")
    end })
  end

  -- POKéMON is always listed (draw_start_menu.asm prints it even with
  -- an empty party; selecting it then just no-ops)
  table.insert(items, { label = "POKéMON", onSelect = function()
    if #game.save.party == 0 then return end
    Screens.push(game, "PartyMenu")
  end })

  table.insert(items, { label = "ITEM", onSelect = function()
    Screens.push(game, "BagMenu")
  end })

  -- the player's name opens the trainer card (StartMenu_TrainerInfo)
  table.insert(items, { label = game.save.player.name or "RED",
    onSelect = function()
      Screens.push(game, "TrainerCard")
    end })

  -- SAVE shows the player/badges/dex/time panel then asks to confirm
  -- (PrintSaveScreenText)
  table.insert(items, { label = "SAVE", onSelect = function()
    local TextBox = require("src.render.TextBox")
    local ChoiceBox = require("src.ui.ChoiceBox")
    local badges = require("src.inventory.Badges").count(game.data, game.save)
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
    Screens.push(game, "OptionsMenu")
  end })

  -- LINK needs a party
  if #game.save.party > 0 then
    table.insert(items, { label = "LINK", onSelect = function()
      local LinkState = require("src.link.LinkState")
      game.stack:push(LinkState.new(game))
    end })
  end

  -- the manager's pause-menu entry (18-mod-manager-ux): gated on at least
  -- one discovered mod so a vanilla install's menu is unchanged
  local status = game.modStatus
  if status and #(status.available or {}) > 0 then
    table.insert(items, { label = "MODS", onSelect = function()
      Screens.push(game, "ManagerState")
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

  local hooked = Runtime.call("ui.start_menu.items", sameItems, game, items)
  if type(hooked) == "table" then
    items = hooked
  else
    Logger.error("ui.start_menu.items returned %s; keeping the vanilla items",
                 type(hooked))
  end

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
