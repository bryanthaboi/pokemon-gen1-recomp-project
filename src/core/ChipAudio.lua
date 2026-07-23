local bit = require("bit")
local Assets = require("src.render.Assets")

local ChipAudio = {}

local SAMPLE_RATE = 22050
local TICKS_PER_SECOND = 15360
local FRAME_TICKS = 256
-- Desktop/mobile playback should tolerate render stalls such as window
-- resizing.  The original queue was only about 0.37s deep; this gives the
-- queue roughly six seconds of headroom without changing the synthesized
-- Game Boy timing or pitch.
local MUSIC_BUFFER_SAMPLES = 4096
local MUSIC_BUFFER_COUNT = 32
local GB_CLOCK = 4194304

local PITCHES = {
  0xF82C, 0xF89D, 0xF907, 0xF96B, 0xF9CA, 0xFA23,
  0xFA77, 0xFAC7, 0xFB12, 0xFB58, 0xFB9B, 0xFBDA,
}
local DUTY = { [0] = 0.125, [1] = 0.25, [2] = 0.5, [3] = 0.75 }
local WAVE_LEVEL = { [0] = 0, [1] = 1, [2] = 0.5, [3] = 0.25 }
local NOISE_DIVISORS = {
  [0] = 8, [1] = 16, [2] = 32, [3] = 48,
  [4] = 64, [5] = 80, [6] = 96, [7] = 112,
}

local function snapTicks(ticks)
  return math.floor((ticks * 735 + 256) / 512)
end

local cachedProgramFile
local cachedBanks
local currentMusic

local function loadBanks(data)
  local audio = data.audio
  if cachedProgramFile == audio.programFile and cachedBanks then
    return cachedBanks
  end
  local raw, readError = love.filesystem.read(audio.programFile)
  if not raw then error("could not read sound programs: " .. tostring(readError)) end
  local banks = {}
  for index, bank in ipairs(audio.bankOrder) do
    local first = (index - 1) * 0x4000 + 1
    banks[bank] = raw:sub(first, first + 0x3FFF)
  end
  cachedProgramFile, cachedBanks = audio.programFile, banks
  return banks
end

-- A def-local program (ChipAsm output) is mounted as pseudo-bank 0 next to
-- the ROM banks, so the 0x4000-window byte reader and every call/loop
-- target work unchanged.  The ROM's own cached bank table is never touched
-- because bank 0 differs per def, and a blob that carries its own waves and
-- drums renders even where programs.bin is unreadable.
local function engineBanks(data, chip)
  if not chip then return loadBanks(data) end
  local banks = {}
  local ok, romBanks = pcall(loadBanks, data)
  if ok then
    for bank, bytes in pairs(romBanks) do banks[bank] = bytes end
  end
  banks[0] = chip.blob
  return banks
end

local function romByte(banks, bank, address)
  local bytes = assert(banks[bank], "uncached audio bank " .. tostring(bank))
  local value = bytes:byte(address - 0x4000 + 1)
  if not value then
    error(("audio read outside bank %02X:%04X"):format(bank, address))
  end
  return value
end

local function romWord(banks, bank, address)
  return romByte(banks, bank, address)
    + romByte(banks, bank, address + 1) * 0x100
end

local function headerChannels(banks, header)
  local channels = {}
  local address = header.address
  local first = romByte(banks, header.bank, address)
  local count = bit.rshift(bit.band(first, 0xF0), 6) + 1
  for _ = 1, count do
    local descriptor = romByte(banks, header.bank, address)
    channels[#channels + 1] = {
      number = bit.band(descriptor, 0x0F) + 1,
      address = romWord(banks, header.bank, address + 1),
    }
    address = address + 3
  end
  return channels
end

local function fadeValue(nibble)
  if bit.band(nibble, 8) ~= 0 then return -bit.band(nibble, 7) end
  return nibble
end

local Channel = {}
Channel.__index = Channel

