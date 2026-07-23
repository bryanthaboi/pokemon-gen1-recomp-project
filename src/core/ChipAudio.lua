-- Playback front end for the Game Boy audio synth (src/core/ChipSynth.lua).
--
-- Map/battle MUSIC is streamed from a background worker thread
-- (src/core/chip_worker.lua): the worker synthesizes the PCM buffers and this
-- module only queues finished SoundData onto a QueueableSource.  That is the
-- fix for the map-transition stutter -- filling the deep (~6s) playback queue
-- from scratch when a song changes is ~200ms of Lua synthesis, and doing it on
-- the render thread dropped frames for the ~10 frames after every seam
-- crossing.  Off-thread, a song change costs the main loop essentially
-- nothing.
--
-- When love.thread is unavailable (the headless test stub) or a worker fails
-- to start, music falls back to the original synchronous, amortized queue fill
-- so behavior is unchanged -- see the `threaded` branch in each entry point.
--
-- SFX and cries stay synchronous: they are short one-shots rendered once into
-- a static Source, not a per-frame streaming cost.

local Assets = require("src.render.Assets")
local ChipSynth = require("src.core.ChipSynth")

local ChipAudio = {}

local SAMPLE_RATE = ChipSynth.SAMPLE_RATE
local MUSIC_BUFFER_SAMPLES = ChipSynth.MUSIC_BUFFER_SAMPLES
local MUSIC_BUFFER_COUNT = ChipSynth.MUSIC_BUFFER_COUNT

-- currentMusic: { source, gen, threaded, started, finished, engine }
--   threaded songs stream from the worker (engine is nil here);
--   the fallback path owns a local engine and fills the source itself.
local currentMusic
local pendingBuf -- a current-gen buffer popped from the worker but not yet
                 -- queued because the Source was momentarily full

-- ---------------------------------------------------------------------------
-- worker management
-- ---------------------------------------------------------------------------

local worker, cmdCh, outCh
local workerReady -- nil = untried, true = running, false = unavailable

local function ensureWorker()
  if workerReady ~= nil then return workerReady end
  if not (love.thread and love.thread.newThread and love.audio) then
    workerReady = false
    return false
  end
  local ok, thread = pcall(love.thread.newThread, "src/core/chip_worker.lua")
  if not ok or not thread then
    workerReady = false
    return false
  end
  cmdCh = love.thread.getChannel("chipaudio_cmd")
  outCh = love.thread.getChannel("chipaudio_out")
  local started = pcall(function() thread:start() end)
  if not started then
    workerReady = false
    return false
  end
  worker = thread
  workerReady = true
  return true
end

