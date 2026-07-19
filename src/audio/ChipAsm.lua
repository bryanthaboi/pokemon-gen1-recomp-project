-- Authoring DSL for the channel bytecode ChipAudio's Channel:nextEvent
-- decodes: note-event Lua tables in, a self-contained program blob out.
-- The blob is mounted as pseudo-bank 0 by ChipAudio, so addresses are based
-- at 0x4000 exactly like the ROM's own 0x4000-window programs.
--
-- Two passes: the first sizes every event and records where each label and
-- each event index lands, the second emits bytes with call/loop targets
-- resolved.  Nothing here touches love.*, so mods assemble at load time and
-- headless tools assemble without a graphics context.

local ChipAsm = {}

local BASE_ADDRESS = 0x4000
local FRAME_TICKS = 256

local NOTES = {
  C = 0, ["C#"] = 1, Db = 1, D = 2, ["D#"] = 3, Eb = 3, E = 4,
  F = 5, ["F#"] = 6, Gb = 6, G = 7, ["G#"] = 8, Ab = 8, A = 9,
  ["A#"] = 10, Bb = 10, B = 11,
}

-- mirrors ChipAudio's snapTicks so authored drums land on the same sample
-- grid as the ROM's own drum tables
local function snapTicks(ticks)
  return math.floor((ticks * 735 + 256) / 512)
end

-- ------- validation

local Cursor = {}
Cursor.__index = Cursor

local function cursor(channel, scope)
  return setmetatable({ channel = channel, scope = scope, index = 0 }, Cursor)
end

function Cursor:fail(message)
  error(("ChipAsm: channel %d %sevent %d: %s")
    :format(self.channel, self.scope, self.index, message), 0)
end

function Cursor:int(value, low, high, what)
  if type(value) ~= "number" or value ~= math.floor(value) then
    self:fail(("%s must be an integer, got %s"):format(what, tostring(value)))
  end
  if value < low or value > high then
    self:fail(("%s out of range %d-%d: %d"):format(what, low, high, value))
  end
  return value
end

function Cursor:length(value)
  return self:int(value or 1, 1, 16, "len")
end

-- the fade nibble is signed: bit 3 set means a decay of the low three bits
function Cursor:fade(value)
  value = self:int(value or 0, -7, 7, "fade")
  if value < 0 then return 8 - value end
  return value
end

function Cursor:pitch(event)
  if event.pitch ~= nil then return self:int(event.pitch, 0, 11, "pitch") end
  local name = event.note
  if type(name) ~= "string" then
    self:fail("note must be a name or an explicit pitch")
  end
  local pitch = NOTES[name]
  if not pitch then self:fail(("unknown note %q"):format(name)) end
  return pitch
end

-- ------- pass 1: events to sized chunks
-- a chunk is a byte, or a two-byte reference to a label / event index that
-- pass 2 resolves once every channel's size is known

local function reference(cur, target)
  return {
    label = target, offsets = cur.offsets, ref = cur, index = cur.index,
  }
end