function Channel.new(engine, spec, options)
  options = options or {}
  local hardware = (spec.number - 1) % 4 + 1
  local isSfxChannel = spec.number > 4
  return setmetatable({
    engine = engine,
    bank = options.bank,
    address = spec.address,
    number = spec.number,
    hardware = hardware,
    wave = hardware == 3,
    noise = hardware == 4,
    sfx = isSfxChannel,
    executeMusic = not isSfxChannel,
    allowLoops = options.allowLoops ~= false,
    frequencyOffset = options.frequencyOffset or 0,
    frameTicks = options.frameTicks or FRAME_TICKS,
    speed = 12,
    volume = 12,
    fade = 0,
    duty = 0.5,
    octave = 4,
    waveInstrument = 0,
    waveLevel = 1,
    perfectPitch = false,
    vibrato = nil,
    pendingSlide = nil,
    sweep = nil,
    callStack = {},
    loopCounts = {},
    event = nil,
    ended = false,
    phase = 0,
    noiseLfsr = 0x7FFF,
    noiseClock = 0,
    timeTicks = 0,
  }, Channel)
end

function Channel:byte()
  local value = romByte(self.engine.banks, self.bank, self.address)
  self.address = self.address + 1
  return value
end

function Channel:word()
  local value = romWord(self.engine.banks, self.bank, self.address)
  self.address = self.address + 2
  return value
end

function Channel:frequency(note, octave)
  local signed = PITCHES[note + 1] - 0x10000
  local register = bit.band(
    bit.arshift(signed, math.max(0, (octave or self.octave) - 1)), 0x7FF)
  if self.perfectPitch then register = bit.band(register + 1, 0x7FF) end
  return bit.band(register + self.frequencyOffset, 0x7FF)
end

function Channel:durationTicks(length)
  local tempo = self.sfx and self.frameTicks or self.engine.tempo
  local speed = self.sfx and (self.executeMusic and self.speed or 1)
    or self.speed
  return length * speed * tempo
end

function Channel:timedEvent(event, ticks)
  local first = snapTicks(self.timeTicks)
  self.timeTicks = self.timeTicks + ticks
  event.duration = ticks / TICKS_PER_SECOND
  event.samples = snapTicks(self.timeTicks) - first
  event.sample = 0
  event.elapsed = 0
  return event
end

function Channel:pan()
  local mask = bit.lshift(1, self.hardware - 1)
  return bit.band(bit.rshift(self.engine.pan, 4), mask) ~= 0,
    bit.band(self.engine.pan, mask) ~= 0
end

function Channel:tone(ticks, register, volume, fade)
  if register >= 0x800 then
    return self:timedEvent({ silence = true }, ticks)
  end
  local duration = ticks / TICKS_PER_SECOND
  local panLeft, panRight = self:pan()
  local slide
  if self.pendingSlide then
    slide = {
      target = self.pendingSlide.target,
      frames = math.max(1, duration * 60 - self.pendingSlide.length),
    }
    self.pendingSlide = nil
  end
  return self:timedEvent({
    register = register,
    volume = volume == nil and self.volume or volume,
    fade = fade == nil and self.fade or fade,
    duty = self.duty,
    wave = self.wave,
    waveInstrument = self.waveInstrument,
    waveLevel = self.waveLevel,
    vibrato = slide and nil or self.vibrato,
    slide = slide,
    sweep = self.sfx and self.hardware == 1 and self.sweep or nil,
    panLeft = panLeft,
    panRight = panRight,
  }, ticks)
end

function Channel:noiseEvent(ticks, volume, fade, parameter)
  local panLeft, panRight = self:pan()
  return self:timedEvent({
    noise = true,
    volume = volume or self.volume,
    fade = fade or 0,
    noiseParameter = parameter,
    panLeft = panLeft, panRight = panRight,
  }, ticks)
end

function Channel:drumEvent(ticks, instrument)
  local panLeft, panRight = self:pan()
  return self:timedEvent({
    noise = true,
    drum = self.engine:noiseInstrument(instrument),
    panLeft = panLeft,
    panRight = panRight,
  }, ticks)
end

function Channel:silenceEvent(ticks)
  return self:timedEvent({ silence = true }, ticks)
end

