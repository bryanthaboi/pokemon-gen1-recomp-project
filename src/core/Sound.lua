-- Sound effects and cries synthesized from compact ROM channel programs,
-- from def-local chip programs (ChipAsm), or loaded from file definitions --
-- the branch is chosen per definition, not by a global import flag. Sources
-- are cached; a definition that fails to load caches as `false` so it is
-- logged once and skipped, never disabling the rest of the audio. Headless
-- use is a safe no-op.

local Assets = require("src.render.Assets")
local Logger = require("src.core.Logger")
local Runtime = require("src.mods.Runtime")

local Sound = {}

local cache = {}
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
-- data.audio.fanfares supersedes this; the copy stays as the fallback for
-- caches built before the importer wrote the table, and a def may claim the
-- behavior for itself with fanfare = true.
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

-- which mod put this key in the registry, for attributed failure logs
local function owner(data, kind, key)
  local owners = data and data.audio and data.audio._owners
  local map = owners and owners[kind]
  return map and map[key] or "base"
end

-- one log line, plus an entry in the loader's error feed when a mod owns the
-- def, so the manager's errors screen can flag that mod
local function reportBadDef(kind, key, who, err)
  Logger.warn("audio: bad %s def %q (mod %s): %s", kind, key, who, tostring(err))
  Runtime.reportError(who,
    ("audio: bad %s def %q: %s"):format(kind, key, tostring(err)))
end

local function isChipDef(def)
  return type(def) == "table" and (def.chip ~= nil or def.address ~= nil)
end

-- a file def carries an optional playback rate; a bare string is shorthand
-- for { file = <string> }
local function newFileSource(def)
  local file = type(def) == "table" and def.file or def
  if type(file) ~= "string" then return nil, "no chip program and no file" end
  local ok, s = pcall(love.audio.newSource, file, "static")
  if not ok or not s then return nil, ok and "no source" or tostring(s) end
  if type(def) == "table" and def.pitch then pcall(s.setPitch, s, def.pitch) end
  return s
end

local function newSfxSource(data, key, def, pitch, tempo)
  if isChipDef(def) then
    local ok, s = pcall(require("src.core.ChipAudio").newSfx,
      data, key:match("^([^@]+)") or key, pitch, tempo, def)
    if not ok then return nil, tostring(s) end
    if not s then return nil, "no source" end
    return s
  end
  return newFileSource(def)
end

local function playPath(data, key, def, pitch, tempo)
  if not love.audio or not def then return nil end
  local src = cache[key]
  if src == false then return nil end -- known bad, already logged
  if not src then
    local s, err = newSfxSource(data, key, def, pitch, tempo)
    if not s then
      cache[key] = false
      reportBadDef("sfx", key, owner(data, "sfx", key), err)
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

local function ducks(data, name, def)
  if type(def) == "table" and def.fanfare then return true end
  local fanfares = data.audio and data.audio.fanfares or FANFARES
  return fanfares[name] and true or false
end

local function played(kind, name, species)
  if not Runtime.wants("sound.played") then return end
  Runtime.emit("sound.played", { kind = kind, name = name, species = species })
end

function Sound.play(data, name)
  local sfx = data.audio and data.audio.sfx
  local def = sfx and sfx[name]
  local src = playPath(data, name, def)
  if not src then return end
  if ducks(data, name, def) then
    require("src.core.Music").duckForFanfare(src)
  end
  played("sfx", name)
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
  -- a chip program synthesizes the modified variant on demand; a file def
  -- can only reach for a pre-rendered one
  if isChipDef(sfx[name]) then
    if playPath(data, ("%s@%02x%02x"):format(name, pitch, tempo),
        sfx[name], pitch, tempo) then
      played("move", name)
    end
    return
  end
  if pitch ~= 0 or tempo ~= 0x80 then
    local key = ("%s@%02x%02x"):format(name, pitch, tempo)
    if sfx[key] then
      if playPath(data, key, sfx[key]) then played("move", name) end
      return
    end
  end
  if playPath(data, name, sfx[name]) then played("move", name) end
end

