-- Plays back the original battle move animations (beams, blobs, rings...)
-- from data/generated/battle_anims.lua, reimplementing the subanimation
-- player in pokered's engine/battle/animations.asm:
--
--   PlayAnimation (:164)    walks a move's battle_anim rows: subanimation
--                           rows (with a tileset + per-frame-block delay) and
--                           2-byte special-effect rows (SE_*).
--   LoadSubanimation (:270) resolves the subanimation type into a transform:
--                           on the PLAYER's turn every type but ENEMY plays
--                           untransformed and ENEMY plays HFLIP'd; on the
--                           ENEMY's turn the type applies as-is and ENEMY
--                           plays untransformed (GetSubanimationTransform1/2,
--                           :333/:346).  REVERSE plays the frame-block list
--                           back to front, untransformed.
--   PlaySubanimation (:580) draws each frame block at its base coordinate,
--                           writing OAM entries from a cursor that resets to
--                           slot 0 at the start of every subanimation row.
--   DrawFrameBlock (:3)     per-tile transforms (8-bit math, OAM space):
--                             HVFLIP:    y' = 136-(base+dy), x' = 168-(base+dx),
--                                        toggles both flip bits (flags with
--                                        PRIO/PAL bits become no-flip)
--                             HFLIP:     y' = base+dy+40, x' = 168-(base+dx),
--                                        toggles the x-flip bit
--                             COORDFLIP: y' = (136-base)+dy, x' = (168-base)+dx
--                           then applies the frame-block mode:
--                             0/1: show for `delay` frames, then clear all
--                                  sprites (one extra frame; GROWL skips the
--                                  clear, :145) and restart at OAM slot 0
--                             2:   accumulate; no delay, keep the cursor moving
--                             3:   show for `delay` frames, keep sprites and
--                                  keep the cursor moving (persistent trails)
--                             4:   show for `delay` frames, keep sprites but
--                                  rewind the cursor (next block overwrites)
--
-- Special-effect rows are timed here (each SE_* gets the frame count its
-- routine really blocks for -- see SE_FRAMES) and exposed through
-- :pollEffects() so the caller can route them into the screen fx layer
-- (palette fades, mon-pic slides, screen shakes; BattleState implements
-- the visuals).  The sprite-emitter effects (AnimationSpiralBallsInward,
-- AnimationShootBallsUpward/ShootManyBallsUpward,
-- AnimationWaterDropletsEverywhere, AnimationLeavesFalling/PetalsFalling)
-- ARE executed here: their OAM trajectories are compiled into sprite
-- steps at start() from the original routines' math.
--
-- Per-animation-id frame-block effects (DoSpecialEffectByAnimationId,
-- data/battle_anims/special_effects.asm) are also compiled in: the
-- screen-flash pulses of Mega Punch/Blizzard/Thunderbolt/Explosion...,
-- Rock Slide's 1px rumble, and Explosion's user-pic hide, each timed at
-- the wSubAnimCounter values the asm checks.
--
-- Events carry the row sounds too ({ sound = <move id> }): PlayAnimation
-- plays each row's MoveSoundTable entry (with its pitch/tempo modifiers)
-- as the row starts, via GetMoveSound.
--
-- Usage (one :update() per 60fps frame):
--   local player = AnimPlayer.new(require("data.generated.battle_anims"))
--   player:start("THUNDERBOLT", true)
--   ... player:update(); player:draw(); player:pollEffects() ...
--   until player:isDone()
--
-- start() takes an optional opts table: { shakes = n } replays each
-- subanimation row n times, opening every pass with an SFX_TINK event
-- and a 40-frame pause -- DoBallShakeSpecialEffects (:739), which rewinds
-- the ball-shake subanimation wNumShakes times.  { ball = "<item id>" }
-- marks a ball-toss row with the thrown ball (wCurItem): a MASTER_BALL
-- or ULTRA_BALL toss flickers the OBJ palette every frame block --
-- DoBallTossSpecialEffects (:685) XORs rOBP0 with %00111100.

local Logger = require("src.core.Logger")

local AnimPlayer = {}
AnimPlayer.__index = AnimPlayer

local SE_PAUSE_FRAMES = 8          -- fallback pacing for unknown SE rows

