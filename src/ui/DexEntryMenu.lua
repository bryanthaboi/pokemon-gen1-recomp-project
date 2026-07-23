-- Pokédex entry page: front sprite, kind, height/weight and the real
-- dex description (data/pokemon/dex_entries.asm + dex_text.asm).
--
-- `species` may be a species id string, or a table
-- `{ species = id, forceOwned = true }`.  forceOwned mirrors pret's
-- StarterDex (engine/events/starter_dex.asm), which temporarily sets the
-- owned bit so Oak's lab ball previews show height/weight/description
-- without permanently marking the mon owned.

local Font = require("src.render.Font")

local DexEntryMenu = {}
DexEntryMenu.__index = DexEntryMenu
DexEntryMenu.isOpaque = true

-- SGB: PalPacket_Pokedex (BROWNMON) + the mon pic zone in its palette
function DexEntryMenu:sgbPalettes(game)
  local P = require("src.render.PaletteFX")
  local base = P.pal(game.data, "BROWNMON")
  if not base then return nil end
  return { P.whole(base),
           P.zone(P.monPal(game.data, self.def and self.def.id), 1, 1, 8, 8) }
end

local function resolveArgs(speciesOrOpts)
  if type(speciesOrOpts) == "table" then
    return speciesOrOpts.species or speciesOrOpts[1],
           speciesOrOpts.forceOwned and true or false
  end
  return speciesOrOpts, false
end

function DexEntryMenu.new(game, speciesOrOpts)
  local species, forceOwned = resolveArgs(speciesOrOpts)
  local self = setmetatable({ game = game, forceOwned = forceOwned }, DexEntryMenu)
  self.def = game.data.pokemon[species]
  local ok, img = pcall(love.graphics.newImage, self.def.spriteFront)
  self.sprite = ok and img or nil
  require("src.core.Sound").playCry(game.data, species)
  return self
end

function DexEntryMenu:update(dt)
  local input = self.game.input
  if input:wasPressed("a") or input:wasPressed("b") then
    self.game.stack:pop()
  end
end

function DexEntryMenu:draw()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 144)
  local def = self.def
  if self.sprite then
    love.graphics.draw(self.sprite, 8, math.max(0, 60 - self.sprite:getHeight()))
  end
  love.graphics.setColor(0, 0, 0, 1)
  Font.draw(def.name, 72, 8)
  local e = def.dexEntry or {}
  -- English R/B prints only the kind string (hlcoord 9,4 PlaceString).
  -- PokeText ("#"/POKéMON) is an unreferenced JPN leftover in pokedex.asm;
  -- appending " POKéMON" here clipped longer kinds ("LIZARD POKé").
  Font.draw(e.kind or "?", 72, 20)
  -- same number width as the list (constants.dexDigits), so a dex past 999
  -- prints the extra digit everywhere at once
  local digits = (self.game.data.constants or {}).dexDigits or 3
  Font.draw(("No.%0" .. digits .. "d"):format(def.dex or 0), 72, 32)
  local owned = self.forceOwned
    or (self.game.save.pokedex and self.game.save.pokedex.owned[def.id])
  -- height/weight print only once owned, like the description
  -- (pokedex.asm: "if the pokemon has not been owned, don't print the
  -- height, weight, or description")
  if owned and e.heightFt then
    -- feet/inches use the dex screen's ′/″ glyphs ("HT  ?′??″" in
    -- pokedex.asm; the tiles come from gfx/pokedex/pokedex.png via
    -- engine/gfx/load_pokedex_tiles.asm)
    Font.draw(("HT %d′%02d″"):format(e.heightFt, e.heightIn or 0), 72, 44)
    Font.draw(("WT %.1flb"):format((e.weight or 0) / 10), 72, 54)
  end
  local text = owned and e.text and self.game.data.text[e.text] or nil
  local y = 72
  if text then
    for line in (text:gsub("\v", "\n"):gsub("\f", "\n") .. "\n"):gmatch("(.-)\n") do
      if y > 132 then break end
      Font.draw(line, 8, y)
      y = y + 10
    end
  else
    Font.draw("Data unknown.", 8, y)
  end
  love.graphics.setColor(1, 1, 1, 1)
end

return DexEntryMenu
