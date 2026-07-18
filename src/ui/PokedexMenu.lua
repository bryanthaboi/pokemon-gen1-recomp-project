-- Minimal Pokédex: dex-ordered list with seen/owned markers.

local ListMenu = require("src.ui.ListMenu")

local PokedexMenu = {}

-- SGB: PalPacket_Pokedex, whole screen
function PokedexMenu:sgbPalettes(game)
  return require("src.render.PaletteFX").wholeNamed(game.data, "BROWNMON")
end

function PokedexMenu.new(game)
  local dex = game.save.pokedex or { seen = {}, owned = {} }
  local byDex = {}
  for species, def in pairs(game.data.pokemon) do
    if def.dex then byDex[def.dex] = def end
  end
  local items = {}
  local seen, owned = 0, 0
  for n = 1, 151 do
    local def = byDex[n]
    if def then
      local label
      if dex.owned[def.id] then
        label = ("%03d %s"):format(n, def.name)
        owned = owned + 1
        seen = seen + 1
      elseif dex.seen[def.id] then
        label = ("%03d %s"):format(n, def.name)
        seen = seen + 1
      else
        label = ("%03d -----"):format(n)
      end
      table.insert(items, {
        label = label,
        -- owned entries carry the pokéball marker like the original
        -- list; seen-only entries are just the name
        ball = dex.owned[def.id] or nil,
        value = (dex.owned[def.id] or dex.seen[def.id]) and def.id or nil,
      })
    end
  end
  local list = ListMenu.new(game, "POKéDEX", items, {
    footer = ("SEEN %d  OWNED %d"):format(seen, owned),
    pageJump = true, -- Left/Right page jumps like the original
    onChoose = function(item)
      if not item.value then return end
      -- the DATA / CRY / AREA / QUIT choice (engine/menus/pokedex.asm
      -- PokedexMenuItemsText); CRY keeps the side menu open like the
      -- original, QUIT returns to the list
      local Menu = require("src.ui.Menu")
      game.stack:push(Menu.new(game, {
        { label = "DATA", onSelect = function()
            local DexEntryMenu = require("src.ui.DexEntryMenu")
            game.stack:push(DexEntryMenu.new(game, item.value))
          end },
        { label = "CRY", keepOpen = true, onSelect = function()
            require("src.core.Sound").playCry(game.data, item.value)
          end },
        { label = "AREA", onSelect = function()
            local TownMap = require("src.ui.TownMap")
            game.stack:push(TownMap.new(game, { nestSpecies = item.value }))
          end },
        { label = "QUIT" },
      }, { tx = 12, ty = 8, tw = 8, th = 10 }))
    end,
  })
  list.sgbPalettes = PokedexMenu.sgbPalettes
  return list
end

return PokedexMenu
