-- The intro sequence (engine/movie/oak_speech/oak_speech.asm): Oak's
-- welcome, the NIDORINO show-off, player and rival naming, and the
-- closing "legend is about to unfold" text followed by the shrink-away:
-- the player pic collapses through ShrinkPic1/ShrinkPic2 into the
-- overworld walking sprite before the fade to white.  Uses the real
-- extracted texts (_OakSpeechText1/2A/2B/3, _IntroducePlayerText,
-- _IntroduceRivalText) with literal fallbacks.
-- Calls onDone() after popping itself.

local Sound = require("src.core.Sound")
local Music = require("src.core.Music")
local TextBox = require("src.render.TextBox")
local Font = require("src.render.Font")

local OakSpeech = {}
OakSpeech.__index = OakSpeech
OakSpeech.isOpaque = true

-- SGB: generic whole-screen palette (SET_PAL_GENERIC)
function OakSpeech:sgbPalettes(game)
  return require("src.render.PaletteFX").wholeNamed(game.data, "MEWMON")
end

local FALLBACKS = {
  _OakSpeechText1 = "Hello there!\nWelcome to the\vworld of POKéMON!\fMy name is OAK!\nPeople call me\vthe POKéMON PROF!",
  _OakSpeechText2A = "This world is\ninhabited by\vcreatures called\vPOKéMON!",
  _OakSpeechText2B = "\fFor some people,\nPOKéMON are\vpets. Others use\vthem for fights.\fMyself...\fI study POKéMON\nas a profession.",
  _OakSpeechText3 = "{PLAYER}!\fYour very own\nPOKéMON legend is\vabout to unfold!\fA world of dreams\nand adventures\vwith POKéMON\vawaits! Let's go!",
  _IntroducePlayerText = "First, what is\nyour name?",
  _IntroduceRivalText = "This is my grand-\nson. He's been\vyour rival since\vyou were a baby.\f...Erm, what is\nhis name again?",
}

local function textOr(game, key)
  local t = game.data.text
  return (t and t[key]) or FALLBACKS[key]
end

local function tryImage(path)
  if not path then return nil end
  local ok, img = pcall(love.graphics.newImage, path)
  return ok and img or nil
end

function OakSpeech.new(game, onDone)
  local self = setmetatable({}, OakSpeech)
  self.game = game
  self.onDone = onDone
  self.step = 0
  self.pic = nil
  local trainers = game.data.trainers or {}
  self.oakPic = tryImage(trainers.OPP_PROF_OAK and trainers.OPP_PROF_OAK.pic)
  self.rivalPic = tryImage(trainers.OPP_RIVAL1 and trainers.OPP_RIVAL1.pic)
  local nido = game.data.pokemon and game.data.pokemon.NIDORINO
  self.nidorinoPic = tryImage(nido and nido.spriteFront)
  -- RedPicFront (gfx/player/red.png, shared with the trainer card) and
  -- the ShrinkPic1/ShrinkPic2 frames (gfx/player/shrink{1,2}.png)
  self.playerPic = tryImage("assets/generated/trainer_card/red.png")
  local oakGfx = game.data.field and game.data.field.oakSpeech
  self.shrinkPic1 = tryImage(oakGfx and oakGfx.shrink1
                             or "assets/generated/intro/shrink1.png")
  self.shrinkPic2 = tryImage(oakGfx and oakGfx.shrink2
                             or "assets/generated/intro/shrink2.png")
  -- RedSprite: the walking sprite the pic shrinks into (frame 0 =
  -- standing, facing down)
  local red = game.data.sprites and game.data.sprites.SPRITE_RED
  self.walkSheet = tryImage(red and red.image)
  return self
end

function OakSpeech:enter()
  -- MUSIC_ROUTES2 plays under the whole speech (oak_speech.asm:43-48)
  Music.play(self.game.data, "Music_Routes2")
  self:advance()
end

function OakSpeech:say(key, next)
  self.game.stack:push(TextBox.new(self.game, textOr(self.game, key), next))
end

local STEPS = {
  -- 1. Oak's welcome
  function(self)
    self.pic = self.oakPic
    self:say("_OakSpeechText1", function() self:advance() end)
  end,
  -- 2. NIDORINO show-off, with its cry
  function(self)
    self.pic = self.nidorinoPic
    Sound.playCry(self.game.data, "NIDORINO")
    self:say("_OakSpeechText2A", function() self:advance() end)
  end,
  -- 3. the rest of the world-of-POKéMON spiel
  function(self)
    self:say("_OakSpeechText2B", function() self:advance() end)
  end,
  -- 4. "First, what is your name?" over the player's own pic
  --    (RedPicFront, oak_speech.asm:86-91) then the naming screen
  function(self)
    self.pic = self.playerPic or self.oakPic
    self:say("_IntroducePlayerText", function() self:advance() end)
  end,
  function(self)
    local NamingScreen = require("src.ui.NamingScreen")
    self.game.stack:push(NamingScreen.new(self.game, {
      title = "YOUR NAME?",
      presets = { "RED", "ASH", "JACK" },
      maxLen = 7,
      onDone = function(name)
        self.game.save.player.name = name
        self:advance()
      end,
    }))
  end,
  -- 6. the rival introduction and naming
  function(self)
    self.pic = self.rivalPic
    self:say("_IntroduceRivalText", function() self:advance() end)
  end,
  function(self)
    local NamingScreen = require("src.ui.NamingScreen")
    self.game.stack:push(NamingScreen.new(self.game, {
      title = "HIS NAME?",
      presets = { "BLUE", "GARY", "JOHN" },
      maxLen = 7,
      onDone = function(name)
        self.game.save.player.rival = name
        self:advance()
      end,
    }))
  end,
  -- 8. "your very own POKéMON legend is about to unfold!" over the
  --    player pic again (oak_speech.asm:105-113)
  function(self)
    self.pic = self.playerPic or self.oakPic
    self:say("_OakSpeechText3", function() self:advance() end)
  end,
  -- 9. SFX_SHRINK: the pic collapses through the two shrink frames
  --    into the walking sprite, then fades to white (oak_speech.asm
  --    .next, lines 115-166).  Not skippable, like the DelayFrames
  --    chain it ports.
  function(self)
    Sound.play(self.game.data, "Shrink")
    -- the OakSpeechText3 box holds its last page on screen through the
    -- shrink (pokered text boxes persist until overwritten)
    self.shrinkText = self:lastPageLines("_OakSpeechText3")
    self.shrink = { frame = 0 }
  end,
}

