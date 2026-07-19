-- Screen-by-screen end credits (engine/movie/credits.asm HallOfFamePC +
-- Credits).  After the Hall of Fame induction fades out, the screen sits
-- blank for 100 frames, then the black letterbox bars appear
-- (FillFourRowsWithBlack: rows 0-3 and 14-17), Music_Credits starts and
-- the first screen follows 128 frames later.  Each CreditsOrder screen
-- places its lines at hlcoord 9,6 plus the per-line signed column offset
-- (rows 6, 8, 10, ...) and runs its terminator:
--   CRED_TEXT_FADE_MON  fade in (4 BGP steps x 5 frames), hold 90, mon wipe
--   CRED_TEXT_MON       text appears at once, hold 110, mon wipe
--   CRED_TEXT_FADE      fade in, hold 120, next screen replaces the text
--   CRED_TEXT           text appears at once, hold 140
-- The mon wipe is DisplayCreditsMon: the middle band scrolls left 8px per
-- frame for 27 frames (ScrollCreditsMonLeft x7 then x20) while the next
-- CreditsMons entry crosses right-to-left as a black silhouette
-- (BGP %11111100), leaving the band blank; BGP is left at %11000000, which
-- is why every post-wipe screen is a FADE variant.  CRED_COPYRIGHT
-- composes the Nintendo / Creatures inc. / GAME FREAK inc. block on its
-- screen (LoadCopyrightTiles: rows 7/9/11 from column 2).  CRED_THE_END
-- waits 16 frames on the blank band, shows the interleaved THE END
-- letters at tile (4,8), and runs one more FadeInCredits (a no-op: the
-- letters are color 3, so they are black from the start).
--
-- Then the caller's onTheEnd fires -- the point where
-- HallOfFameResetEventsAndSaveScript (scripts/HallOfFame.asm) sets
-- wLastBlackoutMap := PALLET_TOWN and runs SaveGameData -- the screen
-- holds 600 more frames (the script's 5 x 120 DelayFrames) and finally
-- waits for A/B (WaitForTextScrollButtonPress: no visible arrow here and
-- no press SFX) before popping and calling onDone (the script's
-- `jp Init`).  If field.credits hasn't been extracted the roll degrades
-- to just THE END.

local Font = require("src.render.Font")
local Music = require("src.core.Music")

local Credits = {}
Credits.__index = Credits
Credits.isOpaque = true

-- FadeInCredits: HoFGBPalettes steps the text color index through GB
-- shades 0 (white) -> 1 -> 2 -> 3 (black), 5 frames per step.  The font
-- glyphs are black-on-transparent, so drawing them at these alphas over
-- the white band reproduces the 255 -> 170 -> 85 -> 0 gray ramp.
local FADE_STEPS = { 0, 1 / 3, 2 / 3, 1 }
local FADE_STEP_FRAMES = 5
local FADE_FRAMES = FADE_STEP_FRAMES * #FADE_STEPS -- 20

-- DelayFrames after each screen's text is up (Credits .next1/.next2)
local HOLD_FADE_MON = 90
local HOLD_MON = 110
local HOLD_FADE = 120
local HOLD_TEXT = 140

local WIPE_FRAMES = 27 -- ScrollCreditsMonLeft: 7 + 20 calls, 8px/frame

-- LoadCopyrightTiles (engine/movie/title.asm CopyrightTextString): tile
-- sequences into the extracted title/copyright.png strip (tiles $60-$72:
-- (c)'95.'96.'98 + Nintendo + Creatures inc.); the GAME FREAK inc. row is
-- the title/gamefreak_inc.png strip (GameFreakLogoGraphics, tiles
-- $73-$7B), with the intro's composed gamefreak_text.png as a fallback
-- for pre-regeneration data.
local COPY_PREFIX = { 0, 1, 2, 1, 3, 1, 4 }               -- (c)'95.'96.'98
local COPY_NINTENDO = { 5, 6, 7, 8, 9, 10 }               -- Nintendo
local COPY_CREATURES = { 11, 12, 13, 14, 15, 16, 17, 18 } -- Creatures inc.

local function tryImage(path)
  if not path then return nil end
  local ok, img = pcall(love.graphics.newImage, path)
  return ok and img or nil
end

-- DisplayCreditsMon shows the mon as a black silhouette: BGP %11111100
-- maps colors 1-3 to black and keeps color 0 white.  The extracted
-- front-sprite PNGs keep GB color 0 as white/transparent pixels, so
-- paint every opaque non-white pixel black.  Without love.image
-- (headless stub) fall back to a black tint (second return value), which
-- also blackens interior color-0 pixels.
local function silhouette(path)
  if not path then return nil end
  if love.image and love.image.newImageData then
    local ok, imgData = pcall(love.image.newImageData, path)
    if ok and imgData then
      imgData:mapPixel(function(_, _, r, g, b, a)
        if a > 0 and r + g + b < 2.9 then return 0, 0, 0, 1 end
        return r, g, b, a
      end)
      local ok2, img = pcall(love.graphics.newImage, imgData)
      if ok2 and img then return img, false end
    end
  end
  local ok, img = pcall(love.graphics.newImage, path)
  if ok and img then return img, true end
  return nil
end

function Credits.new(game, onDone, onTheEnd)
  local self = setmetatable({}, Credits)
  self.game = game
  self.onDone = onDone
  self.onTheEnd = onTheEnd
  local credits = game.data.field and game.data.field.credits or {}
  self.screens = credits.screens or {}
  self.theEnd = credits.theEnd
  self.music = credits.music or "Music_Credits"
  self.index = 0
  self.screen = nil
  self.phase = "white"
  self.timer = 100 -- HallOfFamePC: ClearScreen + 100 DelayFrames
  self.shade = 0

  -- assets (all optional; missing ones fall back to Font glyphs)
  self.endImg = tryImage(self.theEnd and self.theEnd.path)
  self.endQuads = {}
  if self.endImg then
    local iw, ih = self.endImg:getDimensions()
    for l = 0, 4 do -- 8x16 letter columns T,H,E,N,D
      self.endQuads[l] = love.graphics.newQuad(l * 8, 0, 8, 16, iw, ih)
    end
  end
  local title = game.data.field and game.data.field.title
  self.copyImg = tryImage(title and title.copyright and title.copyright.path)
  self.copyQuads = {}
  if self.copyImg then
    local iw, ih = self.copyImg:getDimensions()
    for t = 0, 18 do
      self.copyQuads[t] = love.graphics.newQuad(t * 8, 0, 8, 8, iw, ih)
    end
  end
  local intro = game.data.field and game.data.field.intro
  self.gfImg = tryImage(title and title.gamefreakInc
                        and title.gamefreakInc.path)
             or tryImage(intro and intro.gamefreakText
                         and intro.gamefreakText.path)
  return self
end

function Credits:enter()
  -- AnimateHallOfFame ended on HoFFadeOutScreenAndMusic: silence over the
  -- blank lead-in; MUSIC_CREDITS starts when the bars appear
  pcall(Music.stop)
end

function Credits:monSprite(species)
  local def = self.game.data.pokemon and self.game.data.pokemon[species]
  return silhouette(def and def.spriteFront)
end

-- advance to the next CreditsOrder screen (Credits .nextCreditsScreen);
-- past the last one, CRED_THE_END takes over
function Credits:nextScreen()
  self.index = self.index + 1
  local screen = self.screens[self.index]
  self.screen = screen
  if not screen then
    self.phase = "end_blank" -- .showTheEnd: ld c, 16 on the blank band
    self.timer = 16
    return
  end
  if screen.fade then
    self.phase = "fade"
    self.timer = FADE_FRAMES
    self.shade = 0
  else
    -- no fade: BGP was left black by the previous screen's fade
    self.phase = "hold"
    self.shade = 1
    self.timer = screen.mon and HOLD_MON or HOLD_TEXT
  end
end

function Credits:update(dt)
  if self.phase == "end_wait" then
    -- WaitForTextScrollButtonPress: A or B ends the credits; the HoF
    -- script then soft-resets (`jp Init`).  No SFX on this press.
    local input = self.game.input
    if input:wasPressed("a") or input:wasPressed("b") then
      self.game.stack:pop()
      if self.onDone then self.onDone() end
    end
    return
  end
  self.timer = self.timer - 1
  if self.timer > 0 then
    if self.phase == "fade" then
      local step = math.floor((FADE_FRAMES - self.timer) / FADE_STEP_FRAMES)
      self.shade = FADE_STEPS[math.min(#FADE_STEPS, step + 1)]
    end
    return
  end
  if self.phase == "white" then
    -- bars on, stop-music SFX + PlayMusic MUSIC_CREDITS, then 128 frames
    self.phase = "intro"
    self.timer = 128
    local data = self.game.data
    if data.audio and data.audio.songs and data.audio.songs[self.music] then
      pcall(Music.play, data, self.music)
    end
  elseif self.phase == "intro" then
    self:nextScreen()
  elseif self.phase == "fade" then
    self.shade = 1
    self.phase = "hold"
    self.timer = self.screen.mon and HOLD_FADE_MON or HOLD_FADE
  elseif self.phase == "hold" then
    if self.screen.mon then
      self.phase = "wipe"
      self.timer = WIPE_FRAMES
      self.monImg, self.monTint = self:monSprite(self.screen.mon)
    else
      self:nextScreen()
    end
  elseif self.phase == "wipe" then
    self.monImg = nil
    self:nextScreen()
  elseif self.phase == "end_blank" then
    -- THE END letters are color 3: visible from the first fade palette
    self.phase = "end_fade"
    self.timer = FADE_FRAMES
  elseif self.phase == "end_fade" then
    -- Credits returns to HallOfFameResetEventsAndSaveScript here: the
    -- save happens now, then 5 x 120 DelayFrames before the button wait
    if self.onTheEnd then self.onTheEnd() end
    self.phase = "end_hold"
    self.timer = 600
  elseif self.phase == "end_hold" then
    self.phase = "end_wait"
  end
end

-- one credits screen: lines at rows 6/8/10... with the extractor's
-- absolute column (9 + signed offset), plus the copyright block
function Credits:drawPage(screen, xoff, shade)
  if not screen then return end
  love.graphics.setColor(0, 0, 0, shade)
  for i, line in ipairs(screen.lines or {}) do
    Font.draw(line.text, xoff + (line.column or 0) * 8, 48 + (i - 1) * 16)
  end
  love.graphics.setColor(1, 1, 1, 1)
  if screen.copyright then self:drawCopyright(xoff) end
end

function Credits:drawCopyright(xoff)
  local img = self.copyImg
  if img then
    -- the copyright tiles are loaded fresh (not color-shifted like the
    -- font), so they are color 3: always solid, no fade
    local function row(seq, x, y)
      for _, t in ipairs(seq) do
        love.graphics.draw(img, self.copyQuads[t], x, y)
        x = x + 8
      end
      return x
    end
    row(COPY_PREFIX, xoff + 16, 56)
    row(COPY_NINTENDO, xoff + 80, 56)
    row(COPY_PREFIX, xoff + 16, 72)
    row(COPY_CREATURES, xoff + 80, 72)
    row(COPY_PREFIX, xoff + 16, 88)
    if self.gfImg then
      love.graphics.draw(self.gfImg, xoff + 80, 88)
    else
      love.graphics.setColor(0, 0, 0, 1)
      Font.draw("GAME FREAK", xoff + 80, 88)
      love.graphics.setColor(1, 1, 1, 1)
    end
  else
    love.graphics.setColor(0, 0, 0, 1)
    Font.draw("Nintendo", xoff + 80, 56)
    Font.draw("Creatures inc.", xoff + 80, 72)
    Font.draw("GAME FREAK inc.", xoff + 16, 88)
    love.graphics.setColor(1, 1, 1, 1)
  end
end

-- the mon silhouette crossing during the wipe; x is the left edge of its
-- 7x7 box (bottom-centered inside it, like the GB pic buffer padding)
function Credits:drawMon(x)
  local img = self.monImg
  if not img then return end
  local w, h = img:getDimensions()
  if self.monTint then love.graphics.setColor(0, 0, 0, 1) end
  love.graphics.draw(img, x + math.floor((56 - w) / 2), 48 + (56 - h))
  love.graphics.setColor(1, 1, 1, 1)
end

-- TheEndTextString: 12 tile columns from (4,8), each an 8x16 letter
-- column of the interleaved the_end gfx (pattern indexes T,H,E,N,D)
function Credits:drawTheEnd()
  local te = self.theEnd
  if self.endImg and te and te.pattern then
    love.graphics.setColor(1, 1, 1, 1)
    for i, letter in ipairs(te.pattern) do
      if letter >= 0 then
        love.graphics.draw(self.endImg, self.endQuads[letter],
                           32 + (i - 1) * 8, 64)
      end
    end
  else
    love.graphics.setColor(0, 0, 0, 1)
    Font.draw((te and te.display) or "T H E  E N D", 32, 64)
    love.graphics.setColor(1, 1, 1, 1)
  end
end

function Credits:draw()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 144)
  if self.phase == "white" then return end
  -- FillFourRowsWithBlack: rows 0-3 and 14-17 stay solid black
  love.graphics.setColor(0, 0, 0, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 32)
  love.graphics.rectangle("fill", 0, 112, 160, 32)
  love.graphics.setColor(1, 1, 1, 1)
  if self.phase == "fade" or self.phase == "hold" then
    self:drawPage(self.screen, 0, self.shade)
  elseif self.phase == "wipe" then
    -- ScrollCreditsMonLeft: the middle band scrolls left 8px/frame while
    -- the silhouette enters from the right edge one screen behind it
    local s = (WIPE_FRAMES - self.timer) * 8
    self:drawPage(self.screen, -s, 1)
    self:drawMon(160 - s)
  elseif self.phase == "end_fade" or self.phase == "end_hold"
      or self.phase == "end_wait" then
    self:drawTheEnd()
  end
  love.graphics.setColor(1, 1, 1, 1)
end

return Credits
