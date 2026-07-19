-- Boot splash + attract movie, a faithful port of PlayIntro
-- (engine/movie/intro.asm) and AnimateShootingStar (engine/movie/splash.asm)
-- using the real extracted art (data/generated/field.lua `intro` manifest).
--
-- Three frame-counted phases:
--  1. copyright card, 180 frames (intro.asm:311-312).
--  2. shooting star: 64 frames of empty letterbox (intro.asm:323-324), then
--     the big star streaks down-left for 40 frames while the GAME FREAK
--     logo + letters sit at (72,56)/(40,80) (splash.asm:27-60, 211-228),
--     the logo flashes 3x10 frames (splash.asm:72-82), 4 waves of small
--     stars rain from the logo -- 6x24 frames, +1px every 3 frames, lower
--     star blinking (splash.asm:97-146, 163-209) -- and a 40 frame hold
--     (intro.asm:329-331).
--  3. the Gengar/Nidorino fight (PlayIntroScene, intro.asm:23-141), played
--     from FIGHT_SCRIPT below: Music_IntroBattle starts, Gengar (56x56 BG
--     pose from a gengar_N.tilemap, at tile 13,7 = x104,y56) scrolls left
--     while Nidorino (48x48 OAM at x-8,y72) walks right, then the scripted
--     hip/hop hops, Gengar's raise + slash lunge, Nidorino's dodge leap,
--     retreat, crouch and final lunge, ending in a 24-frame fade to white
--     (GBFadeOutToWhite, home/fade.asm:26-40).
--
-- Any of A/B/START skips the whole movie (CheckForUserInterruption).
-- Pops itself and calls onDone() when finished or skipped.  All art loads
-- through pcall and every missing graphic degrades to a text/rect
-- fallback, so the movie stays headless-safe.

local Font = require("src.render.Font")
local Music = require("src.core.Music")
local Sound = require("src.core.Sound")

local IntroMovie = {}
IntroMovie.__index = IntroMovie
IntroMovie.isOpaque = true

-- SGB intro palettes: the splash uses PalPacket_GameFreakIntro (logo
-- GAMEFREAK, falling star columns RED/VIRIDIAN/BLUEMON), the attract
-- fight PalPacket_NidorinoIntro (PURPLEMON letterbox, BLACK bars)
function IntroMovie:sgbPalettes(game)
  local P = require("src.render.PaletteFX")
  if self.phase == 2 then
    local logo = P.pal(game.data, "GAMEFREAK")
    if not logo then return nil end
    return {
      P.whole(logo),
      P.zone(P.pal(game.data, "REDMON"), 5, 11, 7, 13),
      P.zone(P.pal(game.data, "VIRIDIAN"), 8, 11, 9, 13),
      P.zone(P.pal(game.data, "BLUEMON"), 12, 11, 14, 13),
    }
  elseif self.phase == 3 then
    local purple = P.pal(game.data, "PURPLEMON")
    if not purple then return nil end
    return {
      P.zone(P.pal(game.data, "BLACK"), 0, 0, 19, 3),
      P.zone(purple, 0, 4, 19, 13),
      P.zone(P.pal(game.data, "BLACK"), 0, 14, 19, 17),
    }
  end
  return nil -- the copyright card stays plain
end

local COPYRIGHT_FRAMES = 180  -- ld c, 180 (intro.asm:311-312)

-- phase 2 (shooting star) timeline, in frames from phase start
local STAR_START = 64         -- ld c, 64 (intro.asm:323-324)
local STAR_FRAMES = 40        -- OAM Y 0->160 in +4 steps (splash.asm:32-60)
local FLASH_START = STAR_START + STAR_FRAMES
local FLASH_FRAMES = 30       -- 3 loops x 10 frames (splash.asm:72-82)
local WAVES_START = FLASH_START + FLASH_FRAMES
local WAVE_FRAMES = 24        -- 8 substeps x 3 frames (splash.asm:186-209)
local WAVES_END = WAVES_START + 6 * WAVE_FRAMES  -- 4 waves + 2 empty
local SPLASH_FRAMES = WAVES_END + 40  -- ld c, 40 (intro.asm:329-331)

-- logo 16x24 at grid (10,9), letters row at grid y=12 cols 6..15
-- (GameFreakLogoOAMData, splash.asm:211-228; screen = grid*8, OAM offsets
-- cancel)
local LOGO_X, LOGO_Y = 72, 56
local TEXT_X, TEXT_Y = 40, 80

