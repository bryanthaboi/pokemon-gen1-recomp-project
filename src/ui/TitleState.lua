-- Title screen (engine/movie/title.asm + engine/menus/main_menu.asm):
-- the logo (or a text fallback while the asset is missing), a cycling
-- Pokémon front sprite, the copyright line, and the CONTINUE / NEW GAME
-- / OPTION main menu on START or A.

local Font = require("src.render.Font")
local Music = require("src.core.Music")

local TitleState = {}
TitleState.__index = TitleState
TitleState.isOpaque = true

-- SGB title zones (PalPacket_Titlescreen): the logo rows get LOGO2,
-- the version-ribbon band LOGO1, the rest MEWMON.
function TitleState:sgbPalettes(game)
  local P = require("src.render.PaletteFX")
  local z = {
    P.zone(P.pal(game.data, "LOGO2"), 0, 0, 19, 7),
    P.zone(P.pal(game.data, "LOGO1"), 0, 8, 19, 9),
    P.zone(P.pal(game.data, "MEWMON"), 0, 10, 19, 17),
  }
  return z[3] and z or nil
end

-- the Red-version TitleMons list (data/pokemon/title_mons.asm):
-- TitleScreenPickNewMon draws a random, never-repeating pick from it;
-- field.title.cycleSpecies replaces it wholesale
local CYCLE_SPECIES = {
  "CHARMANDER", "SQUIRTLE", "BULBASAUR", "WEEDLE", "NIDORAN_M", "SCYTHER",
  "PIKACHU", "CLEFAIRY", "RHYDON", "ABRA", "GASTLY", "DITTO",
  "PIDGEOTTO", "ONIX", "PONYTA", "MAGIKARP",
}
local CYCLE_FRAMES = 240 -- the original waits ~4s between picks

local function tryImage(path)
  if not path then return nil end
  local ok, img = pcall(love.graphics.newImage, path)
  return ok and img or nil
end

-- the importer seeds field.title with {path,width,height} descriptors
-- (the shape IntroMovie unwraps); mod patches may use plain path strings
local function imagePath(entry)
  if type(entry) == "table" then return entry.path end
  return entry
end

