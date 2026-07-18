-- Hall of Fame induction (engine/movie/hall_of_fame.asm): each party
-- member's front sprite scrolls onto the screen (HoFShowMonOrPlayer's
-- .ScrollPic), then its name/level shows and its cry plays
-- (HoFDisplayAndRecordMonInfo).  After the last mon, HoFDisplayPlayerStats
-- shows the trainer name, play time, money and Prof. Oak's dex rating.
-- Plays Music_HallOfFame when the audio data has it.  Calls onDone() after
-- popping itself.

local Font = require("src.render.Font")
local Music = require("src.core.Music")
local Sound = require("src.core.Sound")

local HallOfFame = {}
HallOfFame.__index = HallOfFame
HallOfFame.isOpaque = true

-- SGB: SetPal_PokemonWholeScreen for the mon on display
function HallOfFame:sgbPalettes(game)
  local P = require("src.render.PaletteFX")
  local mon = game.save.party[self.index or 0]
  if mon then
    local c = P.monPal(game.data, mon.species)
    if c then return { P.whole(c) } end
    return nil
  end
  return P.wholeNamed(game.data, "MEWMON")
end

local MON_FRAMES = 150 -- ~2.5s per inductee (A advances early)

-- HoFShowMonOrPlayer's .ScrollPic: hSCX is nudged by e = 4px per
-- DelayFrame (doubled on SGB) until it settles.  The back pic (an
-- enlarged, blurred 2x scale of the back sprite) sweeps right-to-left
-- and off the left edge first; tracing the actual hSCX/hSCY math shows
-- the real front pic that follows enters from the *left* edge and
-- slides *right* into its resting tile, at that same 4px/frame rate --
-- that's the half we port here (the back-pic wipe is a VRAM/scroll-
-- register trick with no equivalent in this sprite-based renderer).
local SCROLL_SPEED = 4 -- px/frame @ 60fps

local function tryImage(path)
  if not path then return nil end
  local ok, img = pcall(love.graphics.newImage, path)
  return ok and img or nil
end

-- POKéDEX rating tiers (engine/events/pokedex_rating.asm DexRatingsTable)
local function dexRatingKey(owned)
  if owned >= 150 then return "_DexRatingText_Own150To151" end
  local lo = math.floor(owned / 10) * 10
  return ("_DexRatingText_Own%dTo%d"):format(lo, lo + 9)
end