-- the 4 waves of small stars: screen X positions, all spawning at y=88
-- (OAM $68; SmallStarsWave*Coords, splash.asm:160-183)
local STAR_WAVES = {
  { 40, 56, 80, 112 },
  { 48, 64, 88, 104 },
  { 44, 68, 76, 92 },
  { 52, 84, 100, 108 },
}

-- Nidorino movement lists: {dy, dx} applied every 5 frames
-- (AnimateIntroNidorino, intro.asm:143-158)
local ANIM = {
  -- IntroNidorinoAnimation1..7 (intro.asm:370-437)
  { {0,0}, {-2,2}, {-1,2}, {1,2}, {2,2} },        -- 1: hop arc, +8 right
  { {0,0}, {-2,-2}, {-1,-2}, {1,-2}, {2,-2} },    -- 2: hop arc, -8 left
  { {0,0}, {-12,6}, {-8,6}, {8,6}, {12,6} },      -- 3: dodge leap, +24 right
  { {0,0}, {-8,-4}, {-4,-4}, {4,-4}, {8,-4} },    -- 4: high hop, -16 left
  { {0,0}, {-8,4}, {-4,4}, {4,4}, {8,4} },        -- 5: high hop, +16 right
  { {0,0}, {2,0}, {2,0}, {0,0} },                 -- 6: crouch, +4 down
  { {-8,-16}, {-7,-14}, {-6,-12}, {-4,-10} },     -- 7: lunge, -52/-25 up-left
}

-- PlayIntroScene, in source order (intro.asm:23-141).  `move` ops shift
-- 2px per 2 frames (IntroMoveMon, intro.asm:235-269): "scrollIn" moves
-- Nidorino right AND Gengar left together (the fallthrough at :247-259),
-- gengar dx<0 = MOVE_GENGAR_LEFT (SCX+2), dx>0 = MOVE_GENGAR_RIGHT.
local FIGHT_SCRIPT = {
  { move = "scrollIn", px = 80 },                       -- intro.asm:40-41
  { sfx = "Intro_Hip" }, { anim = 1 },                  -- :44-50
  { sfx = "Intro_Hop" }, { anim = 2 }, { wait = 10 },   -- :51-57
  { sfx = "Intro_Hip" }, { anim = 1 },                  -- :60-64
  { sfx = "Intro_Hop" }, { anim = 2 }, { wait = 30 },   -- :65-71
  { pose = 2 }, { sfx = "Intro_Raise" },                -- :74-78
  { move = "gengar", dx = -8 }, { wait = 30 },          -- :79-82
  { pose = 3 }, { sfx = "Intro_Crash" },                -- :85-89
  { move = "gengar", dx = 16 },                         -- :90-91
  { sfx = "Intro_Hip" }, { frame = 2 }, { anim = 3 },   -- :92-98
  { wait = 30 },                                        -- :99-100
  { move = "gengar", dx = -8 }, { pose = 1 },           -- :103-106
  { wait = 60 },                                        -- :107-108
  { sfx = "Intro_Hip" }, { frame = 1 }, { anim = 4 },   -- :111-117
  { sfx = "Intro_Hop" }, { anim = 5 }, { wait = 20 },   -- :118-124
  { frame = 2 }, { anim = 6 }, { wait = 30 },           -- :127-132
  { sfx = "Intro_Lunge" }, { frame = 3 }, { anim = 7 }, -- :135-141
  { fade = 24 },  -- GBFadeOutToWhite: 3 pals x 8 frames (home/fade.asm:26-40)
}

local function tryImage(path)
  if not path then return nil end
  local ok, img = pcall(love.graphics.newImage, path)
  return ok and img or nil
end