-- Frames each special-effect routine blocks the animation for
-- (engine/battle/animations.asm; delays counted from the routines'
-- DelayFrames calls).  0 = a bare register write (palette sets).
local SE_FRAMES = {
  SE_DARK_SCREEN_FLASH = 4,        -- AnimationFlashScreen: 2f inverted + 2f white
  SE_FLASH_SCREEN_LONG = 48,       -- 12 palettes x (2f + 1f + 1f) over 3 cycles
  SE_DARK_SCREEN_PALETTE = 0,      -- SetAnimationBGPalette writes
  SE_LIGHT_SCREEN_PALETTE = 0,
  SE_DARKEN_MON_PALETTE = 0,
  SE_RESET_SCREEN_PALETTE = 0,
  SE_SHAKE_SCREEN = 72,            -- PredefShakeScreenHorizontally b=8: sum 9f
  SE_SHAKE_ENEMY_HUD = 44,         -- 8 x (2f + 2f) SCX shake + setup Delay3s
  SE_DELAY_ANIMATION_10 = 10,
  SE_SLIDE_MON_OFF = 24,           -- 8 tile steps x 3f (wSlideMonDelay)
  SE_SLIDE_ENEMY_MON_OFF = 24,     -- same routine, turn flipped
  SE_SLIDE_MON_HALF_OFF = 19,      -- 4 tile steps x 4f + Delay3
  SE_SLIDE_MON_UP = 14,            -- 7 row shifts x 2f (cyclic wrap)
  SE_SLIDE_MON_DOWN = 21,          -- 7 rows x Delay3
  SE_SLIDE_MON_DOWN_AND_HIDE = 19, -- 2 x 8f + Delay3
  SE_MOVE_MON_HORIZONTALLY = 3,
  SE_RESET_MON_POSITION = 3,
  SE_SHAKE_BACK_AND_FORTH = 96,    -- 16 loops x 2 redraws x Delay3
  SE_BOUNCE_UP_AND_DOWN = 108,     -- 5 x AnimationSlideMonDown + Delay3
  SE_SQUISH_MON_PIC = 26,          -- 4 loops x 2 x Delay3 + 2f
  SE_MINIMIZE_MON = 6,
  SE_SHOW_MON_PIC = 3, SE_SHOW_ENEMY_MON_PIC = 3,
  SE_HIDE_MON_PIC = 3, SE_HIDE_ENEMY_MON_PIC = 3,
  SE_BLINK_MON = 60, SE_BLINK_ENEMY_MON = 60, -- 6 x (5f off + 5f on)
  SE_FLASH_MON_PIC = 4, SE_FLASH_ENEMY_MON_PIC = 4,
  SE_TRANSFORM_MON = 4,
  SE_SUBSTITUTE_MON = 3,
  SE_WAVY_SCREEN = 255,            -- AnimationWavyScreen: ld c, $ff frames
}

-- data/battle_anims/special_effects.asm AnimationIdSpecialEffects:
-- per-frame-block effects keyed on the animation id.  "flash" =
-- AnimationFlashScreen after every frame block.
local ANIM_ID_FX = {
  MEGA_PUNCH = "flash", GUILLOTINE = "flash", MEGA_KICK = "flash",
  HEADBUTT = "flash", DISABLE = "flash", BUBBLEBEAM = "flash",
  REFLECT = "flash", SPORE = "flash",
  BLIZZARD = "blizzard",           -- flash at counters 13/9/5/1
  HYPER_BEAM = "every4",           -- flash when counter % 4 == 0
  THUNDERBOLT = "every8",          -- flash when counter % 8 == 0
  SELFDESTRUCT = "explode", EXPLOSION = "explode",
  ROCK_SLIDE = "rockslide",        -- 1px shakes at 8-11, flash at 1
}

-- Anim tiles load at vSprites tile $31 (LoadMoveAnimationTiles), so the
-- raw VRAM tile ids the emitter routines poke into OAM are sheet tile
-- (id - $31).
local BALL_TILE = 0x7a - 0x31      -- AnimationSpiralBallsInward/ShootBalls
local DROPLET_TILE = 0x71 - 0x31   -- AnimationWaterDropletsEverywhere (ts 0)
local LEAF_TILE = 0x37 - 0x31      -- AnimationLeavesFalling (ts 1)
local PETAL_TILE = 0x71 - 0x31     -- AnimationPetalsFalling (ts 1)