function TitleState.new(game, opts)
  opts = opts or {}
  local self = setmetatable({}, TitleState)
  self.game = game
  self.onNewGame = opts.onNewGame
  self.onContinue = opts.onContinue
  -- branding comes from field.title with the shipped art as fallback, so
  -- a total conversion rebrands the title without replacing the screen
  local title = (game.data.field and game.data.field.title) or {}
  self.title = title
  self.logo = tryImage(imagePath(title.logo)
                       or "assets/logo/pokemon_logo.png")
  -- versionRibbon is the file-12 key; version is the importer's
  self.version = tryImage(imagePath(title.versionRibbon or title.version)
                          or "assets/generated/title/red_version.png")
  self.player = tryImage("assets/generated/title/player.png")
  self.cycleSpecies = (type(title.cycleSpecies) == "table"
                       and #title.cycleSpecies > 0)
                      and title.cycleSpecies or CYCLE_SPECIES
  self.sprites = {} -- species -> image or false (load failed)
  self.cycleIndex = 1
  self.timer = 0
  self.blink = 0
  return self
end

function TitleState:enter()
  local data = self.game.data
  local song = self.title.music or "Music_TitleScreen"
  if data.audio and data.audio.songs and data.audio.songs[song] then
    pcall(Music.play, data, song)
  end
end

function TitleState:currentSprite()
  local species = self.cycleSpecies[self.cycleIndex]
  local cached = self.sprites[species]
  if cached == nil then
    local def = self.game.data.pokemon[species]
    cached = tryImage(def and def.spriteFront) or false
    self.sprites[species] = cached
  end
  return cached or nil
end

local function hasSave()
  local ok, info = pcall(function()
    return love.filesystem and love.filesystem.getInfo
       and love.filesystem.getInfo("save.lua") or nil
  end)
  return ok and info ~= nil
end

-- The CONTINUE info window (main_menu.asm DisplayContinueGameInfo):
-- PLAYER / BADGES / POKéDEX / TIME over the title, shown after choosing
-- CONTINUE.  A confirms and loads the game, B returns to the main menu.
local ContinueInfo = {}
ContinueInfo.__index = ContinueInfo

function ContinueInfo.new(title, save)
  return setmetatable({ title = title, game = title.game, save = save },
                      ContinueInfo)
end

function ContinueInfo:update(dt)
  local input = self.game.input
  if input:wasPressed("a") then
    self.game.stack:pop()
    if self.title.onContinue then self.title.onContinue() end
  elseif input:wasPressed("b") then
    self.game.stack:pop()
    self.title:openMenu()
  end
end

function ContinueInfo:draw()
  local save = self.save
  -- box at (4,7), 8x14 content; labels double-spaced from (5,9)
  Font.drawBox(4, 7, 16, 10)
  love.graphics.setColor(0, 0, 0, 1)
  Font.draw("PLAYER", 40, 72)
  Font.draw((save.player and save.player.name) or "RED", 96, 72)
  local badges = require("src.inventory.Badges").count(self.game.data, save)
  Font.draw("BADGES", 40, 88)
  Font.draw(("%2d"):format(badges), 128, 88)
  local owned = 0
  for _ in pairs(save.pokedex and save.pokedex.owned or {}) do
    owned = owned + 1
  end
  Font.draw("POKéDEX", 40, 104)
  Font.draw(("%3d"):format(owned), 120, 104)
  local t = math.floor(save.playTime or 0)
  Font.draw("TIME", 40, 120)
  Font.draw(("%3d:%02d"):format(math.floor(t / 3600),
                                math.floor(t / 60) % 60), 104, 120)
  love.graphics.setColor(1, 1, 1, 1)
end

function TitleState:openMenu()
  local Menu = require("src.ui.Menu")
  local game = self.game
  local items = {}
  if hasSave() then
    table.insert(items, { label = "CONTINUE", onSelect = function()
      -- peek at the save for the info window; fall through if the
      -- file can't be read
      local ok, loaded = pcall(require("src.core.SaveData").load)
      if ok and loaded then
        game.stack:push(ContinueInfo.new(self, loaded))
      elseif self.onContinue then
        self.onContinue()
      end
    end })
  end
  table.insert(items, { label = "NEW GAME", onSelect = function()
    if self.onNewGame then self.onNewGame() end
  end })
  table.insert(items, { label = "OPTION", onSelect = function()
    require("src.ui.Screens").push(game, "OptionsMenu")
  end })
  game.stack:push(Menu.new(game, items,
                           { tx = 0, ty = 0, tw = 13, th = #items * 2 + 2 }))
end

function TitleState:update(dt)
  self.timer = self.timer + 1
  self.blink = (self.blink + 1) % 60
  if self.timer >= CYCLE_FRAMES then
    self.timer = 0
    -- random pick that never repeats the current one
    if #self.cycleSpecies > 1 then
      local pick = self.cycleIndex
      while pick == self.cycleIndex do
        pick = love.math.random(1, #self.cycleSpecies)
      end
      self.cycleIndex = pick
    end
    self.slideIn = 20 -- TitleScreenScrollInMon slides the pic in
  end
  if self.slideIn and self.slideIn > 0 then
    self.slideIn = self.slideIn - 1
  end
  local input = self.game.input
  if input:wasPressed("start") or input:wasPressed("a") then
    -- the title mon cries when you leave the title (.finishedWaiting)
    require("src.core.Sound").playCry(self.game.data,
                                      self.cycleSpecies[self.cycleIndex])
    self:openMenu()
  end
end

-- The original tilemap (engine/movie/title.asm): logo at tile (2,1),
-- the version ribbon at (7,8), Red's title art as OAM at px (82,80),
-- the title mon in the 7x7 box at tile (5,10), copyright on row 17.
function TitleState:draw()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 144)
  if self.logo then
    love.graphics.draw(self.logo, 16, 8)
  else
    love.graphics.setColor(0, 0, 0, 1)
    Font.draw("POKéMON RED", (160 - 11 * 8) / 2, 24)
    love.graphics.setColor(1, 1, 1, 1)
  end
  if self.version then
    -- the strip holds Red+Green+Version glyphs; the tilemap prints
    -- tiles $60,$61 ("Red"), a space, then $65-$69 ("Version")
    local iw, ih = self.version:getDimensions()
    love.graphics.draw(self.version,
      love.graphics.newQuad(0, 0, 16, 8, iw, ih), 56, 64)
    love.graphics.draw(self.version,
      love.graphics.newQuad(40, 0, 40, 8, iw, ih), 80, 64)
  end
  local sprite = self:currentSprite()
  if sprite then
    local w, h = sprite:getDimensions()
    local slide = (self.slideIn or 0) * 8 -- scroll in from the right
    -- bottom-aligned and centered in the (5,10)-(11,16) tile box
    love.graphics.draw(sprite, 40 + math.floor((56 - w) / 2) + slide,
                       136 - h)
  end
  -- Red is OAM in the original: he draws over the mon's box edge
  if self.player then
    love.graphics.draw(self.player, 82, 80)
  end
  love.graphics.setColor(0, 0, 0, 1)
  -- the copyright row (tile 2,17); copyrightText because field.title's
  -- copyright key already names the extracted image strip
  Font.draw(self.title.copyrightText or "2026 bois club games", 1, 136)
  love.graphics.setColor(1, 1, 1, 1)
end

return TitleState