-- the last two visible lines of a text's final page, pre-encoded
function OakSpeech:lastPageLines(key)
  local ok, lines = pcall(function()
    local text = TextBox.substitute(self.game, textOr(self.game, key))
    local pages = TextBox.paginate(text)
    local page = pages[#pages]
    local out = {}
    for i = math.max(1, #page - 1), #page do
      out[#out + 1] = Font.encode(page[i])
    end
    return out
  end)
  return ok and lines or nil
end

function OakSpeech:advance()
  self.step = self.step + 1
  local fn = STEPS[self.step]
  if fn then
    fn(self)
  else
    self:finish()
  end
end

function OakSpeech:finish()
  -- the map theme starts with the overworld beneath (the original's
  -- special warp into Pallet Town)
  local ow = self.game.overworld
  local mapId = (ow and ow.map and ow.map.id)
                or (self.game.save.player and self.game.save.player.map)
  if mapId then Music.playMap(self.game.data, mapId) end
  self.game.stack:pop()
  if self.onDone then self.onDone() end
end

-- Shrink timeline (oak_speech.asm .next):
--   frames  1-4   RedPicFront still up      (ld c, 4 / DelayFrames)
--   frames  5-8   ShrinkPic1                (ld c, 4 / DelayFrames)
--   frames  9-28  ShrinkPic2, music fades   (wAudioFadeOutControl; ld c, 20)
--   frames 29-78  pic area cleared, walking sprite at the standard
--                 player screen spot        (ResetPlayerSpriteData /
--                 ClearScreenArea / wUpdateSpritesEnabled; ld c, 50)
--   frames 79-102 GBFadeOutToWhite          (3 palettes x 8 frames)
function OakSpeech:update(dt)
  if not self.shrink then return end
  local s = self.shrink
  s.frame = s.frame + 1
  if s.frame == 5 then
    self.pic = self.shrinkPic1 or self.pic
  elseif s.frame == 9 then
    self.pic = self.shrinkPic2 or self.pic
    -- wAudioFadeOutControl = 10: the music ramps to silence over ~70
    -- frames (7 levels x 10), reaching 0 just as the fade-to-white
    -- begins at frame 79, instead of a hard cut (oak_speech.asm:145-149,
    -- home/fade_audio.asm)
    Music.fadeOut(10)
  elseif s.frame == 29 then
    self.pic = nil
    self.walkVisible = true
  elseif s.frame >= 79 and s.frame <= 102 then
    self.fadeLevel = math.floor((s.frame - 79) / 8) + 1
  elseif s.frame > 102 then
    self:finish()
  end
end

function OakSpeech:draw()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 144)
  if self.pic then
    -- IntroDisplayPicCenteredOrUpperRight centered: the 7x7-tile pic
    -- area sits at hlcoord 6,4 = (48,32); smaller mon pics pad inside
    -- it like the sprite buffer does ((8 - w) >> 1 tiles across,
    -- bottom-aligned)
    local w, h = self.pic:getDimensions()
    local x = 48 + math.floor((8 - w / 8) / 2) * 8
    local y = 32 + (7 - h / 8) * 8
    love.graphics.draw(self.pic, x, y)
  end
  if self.walkVisible and self.walkSheet then
    -- ResetPlayerSpriteData: Y screen pos $3c, X screen pos $40
    self.walkQuad = self.walkQuad
      or love.graphics.newQuad(0, 0, 16, 16, self.walkSheet:getDimensions())
    love.graphics.draw(self.walkSheet, self.walkQuad, 64, 60)
  end
  if self.shrinkText then
    Font.drawBox(0, 12, 20, 6)
    love.graphics.setColor(0, 0, 0, 1)
    for i, line in ipairs(self.shrinkText) do
      local y = (12 + 2 * i) * 8
      for j, code in ipairs(line) do
        Font.drawCode(code, 8 + (j - 1) * 8, y)
      end
    end
    love.graphics.setColor(1, 1, 1, 1)
  end
  if self.fadeLevel then
    love.graphics.setColor(1, 1, 1, self.fadeLevel / 3)
    love.graphics.rectangle("fill", 0, 0, 160, 144)
    love.graphics.setColor(1, 1, 1, 1)
  end
end

return OakSpeech