-- A derived cry ({ base = "RHYDON", pitch, length }) borrows another
-- species' program and applies its own modifiers, so a new species needs no
-- assets at all.  Chains are followed; the modifiers nearest the caller win.
local function resolveCry(data, def, depth)
  if type(def) ~= "table" or not def.base then return def end
  if depth > 8 then return nil, "cry base chain too deep" end
  local cries = data.audio and data.audio.cries
  local baseDef = cries and cries[def.base]
  if not baseDef then
    return nil, "unknown base cry " .. tostring(def.base)
  end
  local resolved, err = resolveCry(data, baseDef, depth + 1)
  if not resolved then return nil, err end
  if type(resolved) ~= "table" or not (resolved.header or resolved.chip) then
    return nil, "base cry " .. tostring(def.base) .. " is not a chip program"
  end
  return {
    header = resolved.header, chip = resolved.chip,
    pitch = def.pitch or resolved.pitch,
    length = def.length or resolved.length,
  }
end

local function newCrySource(data, species, def)
  local resolved, err = resolveCry(data, def, 0)
  if not resolved then return nil, err end
  if type(resolved) == "table" and (resolved.header or resolved.chip) then
    local ok, s = pcall(
      require("src.core.ChipAudio").newCry, data, species, resolved)
    if not ok then return nil, tostring(s) end
    if not s then return nil, "no source" end
    return s
  end
  return newFileSource(resolved)
end

-- returns the source (nil headless) so callers that block on the cry
-- like the original's PlayCry -> WaitForSoundToFinish can poll it
function Sound.playCry(data, species)
  if not love.audio then return nil end
  local cries = data.audio and data.audio.cries
  local def = cries and cries[species]
  if not def then return nil end
  local key = "cry:" .. tostring(species)
  local src = cache[key]
  if src == false then return nil end
  if not src then
    local s, err = newCrySource(data, species, def)
    if not s then
      cache[key] = false
      reportBadDef("cry", tostring(species),
        owner(data, "cries", species), err)
      return nil
    end
    s:setVolume(BASE_VOLUME * volumeScale)
    cache[key] = s
    src = s
  end
  src:stop()
  src:play()
  played("cry", species, species)
  return src
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
  if not love.audio then return end
  local sfx = data.audio and data.audio.sfx
  local def = sfx and sfx[name]
  local alarm = not def and name == "Low_Health_Alarm"
  if not def and not alarm then return end
  local src = loopCache[name]
  if src == false then return end
  if not src then
    local s, err
    if alarm then
      -- the synthesized siren is the default, not the rule: a registered
      -- Low_Health_Alarm def of any shape replaces it
      local ok, generated = pcall(require("src.core.ChipAudio").newLowHealthAlarm)
      if ok then s = generated else err = tostring(generated) end
    else
      s, err = newSfxSource(data, name, def)
    end
    if not s then
      loopCache[name] = false
      reportBadDef("sfx", name, owner(data, "sfx", name), err or "no source")
      return
    end
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
    if src then pcall(src.setVolume, src, BASE_VOLUME * volumeScale) end
  end
  for _, src in pairs(loopCache) do
    if src then pcall(src.setVolume, src, BASE_VOLUME * volumeScale) end
  end
end

-- hot reload / jukebox A-B: drop one key's sources (its pitch-tempo
-- variants included) or all of them, so the next play re-resolves the def
function Sound.invalidate(name)
  local function evict(store, key)
    local src = store[key]
    if src then pcall(src.stop, src) end
    store[key] = nil
  end
  for _, store in ipairs({ cache, loopCache }) do
    for key in pairs(store) do
      if not name or key == name or key:sub(1, #name + 1) == name .. "@" then
        evict(store, key)
      end
    end
  end
  for key, src in pairs(looping) do
    if not name or key == name then
      pcall(src.stop, src)
      looping[key] = nil
    end
  end
end

-- the flush fan-out calls with no key, dropping everything, so an edited
-- def is re-resolved on the next play (20 §2 cache contract, audio row)
Assets.register(Sound.invalidate)

-- re-apply persisted audio options (Game calls this on boot and after
-- loading a save)
function Sound.applyOptions(opts)
  Sound.setVolumeLevel(opts and opts.sfxVol or 7)
end

return Sound