function Channel:nextEvent()
  if self.ended then return nil end
  for _ = 1, 100000 do
    local commandAddress = self.address
    local command = self:byte()

    if (self.executeMusic or not self.sfx) and command < 0xC0 then
      local note = bit.rshift(command, 4)
      local length = bit.band(command, 0x0F) + 1
      if self.noise then
        local instrument = note
        if command >= 0xB0 then instrument = self:byte() end
        return self:drumEvent(self:durationTicks(length), instrument)
      end
      return self:tone(self:durationTicks(length), self:frequency(note))
    elseif command >= 0xC0 and command < 0xD0 then
      local length = bit.band(command, 0x0F) + 1
      return self:silenceEvent(self:durationTicks(length))
    elseif command >= 0xD0 and command < 0xE0 then
      self.speed = bit.band(command, 0x0F)
      if not self.noise then
        local packed = self:byte()
        if self.wave then
          self.waveLevel = WAVE_LEVEL[bit.band(bit.rshift(packed, 4), 3)]
          self.waveInstrument = bit.band(packed, 0x0F)
        else
          self.volume = bit.rshift(packed, 4)
          self.fade = fadeValue(bit.band(packed, 0x0F))
        end
      end
    elseif command >= 0xE0 and command <= 0xE7 then
      self.octave = 8 - bit.band(command, 7)
    elseif command == 0xE8 then
      self.perfectPitch = not self.perfectPitch
    elseif command == 0xE9 then
      -- Unused command.
    elseif command == 0xEA then
      local delay, packed = self:byte(), self:byte()
      local depth = bit.rshift(packed, 4)
      if depth == 0 then
        self.vibrato = nil
      else
        self.vibrato = {
          delay = delay,
          above = bit.rshift(depth, 1) + bit.band(depth, 1),
          below = bit.rshift(depth, 1),
          rate = bit.band(packed, 0x0F),
        }
      end
    elseif command == 0xEB then
      local length, packed = self:byte(), self:byte()
      local octave = 8 - bit.rshift(packed, 4)
      self.pendingSlide = {
        length = length,
        target = self:frequency(bit.band(packed, 0x0F), octave),
      }
    elseif command == 0xEC then
      self.duty = DUTY[bit.band(self:byte(), 3)] or 0.5
    elseif command == 0xED then
      self.engine.tempo = self:byte() * 0x100 + self:byte()
    elseif command == 0xEE then
      self.engine.pan = self:byte()
    elseif command == 0xEF or command == 0xF0 then
      self:byte()
    elseif command == 0xF8 then
      self.executeMusic = not self.executeMusic
    elseif command == 0xFC then
      local packed = self:byte()
      self.duty = {
        DUTY[bit.band(bit.rshift(packed, 6), 3)],
        DUTY[bit.band(bit.rshift(packed, 4), 3)],
        DUTY[bit.band(bit.rshift(packed, 2), 3)],
        DUTY[bit.band(packed, 3)],
      }
    elseif command == 0xFD then
      self.callStack[#self.callStack + 1] = self.address + 2
      self.address = self:word()
    elseif command == 0xFE then
      local count, target = self:byte(), self:word()
      if count == 0 then
        if self.allowLoops then
          self.address = target
        else
          self.ended = true
          return nil
        end
      else
        local remaining = self.loopCounts[commandAddress]
        if remaining == nil then remaining = count end
        remaining = remaining - 1
        if remaining > 0 then
          self.loopCounts[commandAddress] = remaining
          self.address = target
        else
          self.loopCounts[commandAddress] = nil
        end
      end
    elseif command == 0xFF then
      local returnAddress = table.remove(self.callStack)
      if returnAddress then
        self.address = returnAddress
      else
        self.ended = true
        return nil
      end
    elseif self.sfx and command >= 0x20 and command < 0x30 then
      local length = bit.band(command, 0x0F) + 1
      local packed = self:byte()
      local volume = bit.rshift(packed, 4)
      local fade = fadeValue(bit.band(packed, 0x0F))
      if self.noise then
        local parameter = self:byte()
        return self:noiseEvent(
          self:durationTicks(length), volume, fade, parameter)
      end
      local register = bit.band(self:word() + self.frequencyOffset, 0x7FF)
      return self:tone(self:durationTicks(length), register, volume, fade)
    elseif command == 0x10 then
      local packed = self:byte()
      self.sweep = {
        pace = bit.band(bit.rshift(packed, 4), 7),
        subtract = bit.band(packed, 8) ~= 0,
        shift = bit.band(packed, 7),
      }
    else
      self.ended = true
      return nil
    end
  end
  self.ended = true
  return nil
end

local function envelopeVolume(volume, fade, elapsed)
  if fade == 0 then return volume end
  local steps = math.floor(elapsed / (math.abs(fade) / 64))
  if fade > 0 then return math.max(0, volume - steps) end
  return math.min(15, volume + steps)
end

function Channel:resetNoise()
  self.noiseLfsr = 0x7FFF
  self.noiseClock = 0
end

function Channel:clockNoise(width7)
  local feedback = bit.bxor(
    bit.band(self.noiseLfsr, 1),
    bit.band(bit.rshift(self.noiseLfsr, 1), 1))
  self.noiseLfsr = bit.bor(
    bit.rshift(self.noiseLfsr, 1),
    bit.lshift(feedback, 14))
  if width7 then
    self.noiseLfsr = bit.bor(
      bit.band(self.noiseLfsr, bit.bnot(0x40)),
      bit.lshift(feedback, 6))
  end
end

function Channel:sampleNoise(parameter)
  parameter = parameter or 0
  local divisor = NOISE_DIVISORS[bit.band(parameter, 7)]
  local shift = bit.rshift(parameter, 4)
  local output = bit.band(self.noiseLfsr, 1) == 0 and 1 or -1
  if shift >= 14 then return output end
  local cycles = GB_CLOCK / divisor / (2 ^ shift) / SAMPLE_RATE
  local width7 = bit.band(parameter, 8) ~= 0
  local remaining = cycles
  local area = 0

  while remaining > 0 do
    local untilClock = 1 - self.noiseClock
    local span = math.min(remaining, untilClock)
    output = bit.band(self.noiseLfsr, 1) == 0 and 1 or -1
    area = area + output * span
    self.noiseClock = self.noiseClock + span
    remaining = remaining - span
    if self.noiseClock >= 1 - 1e-12 then
      self.noiseClock = 0
      self:clockNoise(width7)
    end
  end

  return area / cycles
end

local function sweepCalculation(register, sweep)
  local delta = math.floor(register / (2 ^ sweep.shift))
  if sweep.subtract then return register - delta end
  return register + delta
end

local function sweptRegister(register, sweep, elapsed)
  if not sweep or sweep.shift == 0 then return register end
  local nextRegister = sweepCalculation(register, sweep)
  if nextRegister > 0x7FF or nextRegister < 0 then return nil end
  if sweep.pace == 0 then return register end

  local iterations = math.floor(elapsed * 128 / sweep.pace)
  for _ = 1, iterations do
    register = nextRegister
    nextRegister = sweepCalculation(register, sweep)
    if nextRegister > 0x7FF or nextRegister < 0 then return nil end
  end
  return register
end

function Channel:sampleDrum(event, sampleIndex)
  local index = event.drumSegmentIndex or 1
  local segment = event.drum[index]
  while segment and sampleIndex >= segment.endSample do
    index = index + 1
    segment = event.drum[index]
  end
  if not segment or sampleIndex < segment.startSample then return 0 end
  if event.drumSegmentIndex ~= index then
    event.drumSegmentIndex = index
    self:resetNoise()
  end
  local elapsed = (sampleIndex - segment.startSample) / SAMPLE_RATE
  local volume = envelopeVolume(segment.volume, segment.fade, elapsed)
  return self:sampleNoise(segment.parameter) * volume / 15 * 0.35
end

function Channel:sample()
  while not self.ended
      and (not self.event or self.event.sample >= self.event.samples) do
    self.event = self:nextEvent()
    self.phase = 0
    self:resetNoise()
  end
  local event = self.event
  if not event then return 0 end
  local sampleIndex = event.sample
  event.elapsed = sampleIndex / SAMPLE_RATE
  event.sample = sampleIndex + 1
  if event.silence then return 0 end

  if event.drum then return self:sampleDrum(event, sampleIndex) end
  local volume = envelopeVolume(
    event.volume or 0, event.fade or 0, event.elapsed)
  if event.noise then
    return self:sampleNoise(event.noiseParameter) * volume / 15 * 0.35
  end

  local register = event.register
  local frame = math.floor(event.elapsed * 60)
  if event.sweep then
    register = sweptRegister(register, event.sweep, event.elapsed)
    if not register then return 0 end
  elseif event.slide then
    local amount = math.min(1, frame / event.slide.frames)
    register = register + (event.slide.target - register) * amount
  elseif event.vibrato and frame >= event.vibrato.delay then
    local vibrato = event.vibrato
    local toggles = math.floor(
      (frame - vibrato.delay + 1) / (vibrato.rate + 1))
    if toggles > 0 then
      local low = bit.band(register, 0xFF)
      local high = bit.band(register, 0x700)
      if bit.band(toggles, 1) ~= 0 then
        register = high + math.min(0xFF, low + vibrato.above)
      else
        register = high + math.max(0, low - vibrato.below)
      end
    end
  end
  local frequency = 131072 / (2048 - math.min(register, 2047))
  if event.wave then frequency = frequency * 0.5 end
  local phase = self.phase
  self.phase = (phase + frequency / SAMPLE_RATE) % 1
  if event.wave then
    local wave = self.engine.waves[
      math.min(event.waveInstrument + 1, #self.engine.waves)]
    -- a def-local program may omit its wave table entirely
    if not wave then return 0 end
    local index = math.min(32, math.floor(phase * 32) + 1)
    return wave[index] * event.waveLevel * 0.55
  end
  local duty = event.duty
  if type(duty) == "table" then
    duty = duty[frame % 4 + 1]
  end
  return (phase < duty and 1 or -1) * volume / 15 * 0.5
end

local Engine = {}
Engine.__index = Engine

function Engine:noiseInstrument(number)
  -- a def-local drum wins over the ROM engine's table for that id
  local custom = self.customDrums and self.customDrums[number]
  if custom then return custom end
  local cached = self.noiseInstruments[number]
  if cached then return cached end

  local header = self.noiseHeaders[tostring(number)]
  local segments = {}
  if header then
    local spec = headerChannels(self.banks, header)[1]
    local address = spec and spec.address
    local ticks = 0
    for _ = 1, 64 do
      local command = romByte(self.banks, header.bank, address)
      address = address + 1
      if command == 0xFF then break end
      if command < 0x20 or command >= 0x30 then
        error(("unsupported drum command %02X at %02X:%04X")
          :format(command, header.bank, address - 1))
      end
      local packed = romByte(self.banks, header.bank, address)
      local parameter = romByte(self.banks, header.bank, address + 1)
      address = address + 2
      local duration = (bit.band(command, 0x0F) + 1) * FRAME_TICKS
      segments[#segments + 1] = {
        startSample = snapTicks(ticks),
        endSample = snapTicks(ticks + duration),
        volume = bit.rshift(packed, 4),
        fade = fadeValue(bit.band(packed, 0x0F)),
        parameter = parameter,
      }
      ticks = ticks + duration
    end
  end

  self.noiseInstruments[number] = segments
  return segments
end

local function readWaves(banks, audio, engineNumber)
  local spec = audio.waveBanks[tostring(engineNumber)]
  local waves = {}
  for wave = 0, 4 do
    local values = {}
    for byteIndex = 0, 15 do
      local packed = romByte(
        banks, spec.bank, spec.address + wave * 16 + byteIndex)
      values[#values + 1] = (bit.rshift(packed, 4) - 7.5) / 7.5
      values[#values + 1] = (bit.band(packed, 0x0F) - 7.5) / 7.5
    end
    waves[#waves + 1] = values
  end
  local values = {}
  for byteIndex = 0, 15 do
    local packed = romByte(
      banks, spec.bank, spec.address + 5 * 16 + byteIndex)
    values[#values + 1] = (bit.rshift(packed, 4) - 7.5) / 7.5
    values[#values + 1] = (bit.band(packed, 0x0F) - 7.5) / 7.5
  end
  for _ = 1, 4 do waves[#waves + 1] = values end
  return waves
end

-- def-local waves are authored either as raw 0-15 nibbles (the ROM's own
-- units) or as the -1..1 samples readWaves produces; the synth wants the
-- latter
local function normalizeWaves(source)
  local waves = {}
  for index, values in ipairs(source) do
    local nibbles = false
    for _, value in ipairs(values) do
      if value > 1 or value < -1 then nibbles = true break end
    end
    local wave = {}
    for position, value in ipairs(values) do
      wave[position] = nibbles and (value - 7.5) / 7.5 or value
    end
    waves[index] = wave
  end
  return waves
end

function Engine.new(data, header, options)
  options = options or {}
  local audio = data.audio or {}
  -- shape dispatch: a def-local chip program supplies its own channels and
  -- may supply its own waves/drums, falling back to a ROM engine's tables
  local chip = header.chip
  local banks = engineBanks(data, chip)
  local engineNumber = chip and (chip.engine or 1) or header.engine
  local waves
  if chip and chip.waves then
    waves = normalizeWaves(chip.waves)
  elseif chip then
    local ok, romWaves = pcall(readWaves, banks, audio, engineNumber)
    waves = ok and romWaves or {}
  else
    waves = readWaves(banks, audio, engineNumber)
  end
  local engine = setmetatable({
    banks = banks,
    tempo = 0x100,
    pan = 0xFF,
    waves = waves,
    noiseHeaders = audio.noiseHeaders
      and audio.noiseHeaders[tostring(engineNumber)] or {},
    customDrums = chip and chip.drums or nil,
    noiseInstruments = {},
    channels = {},
  }, Engine)
  for _, spec in ipairs(chip and chip.channels
      or headerChannels(banks, header)) do
    local frameTicks = options.frameTicks
    local hardware = (spec.number - 1) % 4 + 1
    if hardware == 4 then
      frameTicks = FRAME_TICKS
    elseif options.cryLength then
      frameTicks = 0x80 + options.cryLength
    end
    engine.channels[#engine.channels + 1] = Channel.new(engine, spec, {
      bank = chip and 0 or header.bank,
      sfx = options.sfx,
      allowLoops = options.allowLoops,
      frequencyOffset = options.frequencyOffset,
      frameTicks = frameTicks,
    })
  end
  return engine
end

function Engine:finished()
  for _, channel in ipairs(self.channels) do
    if not channel.ended or channel.event then return false end
  end
  return true
end

function Engine:sample()
  local value = 0
  for _, channel in ipairs(self.channels) do value = value + channel:sample() end
  return math.max(-1, math.min(1, value * 0.5))
end

function Engine:sampleStereo()
  local left, right = 0, 0
  for _, channel in ipairs(self.channels) do
    local value = channel:sample()
    local event = channel.event
    if not event or event.panLeft ~= false then left = left + value end
    if not event or event.panRight ~= false then right = right + value end
  end
  return math.max(-1, math.min(1, left * 0.5)),
    math.max(-1, math.min(1, right * 0.5))
end

function Engine:sampleChannel(number)
  local selected = 0
  for _, channel in ipairs(self.channels) do
    local value = channel:sample()
    if channel.number == number then selected = value end
  end
  return math.max(-1, math.min(1, selected * 0.5))
end

local function soundData(engine, samples, channels)
  local result = love.sound.newSoundData(samples, SAMPLE_RATE, 16, channels)
  for index = 0, samples - 1 do
    if channels == 2 then
      local left, right = engine:sampleStereo()
      result:setSample(index, 1, left)
      result:setSample(index, 2, right)
    else
      result:setSample(index, engine:sample())
    end
  end
  return result
end

-- Amortized queue fill.  The queue is deep (MUSIC_BUFFER_COUNT buffers, ~6s)
-- for stall tolerance, but synthesizing all of it at once -- which is what a
-- song change did -- renders ~6 seconds of Game Boy audio in a single frame:
-- that was the map-switch stutter (a new map's theme starts a new song).  So
-- cap how many buffers each fill renders.  Playback drains ~1 buffer every ~11
-- frames while update() tops up a few per frame, so the deep queue still ramps
-- to full within a fraction of a second and keeps its headroom -- it just gets
-- there gradually instead of all on the frame the song starts.
local MUSIC_FILL_INITIAL = 4  -- buffers rendered when a song first starts
local MUSIC_FILL_PER_CALL = 3 -- buffers rendered per update()/recovery tick

local function fillMusic(limit)
  local music = currentMusic
  if not music or music.engine:finished() then return end
  limit = limit or MUSIC_FILL_PER_CALL
  local free = music.source:getFreeBufferCount()
  while free > 0 and limit > 0 and not music.engine:finished() do
    music.source:queue(soundData(
      music.engine, MUSIC_BUFFER_SAMPLES, 2))
    free = free - 1
    limit = limit - 1
  end
end

function ChipAudio.playMusic(data, header, allowLoops)
  -- build before tearing down: a def that fails to compile (bad addresses,
  -- unreadable blob) must leave the outgoing song sounding
  local engine = Engine.new(data, header, { allowLoops = allowLoops })
  local ok, source = pcall(
    love.audio.newQueueableSource, SAMPLE_RATE, 16, 2, MUSIC_BUFFER_COUNT)
  if not ok then return nil, source end
  ChipAudio.stopMusic()
  currentMusic = { source = source, engine = engine }
  -- only a small starting cushion here; update() ramps the deep queue to full
  -- over the next frames so the song-start frame never renders the whole queue
  fillMusic(MUSIC_FILL_INITIAL)
  source:play()
  return source
end

-- Recover from an audio queue underrun caused by a long render stall.  This
-- is called after Music has handled intentional fanfare pauses, so it never
-- fights the normal pause/resume behavior.
function ChipAudio.ensureMusicPlaying()
  local music = currentMusic
  if not music or music.engine:finished() then return end
  local ok, playing = pcall(music.source.isPlaying, music.source)
  if ok and not playing then
    fillMusic(MUSIC_FILL_INITIAL)
    pcall(music.source.play, music.source)
  end
end

function ChipAudio.update()
  fillMusic()
end

function ChipAudio.stopMusic()
  if currentMusic and currentMusic.source then
    pcall(currentMusic.source.stop, currentMusic.source)
  end
  currentMusic = nil
end

-- hot reload: the next play re-reads programs.bin (a mod may have swapped
-- the file out from under the single-slot bank cache)
function ChipAudio.invalidate()
  ChipAudio.stopMusic()
  cachedProgramFile, cachedBanks = nil, nil
end

-- a stale song must not keep sounding past the flush that replaced its
-- program (20 §2 cache contract, chip music row)
Assets.register(ChipAudio.invalidate)

local function renderEffect(data, header, options)
  if not header then return nil end
  options = options or {}
  options.sfx = true
  options.allowLoops = false
  local engine = Engine.new(data, header, options)
  local maximum = SAMPLE_RATE * 5
  local values = {}
  local count = 0
  while count < maximum and not engine:finished() do
    count = count + 1
    values[count] = engine:sample()
  end
  if count < math.floor(SAMPLE_RATE / 100) then return nil end
  local result = love.sound.newSoundData(count, SAMPLE_RATE, 16, 1)
  for index = 1, count do result:setSample(index - 1, values[index]) end
  return love.audio.newSource(result, "static")
end

function ChipAudio._renderMusicForTest(data, header, seconds)
  local engine = Engine.new(data, header, { allowLoops = true })
  return soundData(engine, math.floor(seconds * SAMPLE_RATE), 2)
end

function ChipAudio._renderMusicChannelForTest(data, header, seconds, number)
  local engine = Engine.new(data, header, { allowLoops = true })
  local samples = math.floor(seconds * SAMPLE_RATE)
  local result = love.sound.newSoundData(samples, SAMPLE_RATE, 16, 1)
  for index = 0, samples - 1 do
    result:setSample(index, engine:sampleChannel(number))
  end
  return result
end

function ChipAudio._traceFirstMusicSampleForTest(data, header)
  local engine = Engine.new(data, header, { allowLoops = true })
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
  local engine = Engine.new(data, header, {
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
  local engine = Engine.new(data, header, {
    sfx = true,
    allowLoops = false,
  })
  return soundData(engine, math.floor(seconds * SAMPLE_RATE), 1)
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

return ChipAudio
