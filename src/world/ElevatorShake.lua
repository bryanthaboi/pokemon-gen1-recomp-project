-- ShakeElevator (pokered engine/overworld/elevator.asm), run after
-- DisplayElevatorFloorMenu picks a floor (the elevator map script fires
-- it via BIT_CUR_MAP_USED_ELEVATOR):
--
--   * lead-in: ShakeElevator's two ShakeElevatorRedrawRow calls (each
--     ends in Delay3) plus its own Delay3 are 9 frames; the SilphCo /
--     RocketHideout ...ShakeScripts prefix one more Delay3 (12 total)
--     while Celadon's farjps straight in (9).  The row redraws
--     themselves are a VRAM patch with no port equivalent -- only their
--     delays are kept.
--   * SFX_STOP_ALL_MUSIC: the map theme cuts out for the ride.
--   * 100 loop iterations, 2 frames each (`ld b, 100` / `ld c, 2` +
--     DelayFrames): `e ^= $fe` flips e between $01 and $ff, so
--     hSCY = rest + e alternates -1 / +1 around the resting scroll
--     (first offset -1), and SFX_COLLISION plays every iteration.
--   * hSCY restored, SFX_STOP_ALL_MUSIC again, then SFX_SAFARI_ZONE_PA
--     plays and .musicLoop busy-waits on wChannelSoundIDs+CHAN5 until
--     it ends.
--   * UpdateSprites + PlayDefaultMusic: the map theme restarts.
--
-- SCY scrolls the BG layer only -- OAM sprites stay put -- so this
-- state drives ow.bgShakeY, which OverworldState:drawWorld adds to the
-- tile layers and not to the sprites.  While it sits on the stack the
-- overworld below neither updates nor takes input, like the original's
-- blocking loop.

local Sound = require("src.core.Sound")

local ElevatorShake = {}
ElevatorShake.__index = ElevatorShake

local CYCLES = 100        -- ld b, 100
local FRAMES_PER_CYCLE = 2 -- ld c, 2 / call DelayFrames

-- opts.preFrames: lead-in delay frames (12 Silph/Rocket, 9 Celadon);
-- opts.onDone: called once the ride is over (the floor warp)
function ElevatorShake.new(game, ow, opts)
  opts = opts or {}
  return setmetatable({
    game = game,
    ow = ow,
    preFrames = opts.preFrames or 12,
    onDone = opts.onDone,
    phase = "pre",
    frames = 0,
    offset = 1, -- ld e, $1; the first `xor $fe` flips it to -1
  }, ElevatorShake)
end

function ElevatorShake:update()
  if self.phase == "pre" then
    if self.frames < self.preFrames then
      self.frames = self.frames + 1
      return
    end
    -- SFX_STOP_ALL_MUSIC: the theme stops just before the first scroll
    -- write, in the same frame slice
    require("src.core.Music").stop()
    self.phase = "shake"
    self.frames = 0
  end
  if self.phase == "shake" then
    if self.frames % FRAMES_PER_CYCLE == 0 then
      -- one .shakeLoop iteration: flip the offset, write the scroll,
      -- retrigger SFX_COLLISION
      self.offset = -self.offset
      self.ow.bgShakeY = self.offset
      Sound.play(self.game.data, "Collision")
    end
    self.frames = self.frames + 1
    if self.frames >= CYCLES * FRAMES_PER_CYCLE then
      -- ld a, d / ldh [hSCY], a: back to the resting scroll, then the
      -- arrival chime
      self.ow.bgShakeY = 0
      if Sound.stop then Sound.stop("Collision") end -- SFX_STOP_ALL_MUSIC
      Sound.play(self.game.data, "Safari_Zone_PA")
      self.phase = "pa"
    end
    return
  end
  -- .musicLoop: hold until SFX_SAFARI_ZONE_PA finishes (headless the
  -- sound never starts, so this resolves on the next frame)
  if Sound.isPlaying and Sound.isPlaying("Safari_Zone_PA") then return end
  require("src.core.Music").restoreMap(self.game.data) -- PlayDefaultMusic
  self.game.stack:pop()
  if self.onDone then self.onDone() end
end

-- safety: never leave a scroll offset behind if popped early
-- (e.g. Game:returnToTitle popping the whole stack)
function ElevatorShake:exit()
  if self.ow then self.ow.bgShakeY = 0 end
end

return ElevatorShake
