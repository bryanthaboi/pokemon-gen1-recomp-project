-- Sound effects and cries synthesized from compact ROM channel programs or
-- loaded from legacy static audio definitions. Sources are cached; headless
-- use is a safe no-op.

local Sound = {}

local cache = {}
local enabled = true
-- port addition: 0-7 SFX volume from save.options.sfxVol (OptionsMenu),
-- scaling the 0.8 base every source gets
local BASE_VOLUME = 0.8
local volumeScale = 1

-- Fanfares occupy the music's tone channels on the Game Boy: their sfx
-- headers claim channels 5-7 (= hardware channels 1-3), silencing the
-- song until they finish (audio/headers/sfxheaders*.asm; the game also
-- blocks on them via PlaySoundWaitForCurrent/WaitForSoundToFinish).
-- The Poké Flute even issues SFX_STOP_ALL_MUSIC first
-- (engine/items/item_effects.asm).  Music.lua pauses the current song
-- while one of these plays and resumes it afterwards.  Ordinary short
-- SFX (menu beeps, hits, cries) stay overlaid.
local FANFARES = {
  Level_Up = true,
  Caught_Mon = true,
  Get_Item1 = true,
  Get_Item2 = true,
  Get_Key_Item = true,
  Pokedex_Rating = true,
  Dex_Page_Added = true,
  Pokeflute = true,
}

local function playPath(data, key, path, pitch, tempo)
  if not enabled or not love.audio or not path then return nil end
  local src = cache[key]
  if not src then
    local ok, s
    if data.audio and data.audio.runtime and type(path) == "table" then
      ok, s = pcall(
        require("src.core.ChipAudio").newSfx,
        data, key:match("^([^@]+)") or key, pitch, tempo, path)
    else
      ok, s = pcall(love.audio.newSource, path, "static")
    end
    if not ok or not s then
      enabled = false
      return nil
    end
    s:setVolume(BASE_VOLUME * volumeScale)
    cache[key] = s
    src = s
  end
  src:stop()
  src:play()
  return src
end

function Sound.play(data, name)
  local sfx = data.audio and data.audio.sfx
  local src = playPath(data, name, sfx and sfx[name])
  if src and FANFARES[name] then
    require("src.core.Music").duckForFanfare(src)
  end
end

-- Play a move's sound with its MoveSoundTable pitch/tempo modifiers
-- (data/moves/sfx.asm; GetMoveSound loads them into wFrequencyModifier/
-- wTempoModifier and the battle sound engine applies them to every
-- battle SFX -- audio/engine_2.asm Audio2_ApplyFrequencyModifier/
-- Audio2_SetSfxTempo).  The extractor pre-synthesizes one WAV per
-- distinct (sfx, pitch, tempo) as "<name>@<pitch><tempo>" keys in the
-- sfx table; older audio.lua builds without the variants fall back to
-- the unmodified sound.
-- anim: a moves.lua anim table { sound, pitch, tempo }.
function Sound.playMove(data, anim)
  if not anim or not anim.sound then return end
  local sfx = data.audio and data.audio.sfx
  if not sfx then return end
  local name = anim.sound
  local pitch, tempo = anim.pitch or 0, anim.tempo or 0x80
  if data.audio.runtime and sfx[name] then
    playPath(data, ("%s@%02x%02x"):format(name, pitch, tempo),
      sfx[name], pitch, tempo)
    return
  end
  if pitch ~= 0 or tempo ~= 0x80 then
    local key = ("%s@%02x%02x"):format(name, pitch, tempo)
    if sfx[key] then
      playPath(data, key, sfx[key])
      return
    end
  end
  playPath(data, name, sfx[name])
end

function Sound.playCry(data, species)
  local cries = data.audio and data.audio.cries
  -- returns the source (nil headless) so callers that block on the cry
  -- like the original's PlayCry -> WaitForSoundToFinish can poll it
  local definition = cries and cries[species]
  if data.audio and data.audio.runtime and definition then
    local key = "cry:" .. tostring(species)
    local src = cache[key]
    if not src then
      local ok, generated = pcall(
        require("src.core.ChipAudio").newCry, data, species)
      if not ok or not generated then return nil end
      generated:setVolume(BASE_VOLUME * volumeScale)
      cache[key] = generated
      src = generated
    end
    src:stop()
    src:play()
    return src
  end
  return playPath(data, "cry:" .. tostring(species), definition)
