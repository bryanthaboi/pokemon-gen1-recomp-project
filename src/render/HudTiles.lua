-- In-battle HUD tiles, shared by the battle screen and the status
-- screen: pokered overlays the $62-$7F font area with the HP bar /
-- status sheet (font_battle_extra -> $62) and the HUD line tiles
-- (battle_hud_1 -> $6D, battle_hud_2+3 -> $73).

local Assets = require("src.render.Assets")

local HudTiles = {}

-- The four HUD sheets are glyph pages like any other, so they resolve
-- through the font registry: mod.content.font:register("battle_hud_1",
-- { image = ..., base = 0x6D }) reskins the HP bar.  These are the
-- vanilla pages the importer's cache carries, in the order the asm
-- overlays them ($6D lands on top of font_battle_extra's tail).
local PAGES = {
  { id = "font_battle_extra",
    image = "assets/generated/battle/font_battle_extra.png", base = 0x62 },
  { id = "battle_hud_1",
    image = "assets/generated/battle/battle_hud_1.png", base = 0x6D },
  { id = "battle_hud_2",
    image = "assets/generated/battle/battle_hud_2.png", base = 0x73 },
  { id = "battle_hud_3",
    image = "assets/generated/battle/battle_hud_3.png", base = 0x76 },
}

local tiles
function HudTiles.tile(code, x, y, tint)
  if not tiles then
    tiles = {}
    local registered = require("src.core.Data").font
    registered = registered and registered.pages or nil
    local function add(path, base)
      local ok, img = pcall(Assets.image, path)
      if not ok then return end
      local iw, ih = img:getDimensions()
      local per = iw / 8
      for i = 0, per * (ih / 8) - 1 do
        tiles[base + i] = {
          img = img,
          quad = love.graphics.newQuad((i % per) * 8,
                                       math.floor(i / per) * 8, 8, 8, iw, ih),
        }
      end
    end
    for _, page in ipairs(PAGES) do
      local override = registered and registered[page.id]
      add(override and override.image or page.image,
          override and override.base or page.base)
    end
  end
  local t = tiles[code]
  if not t then return end
  local r, g, b, a = love.graphics.getColor()
  love.graphics.setColor(tint or { 1, 1, 1, 1 })
  love.graphics.draw(t.img, t.quad, x, y)
  love.graphics.setColor(r, g, b, a)
end

-- lazy: the next tile() rebuilds every page from the search path
function HudTiles.invalidate()
  tiles = nil
end

Assets.register(HudTiles.invalidate)

-- The bar's right-end tile follows wHPBarType (DrawHPBar's "Right"
-- branch): only type 1 -- the player's in-battle bar and the status
-- screen -- gets the double-bar $6D; the enemy bar (0) and the party
-- menu (2) close with the near-blank $6C nub.
function HudTiles.capTile(barType)
  return barType == 1 and 0x6D or 0x6C
end

-- Tile HP bar (home/pokemon.asm DrawHPBar): "HP" ($71) + ":[" ($62),
-- six 8px segments ($63 empty, +n partial, $6B full), then the
-- wHPBarType right cap.  A nonzero HP always shows at least a
-- one-pixel sliver.  The fill is tinted with the SGB bar palettes at
-- GetHealthBarColor's thresholds (>= 27 px green, >= 10 yellow, else
-- red).
function HudTiles.drawHPBar(data, tx, ty, mon, barType)
  local x, y = tx * 8, ty * 8
  HudTiles.tile(0x71, x, y)
  HudTiles.tile(0x62, x + 8, y)
  local px = 0
  if mon.stats.hp > 0 and mon.hp > 0 then
    px = math.max(1, math.floor(mon.hp * 48 / mon.stats.hp))
  end
  local tint
  local PaletteFX = require("src.render.PaletteFX")
  local name = px >= 27 and "GREENBAR" or px >= 10 and "YELLOWBAR" or "REDBAR"
  local colors = PaletteFX.pal(data, name)
  if colors then
    local c = colors[3] -- GB color 2 is the fill shade
    -- the fill pixels are the 2/3-gray shade; divide so they land on
    -- the palette color exactly (the black outline stays black)
    tint = { math.min(1, c[1] / 170), math.min(1, c[2] / 170),
             math.min(1, c[3] / 170), 1 }
  end
  for i = 0, 5 do
    local seg = math.min(8, math.max(0, px - i * 8))
    HudTiles.tile(seg >= 8 and 0x6B or 0x63 + seg, x + 16 + i * 8, y, tint)
  end
  HudTiles.tile(HudTiles.capTile(barType), x + 64, y)
end

return HudTiles
