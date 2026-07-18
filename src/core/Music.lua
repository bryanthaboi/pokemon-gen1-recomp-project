-- Music playback supports compact ROM channel programs synthesized live by
-- ChipAudio and legacy pre-rendered WAV definitions. Songs with split WAVs
-- chain def.file into def.loopFile in Music.update().
-- Map themes switch on map change; battles override with the battle
-- theme and restore afterwards; riding the bike overrides outdoor map
-- themes with Music_BikeRiding until dismount.

local Logger = require("src.core.Logger")

local Music = {}

local VOLUME = 0.7

-- port additions driven by OptionsMenu / save.options: musicVol scales
-- VOLUME (0-7 level like the GB's NR50 master volume) and musicFilter
-- low-passes the song.  Each filter step keeps 40% of the previous
-- step's treble (highgain 0.4^level), so 2X/3X are the 1X filter
-- applied twice/three times over.
local volumeScale = 1
local FILTER_HIGHGAIN = { 0.4, 0.16, 0.064 }
local filterLevel = 0

local function applyVolume(src)
  if src then pcall(src.setVolume, src, VOLUME * volumeScale) end
end

-- Source:setFilter needs OpenAL EFX; the pcall degrades to unfiltered
-- audio where it's missing (and under the headless stub)
local function applyFilter(src)
  if not src then return end
  if filterLevel > 0 then
    pcall(src.setFilter, src, { type = "lowpass", volume = 1,
                                highgain = FILTER_HIGHGAIN[filterLevel] })
  else
    pcall(src.setFilter, src)
  end
end

local state = {
  enabled = true,
  current = nil,      -- song label
  source = nil,       -- currently playing source
  loopSource = nil,   -- pre-loaded loop body waiting for the intro to end
  mapSong = nil,      -- song to restore after a battle
  onBike = false,     -- bike theme overrides outdoor map themes
  surfing = false,    -- surf theme likewise (home/audio.asm MUSIC_SURFING)
  pendingRestore = nil,
  fanfare = nil,      -- fanfare SFX source; the song pauses while it plays
  fanfareResume = false, -- start/resume state.source when the fanfare ends
  fade = nil,         -- active volume-ramp fade-out (see Music.fadeOut)
}

-- Is a fanfare SFX (Sound.lua's FANFARES) still sounding?
local function fanfareActive()
  local src = state.fanfare
  if not src then return false end
  local ok, playing = pcall(src.isPlaying, src)
  if ok and playing then return true end
  state.fanfare = nil
  return false
end

-- Called by Sound.play when a fanfare starts: fanfares own the music
-- channels on the Game Boy, so the current song halts and resumes when
-- the jingle ends (see update()).
function Music.duckForFanfare(src)
  if not state.enabled or not src then return end
  state.fanfare = src
  if state.source then
    local ok, playing = pcall(state.source.isPlaying, state.source)
    if ok and playing then
      pcall(state.source.pause, state.source)
      state.fanfareResume = true
    end
  end
end

-- Overworld themes where the bike can be ridden (outdoor maps plus the
-- caves/dungeons where gen-1 allows cycling).  Indoor themes such as
-- Pokecenter/Gym/SilphCo never get replaced by the bike theme.
local OUTDOOR = {
  Music_PalletTown = true,
  Music_Cities1 = true,
  Music_Cities2 = true,
  Music_Celadon = true,
  Music_Cinnabar = true,
  Music_Vermilion = true,
  Music_Lavender = true,
  Music_Routes1 = true,
  Music_Routes2 = true,
  Music_Routes3 = true,
  Music_Routes4 = true,
  Music_IndigoPlateau = true,
  Music_SafariZone = true,
  Music_Dungeon1 = true,
  Music_Dungeon2 = true,
  Music_Dungeon3 = true,
}

local function songDef(data, song)
  return data and data.audio and data.audio.songs and data.audio.songs[song]
end

local function stopSource(src)
  if src then pcall(src.stop, src) end
end

local function newSource(file)
  local ok, src = pcall(love.audio.newSource, file, "stream")
  if ok and src then return src end
  Logger.warn("music: cannot load %s", tostring(file))
  return nil
end

function Music.play(data, song, loop)
  if not state.enabled or not song or song == state.current then return end
  if not love.audio then -- headless test stub
    state.enabled = false
    return
  end
  local def = songDef(data, song)
  local runtime = data and data.audio and data.audio.runtime
  if not def or (not runtime and not def.file) then return end
  stopSource(state.source)
  stopSource(state.loopSource)
  if runtime then require("src.core.ChipAudio").stopMusic() end
  state.source, state.loopSource, state.fade = nil, nil, nil
  local wantLoop = loop ~= false
  local src
  if runtime then
    local ok, generated = pcall(
      require("src.core.ChipAudio").playMusic, data, def, wantLoop)
    if ok then src = generated end
  else
    src = newSource(def.file)
  end
  if not src then
    state.enabled = false
    state.current = nil
    return
  end
  if not runtime and def.loopFile then
    -- intro file plays once, then update() chains to the loop body
    -- (for one-shot jingles the body plays once and doesn't repeat)
    pcall(src.setLooping, src, false)
    local loopSrc = newSource(def.loopFile)
    if loopSrc then
      pcall(loopSrc.setLooping, loopSrc, wantLoop)
      applyVolume(loopSrc)
      applyFilter(loopSrc)
      state.loopSource = loopSrc
    else
      pcall(src.setLooping, src, wantLoop) -- degrade: intro file only
    end
  else
    pcall(src.setLooping, src, wantLoop)
  end
  applyVolume(src)
  applyFilter(src)
  -- a fanfare owns the music channels: hold the new song until it ends
  -- (update() starts it, like the paused-song resume)
  if fanfareActive() then
    state.fanfareResume = true
  else
    pcall(src.play, src)
  end
  state.source = src
  state.current = song
end

function Music.stop()
  stopSource(state.source)
  stopSource(state.loopSource)
  require("src.core.ChipAudio").stopMusic()
  state.current, state.source, state.loopSource, state.fade = nil, nil, nil, nil
end

-- Ramp the current song's volume to silence, then stop it, mirroring the
-- Game Boy's audio fade-out (home/fade_audio.asm FadeOutAudio +
-- home/audio.asm's .fadeOut): rAUDVOL's master volume steps 7 -> 0 in
-- integer levels, one level every `control` frames, and the music stops
-- when it reaches 0.  `control` is the wAudioFadeOutControl value the ROM
-- writes (oak_speech.asm sets 10 at the shrink beat -> 7*10 = 70 frames
-- to silence).  Ticked once per frame from Music.update().
function Music.fadeOut(control)
  if not state.enabled then return end
  if not state.source then Music.stop() return end
  control = math.max(1, control or 10)
  state.fade = {
    control = control,
    counter = control,       -- frames until the next volume step
    level = 7,               -- current master-volume level (rAUDVOL nibble)
    from = VOLUME * volumeScale, -- level-7 (full) source volume
  }
end

-- the song a map should currently play, honoring the bike/surf overrides
local function effectiveMapSong(data, song)
  if state.onBike and song and OUTDOOR[song]
     and songDef(data, "Music_BikeRiding") then
    return "Music_BikeRiding"
  end
  if state.surfing and song and OUTDOOR[song]
     and songDef(data, "Music_Surfing") then
    return "Music_Surfing"
  end
  return song
end

-- overworld map theme; onBike/surfing override outdoor themes with the
-- bike/surf songs and restore the map theme when they end
function Music.playMap(data, mapId, onBike, surfing)
  local song = data and data.audio and data.audio.mapSongs
    and mapId and data.audio.mapSongs[mapId] or nil
  state.mapSong = song
  state.onBike = not not onBike
  state.surfing = not not surfing
  local play = effectiveMapSong(data, song)
  if play then Music.play(data, play) end
end

-- toggle the surf override mid-map (starting/ending a surf)
function Music.setSurfing(data, surfing)
  state.surfing = not not surfing
  local play = effectiveMapSong(data, state.mapSong)
  if play then Music.play(data, play) end
end

-- battle themes; kind = "wild"|"trainer"|"gym"|"final"
function Music.playBattle(data, kind)
  local b = data.audio and data.audio.battle
  if b then Music.play(data, b[kind] or b.wild) end
end

-- victory theme (Music_DefeatedWildMon/Trainer/GymLeader): starts the
-- moment the win is decided and loops until the battle screen closes
-- (each Defeated* song ends in `sound_loop 0, .mainloop`); the battle's
-- finish() restores the map theme, like the overworld reload's
-- PlayDefaultMusicFadeOutCurrent.  Returns true if the theme started.
function Music.playVictory(data, kind)
  local b = data.audio and data.audio.battle
  local jingle = b and b[kind .. "Win"]
  local def = jingle and songDef(data, jingle)
  if def and (def.file or (data.audio and data.audio.runtime)) then
    Music.play(data, jingle)
    return true
  end
  return false
end

-- one-shot jingle (PkmnHealed, Jigglypuff's song): the map theme
-- resumes when it ends, via update()
function Music.playOnce(data, song)
  local def = songDef(data, song)
  if not (def and (def.file or (data.audio and data.audio.runtime))) then
    return false
  end
  Music.play(data, song, false)
  state.pendingRestore = true
  return true
end

-- is a playOnce jingle still sounding?  (AnimateHealingMachine's
-- .waitLoop2 holds the healing machine until MUSIC_PKMN_HEALED ends)
function Music.oneShotPlaying()
  if not state.pendingRestore then return false end
  local src = state.source
  if not src then return false end
  local ok, playing = pcall(src.isPlaying, src)
  return ok and playing or false
end

function Music.restoreMap(data)
  state.current = nil
  state.pendingRestore = nil
  local play = effectiveMapSong(data, state.mapSong)
  if play then Music.play(data, play) end
end

-- 0-7 music volume (0 mutes), applied to the playing song and the
-- queued loop body as well as everything played later
function Music.setVolumeLevel(level)
  volumeScale = math.max(0, math.min(7, level or 7)) / 7
  applyVolume(state.source)
  applyVolume(state.loopSource)
end

-- music low-pass filter level, 0 (OFF) to 3
function Music.setFilterLevel(level)
  filterLevel = math.max(0, math.min(3, level or 0))
  applyFilter(state.source)
  applyFilter(state.loopSource)
end

-- re-apply persisted audio options (Game calls this on boot and after
-- loading a save)
function Music.applyOptions(opts)
  Music.setVolumeLevel(opts and opts.musicVol or 7)
  Music.setFilterLevel(opts and opts.musicFilter or 0)
end

local function sourceStopped(src)
  if not src then return false end
  local ok, playing = pcall(src.isPlaying, src)
  return ok and not playing
end

-- call once per frame: chains a finished intro into its loop body and
-- restores the map theme after a one-shot jingle
function Music.update(data)
  if data and data.audio and data.audio.runtime then
    require("src.core.ChipAudio").update()
  end
  if not state.enabled then return end
  -- volume ramp (Music.fadeOut): hold the current level for `control`
  -- frames, then drop one level (FadeOutAudio decrements both rAUDVOL
  -- nibbles when its counter reaches 0); at level 0 the music stops.
  if state.fade then
    local f = state.fade
    f.counter = f.counter - 1
    if f.counter <= 0 then
      f.counter = f.control
      f.level = f.level - 1
      if f.level <= 0 then
        state.fade = nil
        Music.stop()
        return
      end
      local vol = f.from * f.level / 7
      if state.source then pcall(state.source.setVolume, state.source, vol) end
      if state.loopSource then
        pcall(state.loopSource.setVolume, state.loopSource, vol)
      end
    end
    return
  end
  -- while a fanfare plays the song stays paused (a paused source reads
  -- as stopped, so the intro-chain/restore checks below must not run);
  -- when it ends, the song picks up where it left off
  if state.fanfare then
    if fanfareActive() then return end
    if state.fanfareResume and state.source then
      pcall(state.source.play, state.source)
    end
    state.fanfareResume = false
  end
  if data and data.audio and data.audio.runtime and not state.fanfare then
    require("src.core.ChipAudio").ensureMusicPlaying()
  end
  if state.loopSource and sourceStopped(state.source) then
    local loopSrc = state.loopSource
    state.loopSource = nil
    state.source = loopSrc
    pcall(loopSrc.play, loopSrc)
  end
  if state.pendingRestore and sourceStopped(state.source)
     and not state.loopSource then
    Music.restoreMap(data)
  end
end

return Music