function AnimPlayer.new(data)
  return setmetatable({
    data = data,
    images = {},   -- tileset id -> Image | false (load failed)
    quads = {},    -- tileset id -> { [tile] = Quad }
    warned = {},
    steps = {},    -- { dur = frames, sprites = { {x,y,tile,ts,xf,yf}... } }
    events = {},   -- { effect = "SE_*", frame = n } in firing order
    stepIndex = 1,
    stepLeft = 0,
    elapsed = 0,
    eventCursor = 1,
  }, AnimPlayer)
end

function AnimPlayer:warnOnce(key, fmt, ...)
  if not self.warned[key] then
    self.warned[key] = true
    Logger.warn(fmt, ...)
  end
end

-- engine/battle/animations.asm GetSubanimationTransform1/2
local function resolveTransform(subType, attackerIsPlayer)
  if subType == "ENEMY" then
    return attackerIsPlayer and "HFLIP" or "NORMAL"
  end
  return attackerIsPlayer and "NORMAL" or subType
end

local function wrap(v) return v % 256 end

-- ------------------------------------------------------------------
-- Sprite-emitter special effects, compiled to per-frame sprite steps.
-- Coordinates are OAM space (screen x+8 / y+16) like the frame blocks;
-- obp marks which hardware OBJ palette the routine ran under ("e4" =
-- ambient rOBP0, "f0" = wAnimPalette on SGB, "obp1" = rOBP1 $6c).
-- ------------------------------------------------------------------