end

-- GROWL/ROAR are the only two moves that play a cry (IsCryMove checks
-- wAnimationID); GetMoveSound still adds their own MoveSoundTable pitch/
-- tempo bytes on top of the cry's species modifiers before the tempo
-- register is set (Audio2_SetSfxTempo: tempo9bit = wTempoModifier+$80).
-- $80 is the table's "no extra shift" tempo byte (every other move's
-- entry defaults to it), so the two moves' own bytes -- Growl's $c0,
-- Roar's $40 -- are the *extra* shift on top of whatever the species'
-- cry already sounds like. The generated cry source already includes the
-- species' pitch/tempo, so layer the move's extra shift on with
-- Source:setPitch (pitch mod is left unmodeled: both moves set it $00).
function Sound.playMoveCry(data, species, tempoMod)
  local src = Sound.playCry(data, species)
  if src and tempoMod and tempoMod ~= 0x80 then
    pcall(src.setPitch, src, 256 / (128 + tempoMod))
  end
  return src
end

-- is a previously played one-shot still sounding?  (ShakeElevator's
-- .musicLoop polls wChannelSoundIDs+CHAN5 until SFX_SAFARI_ZONE_PA
-- ends.)  Headless / never-played names read as silent.
function Sound.isPlaying(name)
  local src = cache[name]
  if not src then return false end
  local ok, playing = pcall(src.isPlaying, src)
  return ok and playing or false
end

-- cut a one-shot short (the SFX_STOP_ALL_MUSIC beats around the
-- elevator shake stop the last collision thud mid-ring)
function Sound.stop(name)
  local src = cache[name]
  if src then pcall(src.stop, src) end
end

-- Looping sources (the low-health alarm): started/stopped by game
-- states. ChipAudio generates the two-tone siren used by runtime imports;
-- legacy data can still provide a looping static source.
local loopCache = {}
local looping = {}

function Sound.startLoop(data, name)
  if looping[name] then return end
  local sfx = data.audio and data.audio.sfx
  local path = sfx and sfx[name]
  local runtimeAlarm = data.audio and data.audio.runtime
    and name == "Low_Health_Alarm"
  if not enabled or not love.audio or (not path and not runtimeAlarm) then
    return
  end
  local src = loopCache[name]
  if not src then
    local ok, s
    if data.audio.runtime and name == "Low_Health_Alarm" then
      ok, s = pcall(require("src.core.ChipAudio").newLowHealthAlarm)
    elseif data.audio.runtime and type(path) == "table" then
      ok, s = pcall(
        require("src.core.ChipAudio").newSfx, data, name)
    else
      ok, s = pcall(love.audio.newSource, path, "static")
    end
    if not ok then return end
    s:setLooping(true)
    s:setVolume(BASE_VOLUME * volumeScale)
    loopCache[name] = s
    src = s
  end
  src:play()
  looping[name] = src
end

function Sound.stopLoop(name)
  local src = looping[name]
  if src then
    pcall(src.stop, src)
    looping[name] = nil
  end
end

-- is a looping source currently sounding? (drivers assert on this)
function Sound.isLooping(name)
  return looping[name] ~= nil
end

-- 0-7 SFX volume level (0 mutes); cached sources (menu beeps, cries,
-- the low-health alarm loop) update immediately so the change is heard
-- on the next play
function Sound.setVolumeLevel(level)
  volumeScale = math.max(0, math.min(7, level or 7)) / 7
  for _, src in pairs(cache) do
    pcall(src.setVolume, src, BASE_VOLUME * volumeScale)
  end
  for _, src in pairs(loopCache) do
    pcall(src.setVolume, src, BASE_VOLUME * volumeScale)
  end
end

-- re-apply persisted audio options (Game calls this on boot and after
-- loading a save)
function Sound.applyOptions(opts)
  Sound.setVolumeLevel(opts and opts.sfxVol or 7)
end

return Sound