function IntroMovie.new(game, onDone)
  local self = setmetatable({}, IntroMovie)
  self.game = game
  self.onDone = onDone
  self.phase = 1
  self.timer = 0
  self.finished = false

  local intro = game.data.field and game.data.field.intro or {}
  self.introCfg = intro
  -- brand-level knobs (12 4.7): studio strings and the skip a total
  -- conversion or dev profile sets to jump straight to the title
  self.studio = intro.studio or {}
  self.skipAll = intro.skip and true or false
  local function img(e) return tryImage(e and e.path) end
  self.copyright = tryImage("assets/generated/title/copyright.png")
  self.logo = img(intro.gamefreakLogo)
  self.gfText = img(intro.gamefreakText)
  self.bigStar = img(intro.bigStar)
  self.smallStar = img(intro.fallingStar)
  self.smallStarBlink = img(intro.fallingStarBlink)
  self.gengarFrames, self.nidoFrames = {}, {}
  for i = 1, 3 do
    self.gengarFrames[i] = img(intro.gengar and intro.gengar["frame" .. i])
    self.nidoFrames[i] = img(intro.nidorino and intro.nidorino["frame" .. i])
  end

  -- fight state (PlayIntroScene entry, intro.asm:30-39): Gengar BG pose at
  -- tile (13,7) = screen (104,56); Nidorino OAM base (0,80) = screen
  -- (-8,72) after the OAM +8 offsets
  self.gengarX, self.gengarY = 104, 56
  self.nidoX, self.nidoY = -8, 72
  self.gengarPose, self.nidoFrame = 1, 1
  self.opIndex, self.opTimer = 1, 0
  self.fade = 0
  return self
end

function IntroMovie:finish()
  if self.finished then return end
  self.finished = true
  pcall(Music.stop)
  self.game.stack:pop()
  if self.onDone then self.onDone() end
end

function IntroMovie:startPhase(phase)
  self.phase = phase
  self.timer = 0
  if phase == 3 then
    -- intro.asm:333-338
    local data = self.game.data
    local songs = data.audio and data.audio.songs
    local song = self.introCfg.music or "Music_IntroBattle"
    if songs and songs[song] then
      pcall(Music.play, data, song, false)
    end
  end
end

-- one frame of the fight script (see FIGHT_SCRIPT)
function IntroMovie:fightStep()
  while true do
    local op = FIGHT_SCRIPT[self.opIndex]
    if not op then
      self:finish()
      return
    end
    if op.sfx then
      Sound.play(self.game.data, op.sfx)
    elseif op.pose then
      self.gengarPose = op.pose
    elseif op.frame then
      self.nidoFrame = op.frame
    elseif op.move then
      -- 2px per 2 frames (IntroMoveMon: CheckForUserInterruption c=2)
      if self.opTimer % 2 == 0 then
        if op.move == "scrollIn" then
          self.gengarX = self.gengarX - 2
          self.nidoX = self.nidoX + 2
        else
          self.gengarX = self.gengarX + (op.dx > 0 and 2 or -2)
        end
      end
      self.opTimer = self.opTimer + 1
      if self.opTimer < (op.px or math.abs(op.dx)) then return end
    elseif op.anim then
      -- one {dy,dx} delta per 5 frames (AnimateIntroNidorino: DelayFrames 5)
      if self.opTimer % 5 == 0 then
        local d = ANIM[op.anim][self.opTimer / 5 + 1]
        self.nidoY = self.nidoY + d[1]
        self.nidoX = self.nidoX + d[2]
      end
      self.opTimer = self.opTimer + 1
      if self.opTimer < #ANIM[op.anim] * 5 then return end
    elseif op.wait then
      self.opTimer = self.opTimer + 1
      if self.opTimer < op.wait then return end
    elseif op.fade then
      self.opTimer = self.opTimer + 1
      self.fade = self.opTimer / op.fade
      if self.opTimer >= op.fade then self:finish() end
      return
    end
    self.opIndex = self.opIndex + 1
    self.opTimer = 0
  end
end

function IntroMovie:update(dt)
  if self.skipAll then
    self:finish()
    return
  end
  local input = self.game.input
  if input:wasPressed("a") or input:wasPressed("b")
     or input:wasPressed("start") then
    self:finish()
    return
  end
  self.timer = self.timer + 1
  if self.phase == 1 then
    if self.timer >= COPYRIGHT_FRAMES then self:startPhase(2) end
  elseif self.phase == 2 then
    if self.timer == STAR_START then
      Sound.play(self.game.data, "Shooting_Star")  -- splash.asm:29-30
    end
    if self.timer >= SPLASH_FRAMES then self:startPhase(3) end
  else
    self:fightStep()
  end
end

-- the letterbox bars: 4 black tile rows top and bottom
-- (IntroDrawBlackBars, intro.asm:343-357); drawn AFTER the sprites since
-- both Nidorino and the small stars carry OAM_PRIO (intro.asm:195,
-- splash.asm:149) so the bars cover them.
local function drawBars()
  love.graphics.setColor(0, 0, 0, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 32)
  love.graphics.rectangle("fill", 0, 112, 160, 32)
  love.graphics.setColor(1, 1, 1, 1)
end

