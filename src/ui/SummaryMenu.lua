-- Pokémon status screen, laid out like the original's two pages
-- (engine/pokemon/status_screen.asm): page 1 = pic, No., HP bar,
-- STATUS/, the ATTACK/DEFENSE/SPEED/SPECIAL box and TYPE1/TYPE2/
-- IDNo/OT; page 2 = EXP and the moves with PP.  A flips pages, B (or
-- A on page 2) closes.

local Font = require("src.render.Font")

local SummaryMenu = {}
SummaryMenu.__index = SummaryMenu
SummaryMenu.isOpaque = true

-- SGB: SetPal_StatusScreen -- HP-bar palette overall, mon pic zone in
-- the species palette
function SummaryMenu:sgbPalettes(game)
  local P = require("src.render.PaletteFX")
  local mon = self.mon
  if not mon then return P.wholeNamed(game.data, "MEWMON") end
  local bar = P.pal(game.data, P.barPalName(mon.hp, mon.stats.hp))
  if not bar then return nil end
  return { P.whole(bar), P.zone(P.monPal(game.data, mon.species), 1, 0, 7, 6) }
end

function SummaryMenu.new(game, mon)
  local self = setmetatable({ game = game, mon = mon, page = 1 }, SummaryMenu)
  local def = game.data.pokemon[mon.species]
  if def and def.spriteFront then
    local ok, img = pcall(love.graphics.newImage, def.spriteFront)
    self.sprite = ok and img or nil
  end
  require("src.core.Sound").playCry(game.data, mon.species)
  return self
end

function SummaryMenu:update(dt)
  local input = self.game.input
  -- both A and B advance the pages (WaitForTextScrollButtonPress)
  if input:wasPressed("a") or input:wasPressed("b") then
    if self.page == 1 then
      self.page = 2
    else
      self.game.stack:pop()
    end
  end
end

-- DrawLineBox (status_screen.asm): a vertical edge down the right,
-- a corner, a horizontal run leftward and the half-arrow ending --
-- drawn from the same HUD tiles the original loads
local function drawLineBox(tx, ty, b, c)
  local HudTiles = require("src.render.HudTiles")
  for i = 0, b - 1 do HudTiles.tile(0x73, tx * 8, (ty + i) * 8) end
  HudTiles.tile(0x77, tx * 8, (ty + b) * 8)
  for i = 1, c do HudTiles.tile(0x76, (tx - i) * 8, (ty + b) * 8) end
  HudTiles.tile(0x6F, (tx - c - 1) * 8, (ty + b) * 8)
end

function SummaryMenu:draw()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 144)
  local mon = self.mon
  local game = self.game
  local data = game.data
  local def = data.pokemon[mon.species]

  -- shared header: pic (1,0), name (9,1), <LV> (14,2), No. (1,7)
  if self.sprite then
    love.graphics.draw(self.sprite, 8,
                       math.max(0, 56 - self.sprite:getHeight()))
  end
  local HudTiles = require("src.render.HudTiles")
  love.graphics.setColor(0, 0, 0, 1)
  Font.draw(mon.nickname or def.name, 72, 8)
  HudTiles.tile(0x6E, 112, 16) -- <LV>
  Font.draw(tostring(mon.level), 120, 16)
  Font.draw(("No.%03d"):format(def.dex or 0), 8, 56)

  if self.page == 1 then
    -- HP bar (11,3) + numbers row 4, STATUS/ (9,6), the DrawLineBox
    -- bracket around the name/HP block
    drawLineBox(19, 1, 6, 10)
    HudTiles.drawHPBar(data, 11, 3, mon, 1) -- wHPBarType 1
    Font.draw(("%3d/%3d"):format(mon.hp, mon.stats.hp), 96, 32)
    Font.draw("STATUS/", 72, 48)
    Font.draw(mon.status or "OK", 128, 48)

    -- stats box (0,8) 10x10: names rows 9/11/13/15, values indented
    Font.drawBox(0, 8, 10, 10)
    local stats = {
      { "ATTACK", mon.stats.attack }, { "DEFENSE", mon.stats.defense },
      { "SPEED", mon.stats.speed }, { "SPECIAL", mon.stats.special },
    }
    for i, s in ipairs(stats) do
      local y = 72 + (i - 1) * 16
      Font.draw(s[1], 8, y)
      Font.draw(("%3d"):format(s[2]), 48, y + 8)
    end

    -- TYPE1/TYPE2/IDNo/OT column (10,9) with values indented (11,10)
    drawLineBox(19, 9, 8, 6)
    Font.draw("TYPE1/", 80, 72)
    Font.draw(def.types[1] or "", 88, 80)
    if def.types[2] then
      Font.draw("TYPE2/", 80, 88)
      Font.draw(def.types[2], 88, 96)
    end
    Font.draw("IDNo/", 80, 104)
    -- the trainer ID is rolled at new game (SaveData.newGame) and
    -- backfilled on load for old saves
    Font.draw(("%05d"):format(mon.otId or game.save.player.id or 0), 96, 112)
    Font.draw("OT/", 80, 120)
    Font.draw(mon.ot or game.save.player.name or "RED", 96, 128)
  else
    -- page 2: EXP + the moves with PP (StatusScreen2)
    drawLineBox(19, 1, 6, 10)
    Font.draw("EXP POINTS", 72, 24)
    Font.draw(("%d"):format(mon.exp), 96, 32)
    Font.draw("LEVEL UP", 72, 44)
    local Growth = require("src.pokemon.Growth")
    local nextExp = mon.level < 100
      and (Growth.expForLevel(def.growthRate, mon.level + 1) - mon.exp) or 0
    Font.draw(("%d to L%d"):format(math.max(0, nextExp),
                                   math.min(100, mon.level + 1)), 88, 52)
    Font.drawBox(0, 8, 20, 10)
    for i = 1, 4 do
      local mv = mon.moves[i]
      local y = 72 + (i - 1) * 16
      if mv then
        local mdef = data.moves[mv.id]
        Font.draw(mdef.name, 16, y)
        Font.draw("PP", 88, y + 8)
        Font.draw(("%2d/%2d"):format(mv.pp, mdef.pp), 112, y + 8)
      else
        Font.draw("-", 16, y)
        Font.draw("--", 112, y + 8)
      end
    end
  end
  love.graphics.setColor(1, 1, 1, 1)
end

return SummaryMenu