-- AnimationSpiralBallsInward (:1480): 3 ball sprites walk the 21-entry
-- coordinate spiral, one entry per 5 frames, player-anchored at (0,0)
-- and enemy-anchored at (y-40, x+80); ends with AnimationFlashScreen.
local SPIRAL_COORDS = { -- y, x pairs (SpiralBallAnimationCoordinates)
  {0x38,0x28},{0x40,0x18},{0x50,0x10},{0x60,0x18},{0x68,0x28},{0x60,0x38},
  {0x50,0x40},{0x40,0x38},{0x40,0x28},{0x46,0x1E},{0x50,0x18},{0x5B,0x1E},
  {0x60,0x28},{0x5B,0x32},{0x50,0x38},{0x46,0x32},{0x48,0x28},{0x50,0x20},
  {0x58,0x28},{0x50,0x30},{0x50,0x28},
}
local function spiralBallSteps(attackerIsPlayer)
  local by, bx = 0, 0
  if not attackerIsPlayer then by, bx = -40, 80 end
  local steps = {}
  for k = 1, #SPIRAL_COORDS - 2 do -- the step aborts when a ball reads the -1
    local sprites = {}
    for i = 0, 2 do
      local c = SPIRAL_COORDS[k + i]
      sprites[#sprites + 1] = { x = wrap(bx + c[2]), y = wrap(by + c[1]),
                                tile = BALL_TILE, ts = 0, obp = "e4" }
    end
    steps[#steps + 1] = { dur = 5, sprites = sprites }
  end
  return steps
end

-- _AnimationShootBallsUpward (:1638): a pillar of `n` balls at x, from
-- baseY+8*i, each moving up 4px per frame and vanishing at baseY+8.
local function shootPillarSteps(steps, n, x, baseY)
  local ys = {}
  for i = 1, n do ys[i] = baseY + 8 * i end
  local function snapshot()
    local sprites = {}
    for i = 1, n do
      if ys[i] then
        sprites[#sprites + 1] = { x = x, y = wrap(ys[i]), tile = BALL_TILE,
                                  ts = 0, obp = "e4" }
      end
    end
    return sprites
  end
  steps[#steps + 1] = { dur = 1, sprites = snapshot() } -- init DelayFrame
  local alive = n
  while alive > 0 do
    for i = 1, n do
      if ys[i] then
        if ys[i] == baseY + 8 then
          ys[i] = nil
          alive = alive - 1
        else
          ys[i] = ys[i] - 4
        end
      end
    end
    steps[#steps + 1] = { dur = 1, sprites = snapshot() }
  end
end

-- AnimationShootBallsUpward (:1617): one 5-ball pillar; player at
-- (x=5*8, baseY=6*8), enemy at (x=16*8, baseY=0).
local function shootBallsSteps(attackerIsPlayer)
  local steps = {}
  if attackerIsPlayer then
    shootPillarSteps(steps, 5, 5 * 8, 6 * 8)
  else
    shootPillarSteps(steps, 5, 16 * 8, 0)
  end
  return steps
end

-- AnimationShootManyBallsUpward (:1686): six sequential 4-ball pillars.
local function shootManyBallsSteps(attackerIsPlayer)
  local xs = attackerIsPlayer
    and { 0x10, 0x40, 0x28, 0x18, 0x38, 0x30 }
    or  { 0x60, 0x90, 0x78, 0x68, 0x88, 0x80 }
  local baseY = attackerIsPlayer and 0x50 or 0x28
  local steps = {}
  for _, x in ipairs(xs) do
    shootPillarSteps(steps, 4, x, baseY)
  end
  return steps
end

-- AnimationWaterDropletsEverywhere (:1114): 64 one-frame passes of
-- droplet rows; the 8-bit x cursor persists across passes, which is
-- what makes the field scroll.
local function waterDropletSteps()
  local steps = {}
  local baseX = 0xF0 -- ld a, -16
  for _ = 1, 32 do
    for _, startY in ipairs({ 16, 24 }) do
      local sprites = {}
      local y = startY
      while true do
        baseX = wrap(baseX + 27)
        sprites[#sprites + 1] = { x = baseX, y = y, tile = DROPLET_TILE,
                                  ts = 0, obp = "e4" }
        if baseX >= 144 then
          baseX = wrap(baseX - 168)
          y = y + 16
          if y >= 112 then break end
        end
      end
      steps[#steps + 1] = { dur = 1, sprites = sprites }
    end
  end
  return steps
end

-- AnimationFallingObjects (:2335): n objects fall 2px per 3-frame tick,
-- swaying via the delta-X table (index advances each tick, direction
-- flips past index 8), until object 1 reaches y=104.
local FALLING_X = { 0x38,0x40,0x50,0x60,0x70,0x88,0x90,0x56,0x67,0x4A,
                    0x77,0x84,0x98,0x32,0x22,0x5C,0x6C,0x7D,0x8E,0x99 }
local FALLING_M = { 0x00,0x84,0x06,0x81,0x02,0x88,0x01,0x83,0x05,0x89,
                    0x09,0x80,0x07,0x87,0x03,0x82,0x04,0x85,0x08,0x86 }
local FALLING_DX = { [0]=0, 1, 3, 5, 7, 9, 11, 13, 15 }
local function fallingObjectSteps(n, tile, obp)
  local objs = {}
  for i = 1, n do
    objs[i] = { y = (i == 1) and 0 or 8 * i, x = FALLING_X[i],
                m = FALLING_M[i], xf = false }
  end
  local steps = {}
  while objs[1].y ~= 104 do
    local sprites = {}
    for i = 1, n do
      local o = objs[i]
      -- FallingObjects_UpdateMovementByte runs before the OAM update
      local left = o.m >= 0x80
      local idx = (o.m % 0x80) + 1
      if idx == 9 then
        left = not left
        idx = 0
      end
      o.m = (left and 0x80 or 0) + idx
      o.y = o.y + 2
      if o.y >= 112 then o.y = 160 end -- parked off-screen
      local dx = FALLING_DX[idx]
      o.x = left and wrap(o.x - dx) or wrap(o.x + dx)
      o.xf = left
      sprites[#sprites + 1] = { x = o.x, y = o.y, tile = tile, ts = 1,
                                xf = o.xf, obp = obp }
    end
    steps[#steps + 1] = { dur = 3, sprites = sprites }
    if #steps > 120 then break end -- safety; the asm exits at 52 ticks
  end
  return steps
end

-- effect id -> compiled sprite steps
local EMITTERS = {
  SE_SPIRAL_BALLS_INWARD = function(isPlayer) return spiralBallSteps(isPlayer), "flash" end,
  SE_SHOOT_BALLS_UPWARD = function(isPlayer) return shootBallsSteps(isPlayer) end,
  SE_SHOOT_MANY_BALLS_UPWARD = function(isPlayer) return shootManyBallsSteps(isPlayer) end,
  SE_WATER_DROPLETS_EVERYWHERE = function() return waterDropletSteps() end,
  -- AnimationLeavesFalling runs under wAnimPalette ($f0 on SGB);
  -- petals keep the ambient $e4
  SE_LEAVES_FALLING = function() return fallingObjectSteps(3, LEAF_TILE, "f0") end,
  SE_PETALS_FALLING = function() return fallingObjectSteps(20, PETAL_TILE, "e4") end,
}

-- One OAM entry for tile `t` of a frame block anchored at base coord `bc`,
-- with the subanimation transform applied (DrawFrameBlock).
local function placeTile(transform, bc, t, tileset)
  local x, y, xf, yf
  if transform == "HVFLIP" then
    y = wrap(136 - wrap(bc.y + t.y))
    x = wrap(168 - wrap(bc.x + t.x))
    -- the engine compares the whole flags byte: plain/xflip/yflip toggle
    -- both bits, any other combination (both, PRIO, PAL1) becomes no-flip
    local plain = not (t.prio or t.pal1)
    if plain and not t.xflip and not t.yflip then
      xf, yf = true, true
    elseif plain and t.xflip and not t.yflip then
      xf, yf = false, true
    elseif plain and t.yflip and not t.xflip then
      xf, yf = true, false
    else
      xf, yf = false, false
    end
  elseif transform == "HFLIP" then
    y = wrap(wrap(bc.y + t.y) + 40)
    x = wrap(168 - wrap(bc.x + t.x))
    xf, yf = not t.xflip, t.yflip
  elseif transform == "COORDFLIP" then
    y = wrap(wrap(136 - bc.y) + t.y)
    x = wrap(wrap(168 - bc.x) + t.x)
    xf, yf = t.xflip, t.yflip
  else -- NORMAL (and REVERSE, which only reorders the block list)
    y = wrap(bc.y + t.y)
    x = wrap(bc.x + t.x)
    xf, yf = t.xflip, t.yflip
  end
  -- OAM_PAL1 tiles render through rOBP1 ($6c); the rest use rOBP0
  -- (= wAnimPalette during subanimations: $f0 on SGB, $e4 on DMG)
  return { x = x, y = y, tile = t.tile, ts = tileset, xf = xf, yf = yf,
           obp = t.pal1 and "obp1" or "f0" }
end

-- Compile the move's battle_anim rows into a list of timed steps by
-- simulating the OAM buffer, so :update()/:draw() are trivial.
function AnimPlayer:start(moveId, attackerIsPlayer, opts)
  self.steps, self.events = {}, {}
  self.stepIndex, self.stepLeft = 1, 0
  self.elapsed, self.eventCursor = 0, 1

  local anim = self.data and self.data.moveAnims and self.data.moveAnims[moveId]
  if not anim then
    self:warnOnce("move:" .. tostring(moveId),
                  "AnimPlayer: no animation data for move %s", tostring(moveId))
    return
  end

  local steps, events = self.steps, self.events
  local oam, oamMax = {}, 0
  local frame = 0
  -- DoGrowlSpecialEffects (:928): after every frame block it copies the
  -- note sprite's 4 OAM entries to a second, untouched slot; since GROWL
  -- also skips AnimationCleanOAM between blocks (the mode 0/1 branch
  -- below), that copy from the PREVIOUS block is still on screen -- at
  -- its old base coordinate -- while the current block draws, so two
  -- notes are visible each frame, one trailing a step behind the other
  local growlNoteTrail

  local function emit(dur, spritesOverride)
    if dur < 1 then dur = 1 end
    local sprites = spritesOverride
    if not sprites then
      sprites = {}
      for i = 1, oamMax do
        local s = oam[i]
        if s then sprites[#sprites + 1] = s end
      end
    end
    steps[#steps + 1] = { dur = dur, sprites = sprites }
    frame = frame + dur
  end

  -- AnimationFlashScreen (4 blocking frames), reused by the per-block
  -- animation-id effects; same visual as an SE_DARK_SCREEN_FLASH row
  local function flashScreen()
    events[#events + 1] = { effect = "SE_DARK_SCREEN_FLASH", frame = frame }
    emit(4)
  end

  local idFx = ANIM_ID_FX[moveId]

  -- DoBallTossSpecialEffects (:685): while a Master or Ultra ball is
  -- tossed (wCurItem <= ULTRA_BALL), the per-block special effect XORs
  -- rOBP0 with %00111100, complementing colors 1 and 2 -- the ball
  -- flickers between the $f0 and $cc shade maps block to block.  The
  -- effect runs AFTER each block displays, so block 1 shows normal.
  -- PlayAnimation pushes rOBP0 around every subanimation row (:246-251
  -- / :259-262), so the ambient palette returns when the toss ends.
  -- opts.ballFlicker carries the ball record's flicker flag; the id
  -- check covers callers that only pass the ball item.
  local wantsFlicker
  if opts and opts.ballFlicker ~= nil then
    wantsFlicker = opts.ballFlicker
  else
    wantsFlicker = opts
      and (opts.ball == "MASTER_BALL" or opts.ball == "ULTRA_BALL")
  end
  local ballFlicker = wantsFlicker
    and (moveId == "TOSS_ANIM" or moveId == "GREATTOSS_ANIM"
         or moveId == "ULTRATOSS_ANIM")
  local obp0Flip = false

  for _, row in ipairs(anim.seq) do
    -- PlayAnimation/PlaySubanimation: each row's sound byte is a move id
    -- whose MoveSoundTable entry (sfx + pitch/tempo modifiers) plays as
    -- the row starts (GetMoveSound)
    if row.sound then
      events[#events + 1] = { sound = row.sound, frame = frame }
    end
    if row.effect then
      local emitter = EMITTERS[row.effect]
      if emitter then
        -- the emitter routines write OAM from slot 0 and clean up after
        oam, oamMax = {}, 0
        local emSteps, tailFx = emitter(attackerIsPlayer)
        events[#events + 1] = { effect = row.effect, frame = frame }
        for _, st in ipairs(emSteps) do
          emit(st.dur, st.sprites)
        end
        emit(1, {}) -- AnimationCleanOAM / ClearSprites
        if tailFx == "flash" then flashScreen() end
      else
        local dur = SE_FRAMES[row.effect]
        events[#events + 1] = { effect = row.effect, frame = frame,
                                dur = dur or SE_PAUSE_FRAMES }
        if dur == nil then dur = SE_PAUSE_FRAMES end
        if dur > 0 then emit(dur) end
      end
    else
      local sub = self.data.subanims and self.data.subanims[row.subanim]
      if not (sub and sub.blocks) then
        self:warnOnce("subanim:" .. tostring(row.subanim),
                      "AnimPlayer: %s references unknown subanimation %s",
                      tostring(moveId), tostring(row.subanim))
      else
        local transform = resolveTransform(sub.type, attackerIsPlayer)
        local first, last, dir = 1, #sub.blocks, 1
        if transform == "REVERSE" then first, last, dir = last, first, -1 end
        -- DoBallShakeSpecialEffects: each ball shake opens with SFX_TINK
        -- and a 40-frame pause, then rewinds the same subanimation; the
        -- mode-4 frame blocks persist, so the resting ball stays visible
        -- through the pauses between wobbles
        for _ = 1, (opts and opts.shakes) or 1 do
          if opts and opts.shakes then
            events[#events + 1] = { effect = "SFX_TINK", frame = frame }
            emit(40)
          end
          local dest = 1   -- PlaySubanimation resets the OAM cursor per row
          local nblocks = math.abs(last - first) + 1
          local played = 0
          for bi = first, last, dir do
            local entry = sub.blocks[bi]
            local fb = self.data.frameBlocks and self.data.frameBlocks[entry.block]
            local bc = self.data.baseCoords and self.data.baseCoords[entry.coord]
            if not (fb and bc) then
              self:warnOnce("block:" .. tostring(entry.block) .. ":" .. tostring(entry.coord),
                            "AnimPlayer: %s references missing frame block/coord",
                            tostring(moveId))
            else
              for j = 1, #fb do
                oam[dest + j - 1] = placeTile(transform, bc, fb[j], row.tileset)
              end
              if obp0Flip then
                -- rOBP0 is complemented right now: this block's rOBP0
                -- tiles show with colors 1/2 swapped ($f0 -> $cc)
                for j = 1, #fb do
                  local t = oam[dest + j - 1]
                  if t.obp == "f0" then t.obp = "f0x" end
                end
              end
              if dest + #fb - 1 > oamMax then oamMax = dest + #fb - 1 end
              local mode = entry.mode
              if mode == 2 then          -- accumulate, no frame shown yet
                dest = dest + #fb
              elseif mode == 3 then      -- show and persist
                emit(row.delay)
                dest = dest + #fb
              elseif mode == 4 then      -- show; next block overwrites
                emit(row.delay)
              else                       -- 0/1: show, then clean the OAM buffer
                if moveId == "GROWL" then
                  -- GROWL quirk: sprites persist (no clean), plus the
                  -- previous block's note copy draws alongside this one
                  local current = {}
                  for i = 1, oamMax do
                    if oam[i] then current[#current + 1] = oam[i] end
                  end
                  local shown = current
                  if growlNoteTrail then
                    shown = {}
                    for _, s in ipairs(current) do shown[#shown + 1] = s end
                    for _, s in ipairs(growlNoteTrail) do shown[#shown + 1] = s end
                  end
                  emit(row.delay, shown)
                  growlNoteTrail = current
                else
                  emit(row.delay + 1)    -- AnimationCleanOAM's extra frame
                  oam, oamMax = {}, 0
                end
                dest = 1
              end
              -- DoSpecialEffectByAnimationId runs after every frame
              -- block with wSubAnimCounter = blocks remaining
              played = played + 1
              if ballFlicker then obp0Flip = not obp0Flip end
              if idFx then
                local counter = nblocks - played + 1
                if idFx == "flash"
                   or (idFx == "every4" and counter % 4 == 0)
                   or (idFx == "every8" and counter % 8 == 0)
                   or (idFx == "blizzard" and (counter == 13 or counter == 9
                       or counter == 5 or counter == 1)) then
                  flashScreen()
                elseif idFx == "explode" then
                  if counter % 4 == 0 then flashScreen() end
                  if counter == 1 then
                    -- DoExplodeSpecialEffects: the user's pic vanishes
                    events[#events + 1] = { effect = "SE_HIDE_ATTACKER_PIC",
                                            frame = frame }
                  end
                elseif idFx == "rockslide" then
                  if counter >= 8 and counter <= 11 then
                    -- 1px horizontal + vertical rumble (15 blocking frames)
                    events[#events + 1] = { effect = "SE_ROCK_SLIDE_SHAKE",
                                            frame = frame, dur = 15 }
                    emit(15)
                  elseif counter == 1 then
                    flashScreen()
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  local firstStep = steps[1]
  self.stepLeft = firstStep and firstStep.dur or 0
end

-- Advance one frame (call once per 60fps tick).
function AnimPlayer:update()
  if self:isDone() then return end
  self.elapsed = self.elapsed + 1
  self.stepLeft = self.stepLeft - 1
  while self.stepLeft <= 0 do
    self.stepIndex = self.stepIndex + 1
    local st = self.steps[self.stepIndex]
    if not st then break end
    self.stepLeft = st.dur
  end
end

function AnimPlayer:isDone()
  return self.steps[self.stepIndex] == nil
end

-- SE_* rows whose time has come since the last poll:
-- returns { { effect = "SE_...", frame = n }, ... } (possibly empty).
function AnimPlayer:pollEffects()
  local fired = {}
  local events = self.events
  while self.eventCursor <= #events
        and events[self.eventCursor].frame <= self.elapsed do
    fired[#fired + 1] = events[self.eventCursor]
    self.eventCursor = self.eventCursor + 1
  end
  return fired
end

function AnimPlayer:sheetImage(ts)
  local cached = self.images[ts]
  if cached ~= nil then
    return cached or nil
  end
  local sheet = self.data.tilesheets and self.data.tilesheets[ts]
  local ok, img = false, nil
  if sheet and love and love.graphics and love.graphics.newImage then
    ok, img = pcall(love.graphics.newImage, sheet.path)
  end
  if not (ok and img) then
    self:warnOnce("sheet:" .. tostring(ts),
                  "AnimPlayer: battle anim tilesheet %s unavailable",
                  tostring(sheet and sheet.path or ts))
    img = false
  end
  self.images[ts] = img or false
  return self.images[ts] or nil
end

function AnimPlayer:tileQuad(ts, tile)
  local sheet = self.data.tilesheets[ts]
  if not sheet or tile >= sheet.tiles then return nil end
  local perSheet = self.quads[ts]
  if not perSheet then
    perSheet = {}
    self.quads[ts] = perSheet
  end
  local q = perSheet[tile]
  if q == nil and love and love.graphics and love.graphics.newQuad then
    local cols = math.floor(sheet.width / 8)
    q = love.graphics.newQuad((tile % cols) * 8,
                              math.floor(tile / cols) * 8,
                              8, 8, sheet.width, sheet.height)
    perSheet[tile] = q
  end
  return q
end

-- Draw the current frame's tiles onto the 160x144 battle canvas.
-- colorFn (optional): function(sprite, px, py) -> {c1,c2,c3} SGB colors
-- (0-1 RGB triples) for the sprite's three opaque shades at screen
-- pixel (px, py), or nil to draw the raw DMG grays.  BattleState
-- supplies the SGB zone palette + OBJ palette mapping.
function AnimPlayer:draw(colorFn)
  local st = self.steps[self.stepIndex]
  if not st then return end
  self:drawSprites(st.sprites, colorFn)
end

-- The last compiled step's sprites, or nil.  After a capture the
-- SHAKE_ANIM chain ends on the resting closed ball (its mode-4 frame
-- blocks persist), which the GB leaves in OAM through the caught text;
-- BattleState keeps drawing it via drawSprites.
function AnimPlayer:finalSprites()
  local last = self.steps[#self.steps]
  return last and last.sprites or nil
end

-- two colorFn results (three 0-1 RGB triples) resolve the same palette?
local function sameColors(a, b)
  if a == b then return true end
  for i = 1, 3 do
    local p, q = a[i], b[i]
    if p[1] ~= q[1] or p[2] ~= q[2] or p[3] ~= q[3] then return false end
  end
  return true
end

-- Draw one compiled step's OAM sprites.  With colorFn, each sprite is
-- drawn through the PaletteFX shade-remap shader.  The SGB colorized
-- the finished DMG picture per 8x8 screen cell (the ATTR_BLK regions
-- know nothing of OAM), so a tile overlapping a palette boundary shows
-- each region's colors on the pixels inside it: colorFn is sampled
-- once per attribute cell the 8x8 tile touches (up to 4), and cells
-- that resolve to a different palette than the first are repainted
-- through a scissor clipped to the cell.
function AnimPlayer:drawSprites(sprites, colorFn)
  local g = love and love.graphics
  local shader
  if colorFn and g and g.setShader then
    shader = require("src.render.PaletteFX").shader()
  end
  local slices = shader and g.getScissor and g.intersectScissor
                 and g.setScissor
  for i = 1, #sprites do
    local s = sprites[i]
    -- hardware hides sprites at the OAM extremes (y=0/y>=160, x=0/x>=168);
    -- wrapped offsets rely on this to park tiles offscreen
    if s.x > 0 and s.x < 168 and s.y > 0 and s.y < 160 then
      local img = self:sheetImage(s.ts)
      local quad = img and self:tileQuad(s.ts, s.tile)
      if quad then
        local rx, ry = s.x - 8, s.y - 16 -- screen-space rect of the tile
        local function blit()
          g.draw(img, quad,
                 rx + (s.xf and 8 or 0),
                 ry + (s.yf and 8 or 0),
                 0,
                 s.xf and -1 or 1,
                 s.yf and -1 or 1)
        end
        -- the attribute cell holding the tile's top-left pixel
        local cx = math.floor(rx / 8) * 8
        local cy = math.floor(ry / 8) * 8
        local colors = shader and colorFn(s, cx, cy)
        if colors then
          g.setShader(shader)
          -- c0 is the transparent color-0 slot; send anything
          shader:send("c0", colors[1])
          shader:send("c1", colors[1])
          shader:send("c2", colors[2])
          shader:send("c3", colors[3])
        end
        blit()
        if colors and slices and (cx ~= rx or cy ~= ry) then
          -- unaligned: the tile spills into up to 3 more cells; repaint
          -- the ones whose zone palette differs (opaque overdraw -- GB
          -- tiles have binary alpha)
          local function slice(px, py)
            if px < 0 or py < 0 or px >= 160 or py >= 144 then
              return -- fully off-canvas
            end
            local cc = colorFn(s, px, py)
            if not cc or sameColors(cc, colors) then return end
            local s1, s2, s3, s4 = g.getScissor()
            g.intersectScissor(px, py, 8, 8)
            shader:send("c0", cc[1])
            shader:send("c1", cc[1])
            shader:send("c2", cc[2])
            shader:send("c3", cc[3])
            blit()
            if s1 then g.setScissor(s1, s2, s3, s4) else g.setScissor() end
          end
          local cx2 = math.floor((rx + 7) / 8) * 8
          local cy2 = math.floor((ry + 7) / 8) * 8
          if cx2 ~= cx then slice(cx2, cy) end
          if cy2 ~= cy then slice(cx, cy2) end
          if cx2 ~= cx and cy2 ~= cy then slice(cx2, cy2) end
        end
        if colors then
          g.setShader()
        end
      end
    end
  end
end

return AnimPlayer