local function emitters(cur, hw)
  local E = {}

  function E.label() end

  function E.note(event, out)
    if hw == 4 then cur:fail("channel 4 plays drums, not notes") end
    out[#out + 1] = cur:pitch(event) * 16 + cur:length(event.len) - 1
  end

  function E.rest(event, out)
    local len = event.rest == true and event.len or event.rest
    out[#out + 1] = 0xC0 + cur:length(len) - 1
  end

  function E.drum(event, out)
    if hw ~= 4 then cur:fail("drums only play on channel 4") end
    local id = cur:int(event.drum, 0, 255, "drum")
    local len = cur:length(event.len) - 1
    -- ids from 11 up do not fit the note nibble and carry an extra byte
    if id >= 11 then
      out[#out + 1] = 0xB0 + len
      out[#out + 1] = id
    else
      out[#out + 1] = id * 16 + len
    end
  end

  -- the interpreter reads the packed byte per hardware channel: none on
  -- noise, wave level plus instrument on channel 3, volume plus fade on the
  -- two square channels
  function E.notetype(event, out)
    local spec = event.notetype
    out[#out + 1] = 0xD0 + cur:int(spec.speed or 12, 0, 15, "speed")
    if hw == 4 then return end
    if hw == 3 then
      out[#out + 1] = cur:int(spec.waveLevel or 0, 0, 3, "waveLevel") * 16
        + cur:int(spec.waveInstrument or 0, 0, 15, "waveInstrument")
    else
      out[#out + 1] = cur:int(spec.volume or 0, 0, 15, "volume") * 16
        + cur:fade(spec.fade)
    end
  end

  function E.octave(event, out)
    out[#out + 1] = 0xE0 + 8 - cur:int(event.octave, 1, 8, "octave")
  end

  function E.perfectPitch(_, out)
    out[#out + 1] = 0xE8
  end

  function E.vibrato(event, out)
    local spec = event.vibrato
    out[#out + 1] = 0xEA
    out[#out + 1] = cur:int(spec.delay or 0, 0, 255, "vibrato delay")
    out[#out + 1] = cur:int(spec.depth or 0, 0, 15, "vibrato depth") * 16
      + cur:int(spec.rate or 0, 0, 15, "vibrato rate")
  end

  function E.slide(event, out)
    local spec = event.slide
    out[#out + 1] = 0xEB
    out[#out + 1] = cur:int(spec.len or 0, 0, 255, "slide len")
    out[#out + 1] = (8 - cur:int(spec.octave or 4, 1, 8, "slide octave")) * 16
      + cur:pitch(spec)
  end

  function E.duty(event, out)
    out[#out + 1] = 0xEC
    out[#out + 1] = cur:int(event.duty, 0, 3, "duty")
  end

  function E.dutyPattern(event, out)
    local packed = 0
    for slot = 1, 4 do
      packed = packed * 4 + cur:int(event.dutyPattern[slot], 0, 3, "dutyPattern")
    end
    out[#out + 1] = 0xFC
    out[#out + 1] = packed
  end

  function E.tempo(event, out)
    local tempo = cur:int(event.tempo, 0, 0xFFFF, "tempo")
    out[#out + 1] = 0xED
    out[#out + 1] = math.floor(tempo / 0x100)
    out[#out + 1] = tempo % 0x100
  end

  function E.pan(event, out)
    out[#out + 1] = 0xEE
    out[#out + 1] = cur:int(event.pan, 0, 255, "pan")
  end

  function E.executeMusic(_, out)
    out[#out + 1] = 0xF8
  end

  function E.call(event, out)
    out[#out + 1] = 0xFD
    out[#out + 1] = reference(cur, event.call)
  end

  function E.ret(_, out)
    out[#out + 1] = 0xFF
  end

  function E.loop(event, out)
    out[#out + 1] = 0xFE
    out[#out + 1] = cur:int(event.loop.count or 0, 0, 255, "loop count")
    out[#out + 1] = reference(cur, event.loop.to)
  end

  -- sfx-only: the 0x20-0x2F note form carries its own volume and fade plus
  -- either a raw frequency register or a noise parameter
  function E.squareNote(event, out)
    local spec = event.squareNote
    local register = cur:int(spec.frequency or 0, 0, 0x7FF, "frequency")
    out[#out + 1] = 0x20 + cur:length(spec.len) - 1
    out[#out + 1] = cur:int(spec.volume or 0, 0, 15, "volume") * 16
      + cur:fade(spec.fade)
    out[#out + 1] = register % 0x100
    out[#out + 1] = math.floor(register / 0x100)
  end

  function E.noiseNote(event, out)
    local spec = event.noiseNote
    out[#out + 1] = 0x20 + cur:length(spec.len) - 1
    out[#out + 1] = cur:int(spec.volume or 0, 0, 15, "volume") * 16
      + cur:fade(spec.fade)
    out[#out + 1] = cur:int(spec.parameter or 0, 0, 255, "parameter")
  end

  function E.pitchSweep(event, out)
    local spec = event.pitchSweep
    out[#out + 1] = 0x10
    out[#out + 1] = cur:int(spec.pace or 0, 0, 7, "sweep pace") * 16
      + (spec.subtract and 8 or 0)
      + cur:int(spec.shift or 0, 0, 7, "sweep shift")
  end

  return E
end

-- the event key that names the command, checked in a fixed order so an
-- event carrying `len` alongside `note` is still a note
local KEYS = {
  "label", "note", "pitch", "rest", "drum", "notetype", "octave",
  "perfectPitch", "vibrato", "slide", "duty", "dutyPattern", "tempo", "pan",
  "executeMusic", "call", "ret", "loop", "squareNote", "noiseNote",
  "pitchSweep",
}

-- an unresolved reference is one chunk but two bytes, so offsets are counted
-- rather than read off the chunk list's length
local function byteSize(chunks)
  local size = 0
  for _, chunk in ipairs(chunks) do
    size = size + (type(chunk) == "table" and 2 or 1)
  end
  return size
end

local function assembleStream(program, cur, E, out, offsets, labels)
  cur.offsets = offsets
  for index, event in ipairs(program) do
    cur.index = index
    if type(event) ~= "table" then cur:fail("event must be a table") end
    local offset = byteSize(out)
    offsets[index] = offset
    local kind
    for _, key in ipairs(KEYS) do
      if event[key] ~= nil then kind = key break end
    end
    if not kind then cur:fail("no command in event") end
    if kind == "pitch" then kind = "note" end
    if kind == "label" then labels[event.label] = offset end
    E[kind](event, out)
  end
end

-- a stream that cannot fall off its end needs no terminator; anything else
-- gets the endchannel byte the interpreter stops on
local function endsItself(program)
  local last = program[#program]
  if type(last) ~= "table" then return false end
  if last.ret then return true end
  return last.loop ~= nil and (last.loop.count or 0) == 0
end

local function assembleChannel(spec, hw, number, prelude)
  local cur = cursor(number, "")
  local out, offsets, labels = {}, {}, {}
  for _, byte in ipairs(prelude or {}) do out[#out + 1] = byte end
  local program = spec.program or {}
  assembleStream(program, cur, emitters(cur, hw), out, offsets, labels)
  if not endsItself(program) then out[#out + 1] = 0xFF end
  -- subroutines follow the body so every call target is inside the blob
  local names = {}
  for name in pairs(spec.subroutines or {}) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    labels[name] = byteSize(out)
    local sub = spec.subroutines[name]
    local subCursor = cursor(number, ("subroutine %q "):format(name))
    assembleStream(sub, subCursor, emitters(subCursor, hw), out, {}, labels)
    if not endsItself(sub) then out[#out + 1] = 0xFF end
  end
  return { bytes = out, labels = labels }
end

-- ------- pass 2: resolve the references and pack the blob

local function targetAddress(chunk, labels, base)
  local target = chunk.label
  local offset
  if type(target) == "number" then
    offset = chunk.offsets[target]
    if not offset then
      chunk.ref.index = chunk.index
      chunk.ref:fail(("loop target event %d does not exist"):format(target))
    end
  else
    offset = labels[target]
    if not offset then
      chunk.ref.index = chunk.index
      chunk.ref:fail(("unknown label %q"):format(tostring(target)))
    end
  end
  return offset + base
end

local function pack(channels, blobBase)
  local pieces = {}
  for _, channel in ipairs(channels) do
    local base = channel.base + blobBase
    for _, byte in ipairs(channel.bytes) do
      if type(byte) == "table" then
        local address = targetAddress(byte, channel.labels, base)
        pieces[#pieces + 1] = string.char(address % 0x100)
        pieces[#pieces + 1] = string.char(math.floor(address / 0x100) % 0x100)
      else
        pieces[#pieces + 1] = string.char(byte % 0x100)
      end
    end
  end
  return table.concat(pieces)
end

-- friendly drum rows to the segment lists Engine:noiseInstrument caches
local function drumSegments(rows)
  local drums = {}
  for id, program in pairs(rows) do
    local segments, ticks = {}, 0
    for index, row in ipairs(program) do
      local length = row.len or 1
      if type(length) ~= "number" or length < 1 or length > 16 then
        error(("ChipAsm: drum %s row %d: len out of range 1-16")
          :format(tostring(id), index), 0)
      end
      local duration = length * FRAME_TICKS
      segments[#segments + 1] = {
        startSample = snapTicks(ticks),
        endSample = snapTicks(ticks + duration),
        volume = row.volume or 0,
        fade = row.fade or 0,
        parameter = row.parameter or 0,
      }
      ticks = ticks + duration
    end
    drums[id] = segments
  end
  return drums
end

local function assemble(spec, sfx)
  local channels, size = {}, 0
  for index, channelSpec in ipairs(spec.channels or {}) do
    local hw = channelSpec.hw or index
    if type(hw) ~= "number" or hw < 1 or hw > 4 then
      error(("ChipAsm: channel %d: hw must be 1-4"):format(index), 0)
    end
    -- the global tempo rides on the first channel, the way the ROM's own
    -- songs write it
    local prelude
    if index == 1 and spec.tempo and not sfx then
      local tempo = cursor(index, ""):int(spec.tempo, 0, 0xFFFF, "tempo")
      prelude = { 0xED, math.floor(tempo / 0x100), tempo % 0x100 }
    end
    local built = assembleChannel(channelSpec, hw, index, prelude)
    built.base = size
    -- effect programs live on channels 5-8, which is how the interpreter
    -- tells an effect's command set from a song's
    built.number = sfx and hw + 4 or hw
    size = size + byteSize(built.bytes)
    channels[#channels + 1] = built
  end
  local blob = pack(channels, BASE_ADDRESS)
  local layout = {}
  for _, channel in ipairs(channels) do
    layout[#layout + 1] = {
      number = channel.number,
      address = BASE_ADDRESS + channel.base,
    }
  end
  return {
    chip = {
      blob = blob,
      channels = layout,
      waves = spec.waves,
      drums = spec.drums and drumSegments(spec.drums) or nil,
      engine = spec.engine or 1,
    },
  }
end

function ChipAsm.song(spec)
  return assemble(spec, false)
end

function ChipAsm.sfx(spec)
  return assemble(spec, true)
end

return ChipAsm