-- only the tables ChipSynth.newEngine reads for ROM songs; sent with every
-- play so a hot-reloaded dataset (or a mod's audio) always reaches the worker
local function slimAudio(data)
  local audio = data.audio or {}
  return {
    programFile = audio.programFile,
    bankOrder = audio.bankOrder,
    waveBanks = audio.waveBanks,
    noiseHeaders = audio.noiseHeaders,
  }
end

-- If the worker died (a malformed def that errors mid-synth), fall back to the
-- synchronous path for the rest of the session instead of going silent.
local function workerAlive()
  if not worker then return false end
  local err = worker:getError()
  if err then
    require("src.core.Logger").warn("chip audio worker died: %s", tostring(err))
    workerReady = false
    worker = nil
    return false
  end
  return true
end

-- ---------------------------------------------------------------------------
-- synchronous fallback (no love.thread): the original amortized queue fill
-- ---------------------------------------------------------------------------

-- The queue is deep (MUSIC_BUFFER_COUNT, ~6s) for stall tolerance, but
-- synthesizing all of it on the frame a song starts renders ~6s of audio at
-- once.  Cap how many buffers each fill renders; playback drains ~1 buffer
-- every ~11 frames while update() tops up a few per frame, so the deep queue
-- still ramps to full within a fraction of a second.
local MUSIC_FILL_INITIAL = 4
local MUSIC_FILL_PER_CALL = 3

local function fillSync(limit)
  local music = currentMusic
  if not music or not music.engine or music.engine:finished() then return end
  limit = limit or MUSIC_FILL_PER_CALL
  local free = music.source:getFreeBufferCount()
  while free > 0 and limit > 0 and not music.engine:finished() do
    music.source:queue(ChipSynth.soundData(music.engine, MUSIC_BUFFER_SAMPLES, 2))
    free = free - 1
    limit = limit - 1
  end
end

local function playMusicSync(data, header, allowLoops)
  -- build before tearing down: a def that fails to compile must leave the
  -- outgoing song sounding
  local ok, engine = pcall(ChipSynth.newEngine, data, header,
                           { allowLoops = allowLoops })
  if not ok then return nil, engine end
  local ok2, source = pcall(
    love.audio.newQueueableSource, SAMPLE_RATE, 16, 2, MUSIC_BUFFER_COUNT)
  if not ok2 then return nil, source end
  ChipAudio.stopMusic()
  currentMusic = { source = source, engine = engine, threaded = false,
                   started = true, finished = false }
  fillSync(MUSIC_FILL_INITIAL)
  source:play()
  return source
end

-- ---------------------------------------------------------------------------
-- threaded music
-- ---------------------------------------------------------------------------

local musicGen = 0

function ChipAudio.playMusic(data, header, allowLoops)
  if not ensureWorker() then
    return playMusicSync(data, header, allowLoops)
  end
  -- validate the def on this thread (cheap: engine construction, no synthesis)
  -- so a broken def costs nothing but a log line and keeps the old song
  local ok, engine = pcall(ChipSynth.newEngine, data, header,
                           { allowLoops = allowLoops })
  if not ok then return nil, engine end
  -- build the new source before tearing the old song down
  local ok2, source = pcall(
    love.audio.newQueueableSource, SAMPLE_RATE, 16, 2, MUSIC_BUFFER_COUNT)
  if not ok2 then return nil, source end
  ChipAudio.stopMusic()
  musicGen = musicGen + 1
  local gen = musicGen
  cmdCh:push({ cmd = "play", gen = gen, header = header,
               allowLoops = allowLoops, audio = slimAudio(data) })
  currentMusic = { source = source, gen = gen, threaded = true,
                   started = false, finished = false }
  -- playback starts in update() once the first buffer arrives (~1 frame)
  return source
end

-- move finished buffers from the worker into the Source; start playback once
-- the first one lands
local function updateThreaded()
  local m = currentMusic
  if not m then return end
  if not workerAlive() then
    -- worker gone: nothing more will arrive; leave whatever is queued playing
    return
  end
  while true do
    local free = m.source:getFreeBufferCount()
    local buf = pendingBuf
    if buf then pendingBuf = nil else buf = outCh:pop() end
    if not buf then break end
    if buf.gen ~= m.gen then
      -- stale buffer from a superseded song: drop it
    elseif buf.done then
      m.finished = true
    elseif buf.error then
      require("src.core.Logger").warn("chip audio: %s", tostring(buf.error))
      m.finished = true
    elseif buf.sd then
      if free > 0 then
        m.source:queue(buf.sd)
      else
        pendingBuf = buf -- Source full; hold this one for next frame
        break
      end
    end
  end
  if not m.started then
    if (MUSIC_BUFFER_COUNT - m.source:getFreeBufferCount()) > 0 then
      pcall(function() m.source:play() end)
      m.started = true
    end
  end
end

function ChipAudio.update()
  local m = currentMusic
  if not m then return end
  if m.threaded then
    updateThreaded()
  else
    fillSync()
  end
end

-- Recover from a queue underrun caused by a long render stall.  Called after
-- Music has handled intentional fanfare pauses, so it never fights the normal
-- pause/resume behavior.
function ChipAudio.ensureMusicPlaying()
  local m = currentMusic
  if not m or m.finished then return end
  if m.threaded then
    if not m.started then return end
    local ok, playing = pcall(function() return m.source:isPlaying() end)
    if ok and not playing
       and (MUSIC_BUFFER_COUNT - m.source:getFreeBufferCount()) > 0 then
      pcall(function() m.source:play() end)
    end
  else
    if not m.engine or m.engine:finished() then return end
    local ok, playing = pcall(m.source.isPlaying, m.source)
    if ok and not playing then
      fillSync(MUSIC_FILL_INITIAL)
      pcall(m.source.play, m.source)
    end
  end
end

function ChipAudio.stopMusic()
  if currentMusic and currentMusic.source then
    pcall(currentMusic.source.stop, currentMusic.source)
  end
  if workerReady and cmdCh then
    cmdCh:push({ cmd = "stop" })
    if outCh then outCh:clear() end
  end
  pendingBuf = nil
  currentMusic = nil
end

-- hot reload: the next play re-reads programs.bin (a mod may have swapped the
-- file out from under the single-slot bank cache), on both threads
function ChipAudio.invalidate()
  ChipAudio.stopMusic()
  ChipSynth.invalidateBanks()
  if workerReady and cmdCh then cmdCh:push({ cmd = "invalidate" }) end
end

-- a stale song must not keep sounding past the flush that replaced its
-- program (20 §2 cache contract, chip music row)
Assets.register(ChipAudio.invalidate)

-- ---------------------------------------------------------------------------
-- one-shot effects (SFX, cries, low-health alarm): synchronous static Sources
-- ---------------------------------------------------------------------------

local function renderEffect(data, header, options)
  local sd = ChipSynth.renderEffectData(data, header, options)
  if not sd then return nil end
  return love.audio.newSource(sd, "static")
end

function ChipAudio.newSfx(data, name, pitch, tempo, header)
  header = header or data.audio.sfx[name]
  return renderEffect(data, header, {
    frequencyOffset = pitch or 0,
    frameTicks = 0x80 + (tempo or 0x80),
  })
end

-- `resolved` is a {header|chip, pitch, length} def the caller already worked
-- out -- a derived cry borrowing another species' header with its own
-- modifiers, which no registry lookup under `species` could find
function ChipAudio.newCry(data, species, resolved)
  local cry = resolved or (data.audio.cries and data.audio.cries[species])
  if not cry then return nil end
  return renderEffect(data, cry.chip and cry or cry.header, {
    frequencyOffset = cry.pitch,
    cryLength = cry.length,
  })
end

function ChipAudio.newLowHealthAlarm()
  local samples = math.floor(SAMPLE_RATE * 62 / 60)
  local data = love.sound.newSoundData(samples, SAMPLE_RATE, 16, 1)
  local phase = 0
  for index = 0, samples - 1 do
    local frame = math.floor(index * 60 / SAMPLE_RATE) % 31
    local register = frame < 11 and 0x750 or 0x6EE
    local frequency = 131072 / (2048 - register)
    phase = (phase + frequency / SAMPLE_RATE) % 1
    data:setSample(index, (phase < 0.5 and 1 or -1) * 0.25)
  end
  return love.audio.newSource(data, "static")
end

-- ---------------------------------------------------------------------------
-- test hooks (headless): synchronous synthesis straight through ChipSynth
-- ---------------------------------------------------------------------------

function ChipAudio._renderMusicForTest(data, header, seconds)
  local engine = ChipSynth.newEngine(data, header, { allowLoops = true })
  return ChipSynth.soundData(engine, math.floor(seconds * SAMPLE_RATE), 2)
end

function ChipAudio._renderMusicChannelForTest(data, header, seconds, number)
  local engine = ChipSynth.newEngine(data, header, { allowLoops = true })
  local samples = math.floor(seconds * SAMPLE_RATE)
  local result = love.sound.newSoundData(samples, SAMPLE_RATE, 16, 1)
  for index = 0, samples - 1 do
    result:setSample(index, engine:sampleChannel(number))
  end
  return result
end

function ChipAudio._traceFirstMusicSampleForTest(data, header)
  local engine = ChipSynth.newEngine(data, header, { allowLoops = true })
  local result = {}
  for _, channel in ipairs(engine.channels) do
    local value = channel:sample()
    local event = channel.event or {}
    result[#result + 1] = {
      number = channel.number,
      value = value,
      register = event.register,
      duration = event.duration,
      volume = event.volume,
      duty = event.duty,
      wave = event.wave,
      waveInstrument = event.waveInstrument,
      drumSegments = event.drum and #event.drum or nil,
      noiseParameter = event.noiseParameter,
      sweep = event.sweep,
    }
  end
  return result
end

function ChipAudio._traceFirstSfxSampleForTest(data, header)
  local engine = ChipSynth.newEngine(data, header, {
    sfx = true,
    allowLoops = false,
  })
  local result = {}
  for _, channel in ipairs(engine.channels) do
    local value = channel:sample()
    local event = channel.event or {}
    result[#result + 1] = {
      number = channel.number,
      value = value,
      register = event.register,
      duration = event.duration,
      volume = event.volume,
      fade = event.fade,
      noiseParameter = event.noiseParameter,
      sweep = event.sweep,
    }
  end
  return result
end

function ChipAudio._renderSfxForTest(data, header, seconds)
  local engine = ChipSynth.newEngine(data, header, {
    sfx = true,
    allowLoops = false,
  })
  return ChipSynth.soundData(engine, math.floor(seconds * SAMPLE_RATE), 1)
end

return ChipAudio