function IntroMovie:drawSplash()
  local t = self.timer
  if t >= STAR_START then
    -- logo + GAME FREAK letters appear with the star OAM
    -- (LoadShootingStarGraphics, splash.asm:18-25); the logo palette
    -- rotates during the 3-flash loop (splash.asm:72-82)
    local flashing = t >= FLASH_START and t < FLASH_START + FLASH_FRAMES
    local dim = flashing and math.floor((t - FLASH_START) / 5) % 2 == 0
    love.graphics.setColor(1, 1, 1, dim and 0.35 or 1)
    if self.logo then
      love.graphics.draw(self.logo, LOGO_X, LOGO_Y)
    end
    -- custom studio name (replaces the GAME FREAK splash text)
    love.graphics.setColor(0, 0, 0, dim and 0.35 or 1)
    local card = self.studio.card or "bois club games"
    Font.draw(card, (160 - #card * 8) / 2, TEXT_Y)
    love.graphics.setColor(1, 1, 1, 1)
  end
  if t >= STAR_START and t < FLASH_START then
    -- big star: from OAM (160,0) moving +4Y/-4X per frame
    -- (GameFreakShootingStarOAMData + .bigStarLoop, splash.asm:32-60)
    local n = t - STAR_START + 1
    local sx, sy = 152 - 4 * n, -16 + 4 * n
    if self.bigStar then
      love.graphics.draw(self.bigStar, sx, sy)
    else
      love.graphics.setColor(0, 0, 0, 1)
      love.graphics.rectangle("fill", sx + 6, sy + 6, 4, 4)
      love.graphics.setColor(1, 1, 1, 1)
    end
  end
  if t >= WAVES_START then
    -- small stars: wave w spawns at y=88 every 24 frames, everything falls
    -- +1px per 3-frame substep until the wave loop ends; the lower star in
    -- the tile blinks every substep (splash.asm:97-146, 186-209)
    local substep = math.floor((math.min(t, WAVES_END) - WAVES_START) / 3)
    local blink = substep % 2 == 0
    for w, xs in ipairs(STAR_WAVES) do
      local spawn = (w - 1) * 8  -- in substeps
      if substep >= spawn then
        local y = 88 + (substep - spawn)
        if y < 144 then
          local img = blink and self.smallStar
                      or (self.smallStarBlink or self.smallStar)
          for _, x in ipairs(xs) do
            if img then
              love.graphics.draw(img, x, y)
            else
              love.graphics.setColor(0, 0, 0, 1)
              love.graphics.rectangle("fill", x + 3, y + 1, 2, 2)
              love.graphics.setColor(1, 1, 1, 1)
            end
          end
        end
      end
    end
  end
  drawBars()
end

function IntroMovie:drawFight()
  -- Gengar: a 56x56 BG-tile pose recomposed from gengar_N.tilemap, moved
  -- by scrolling SCX (intro.asm:32-33, 235-269)
    -- Nidorino: 6x6 OAM sprite, one of the three red_nidorino poses
  local nido = self.nidoFrames[self.nidoFrame]
  if nido then
    love.graphics.draw(nido, self.nidoX, self.nidoY)
  end
  local gengar = self.gengarFrames[self.gengarPose]
  if gengar then
    love.graphics.draw(gengar, self.gengarX, self.gengarY)
  end

  if not gengar and not nido then
    love.graphics.setColor(0, 0, 0, 1)
    Font.draw("GENGAR VS NIDORINO", (160 - 18 * 8) / 2, 64)
    love.graphics.setColor(1, 1, 1, 1)
  end
  drawBars()
  if self.fade > 0 then
    love.graphics.setColor(1, 1, 1, math.min(1, self.fade))
    love.graphics.rectangle("fill", 0, 0, 160, 144)
    love.graphics.setColor(1, 1, 1, 1)
  end
end

function IntroMovie:draw()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 144)
  if self.phase == 1 then
    -- custom boot card (replaces the Nintendo / GAME FREAK copyright
    -- card; no (c) glyph in the charmap, keep it ASCII-safe)
    love.graphics.setColor(0, 0, 0, 1)
    local credit = self.studio.credit or "bois club"
    Font.draw("2026", (160 - 4 * 8) / 2, 48)
    Font.draw(credit, (160 - #credit * 8) / 2, 64)
    Font.draw("bryanthaboi", (160 - 11 * 8) / 2, 80)
  elseif self.phase == 2 then
    self:drawSplash()
  else
    self:drawFight()
  end
  love.graphics.setColor(1, 1, 1, 1)
end

return IntroMovie