-- \n/\v/\f-marked extracted text, one Font.draw line at a time (same
-- technique as DexEntryMenu.lua's dex-description block)
local function drawTextBlock(text, x, y, maxY)
  for line in (text:gsub("\v", "\n"):gsub("\f", "\n") .. "\n"):gmatch("(.-)\n") do
    if maxY and y > maxY then break end
    Font.draw(line, x, y)
    y = y + 10
  end
  return y
end

function HallOfFame.new(game, onDone)
  local self = setmetatable({}, HallOfFame)
  self.game = game
  self.onDone = onDone
  self.index = 0
  self.timer = 0
  self.phase = "mons"
  self.sprites = {} -- species -> image or false
  return self
end

function HallOfFame:enter()
  local data = self.game.data
  if data.audio and data.audio.songs and data.audio.songs.Music_HallOfFame then
    pcall(Music.play, data, "Music_HallOfFame")
  end
  self:nextMon()
end

function HallOfFame:nextMon()
  self.index = self.index + 1
  local mon = self.game.save.party[self.index]
  if mon then
    self.timer = MON_FRAMES
    Sound.playCry(self.game.data, mon.species)
    -- scroll the new inductee's pic in from the left (see SCROLL_SPEED)
    local sprite = self:spriteFor(mon.species)
    local w = sprite and sprite:getWidth() or 0
    self.scrollRestX = math.floor((160 - w) / 2)
    self.scrollX = -w
  else
    self.phase = "congrats"
  end
end

function HallOfFame:spriteFor(species)
  local cached = self.sprites[species]
  if cached == nil then
    local def = self.game.data.pokemon[species]
    cached = tryImage(def and def.spriteFront) or false
    self.sprites[species] = cached
  end
  return cached or nil
end

-- HoFDisplayPlayerStats' DisplayDexRating tally (also
-- OverworldController:dexRating / PokedexMenu.new's seen+owned counts)
function HallOfFame:dexSeenOwned()
  local dex = self.game.save.pokedex or { seen = {}, owned = {} }
  local seen, owned = 0, 0
  for _ in pairs(dex.seen or {}) do seen = seen + 1 end
  for _ in pairs(dex.owned or {}) do owned = owned + 1 end
  return seen, owned
end

function HallOfFame:update(dt)
  local input = self.game.input
  if self.phase == "mons" then
    if self.scrollX and self.scrollX < self.scrollRestX then
      self.scrollX = math.min(self.scrollRestX, self.scrollX + SCROLL_SPEED)
    end
    self.timer = self.timer - 1
    if input:wasPressed("a") or self.timer <= 0 then
      self:nextMon()
    end
  elseif input:wasPressed("a") then
    Sound.play(self.game.data, "Press_AB")
    self.game.stack:pop()
    if self.onDone then self.onDone() end
  end
end

function HallOfFame:draw()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 144)
  love.graphics.setColor(0, 0, 0, 1)
  if self.phase == "mons" then
    Font.draw("HALL OF FAME", (160 - 12 * 8) / 2, 8)
    local mon = self.game.save.party[self.index]
    if mon then
      local def = self.game.data.pokemon[mon.species]
      love.graphics.setColor(1, 1, 1, 1)
      local sprite = self:spriteFor(mon.species)
      if sprite then
        local w, h = sprite:getDimensions()
        love.graphics.draw(sprite, self.scrollX or math.floor((160 - w) / 2), 96 - h)
      end
      love.graphics.setColor(0, 0, 0, 1)
      local name = mon.nickname or (def and def.name) or mon.species
      Font.draw(name, 32, 108)
      Font.draw((":L%d"):format(mon.level), 112, 108)
    end
  else
    -- HoFDisplayPlayerStats (no "HALL OF FAME" banner here -- the real
    -- screen is a fresh ClearScreen): trainer name, play time, money,
    -- then the POKéDEX seen/owned tally and Prof. Oak's rating text,
    -- using the same real save-data fields as TrainerCard.lua
    -- (save.player.name/playTime/money) and PokedexMenu.lua/
    -- OverworldController:dexRating (save.pokedex.seen/owned).
    local save = self.game.save
    local text = self.game.data.text or {}
    local y = 8
    Font.draw(save.player.name or "RED", 8, y)
    y = y + 16
    local t = math.floor(save.playTime or 0)
    Font.draw(("PLAY TIME %3d:%02d"):format(math.floor(t / 3600),
                                            math.floor(t / 60) % 60), 8, y)
    y = y + 12
    Font.draw(("MONEY ¥%d"):format(save.money or 0), 8, y)
    y = y + 16

    local seen, owned = self:dexSeenOwned()
    local seenOwned = text._DexSeenOwnedText
      or "POKéDEX   Seen:{NUM:wDexRatingNumMonsSeen, 1, 3}\n         Owned:{NUM:wDexRatingNumMonsOwned, 1, 3}"
    seenOwned = seenOwned
      :gsub("{NUM:wDexRatingNumMonsSeen[^}]*}", tostring(seen))
      :gsub("{NUM:wDexRatingNumMonsOwned[^}]*}", tostring(owned))
    y = drawTextBlock(seenOwned, 8, y) + 6

    local ratingHeader = (text._DexRatingText or "POKéDEX Rating{COLON}"):gsub("{COLON}", ":")
    Font.draw(ratingHeader, 8, y)
    y = y + 12

    local rating = text[dexRatingKey(owned)] or "Keep it up!"
    drawTextBlock(rating, 8, y, 136)
  end
  love.graphics.setColor(1, 1, 1, 1)
end

return HallOfFame
