-- Audio modding (M9): per-definition shape dispatch in Music/Sound, failure
-- isolation instead of a latching global disable, the granular
-- sfx/cries/map_songs merge, the ChipAsm assembler and its def-local blob
-- mode in ChipAudio, the song-literal tables and their fallbacks, and the
-- music.select hook plus the audio events.
package.path = "./?.lua;./?/init.lua;" .. package.path

local S = require("tests.harness").suite("mod audio")
local check = S.check

-- ------- love audio stub
-- Records every source so the tests can assert on which branch built it;
-- string paths only resolve when listed in `assets`, which is how a broken
-- definition is simulated.

local love = _G.love or {}
_G.love = love
local savedAudio, savedSound = love.audio, love.sound

local assets = {
  ["assets/theme.ogg"] = true,
  ["assets/theme_loop.ogg"] = true,
  ["assets/other.ogg"] = true,
  ["assets/beep.wav"] = true,
  ["assets/chime.ogg"] = true,
  ["assets/cry.ogg"] = true,
}

local sources = {}

local Source = {}
Source.__index = Source
function Source:play() self.playing = true self.plays = self.plays + 1 end
function Source:stop() self.playing = false end
function Source:isPlaying() return self.playing end
function Source:pause() self.playing = false end
function Source:setLooping(value) self.looping = value end
function Source:setVolume(value) self.volume = value end
function Source:setPitch(value) self.pitch = value end
function Source:setFilter() end
function Source:getDuration() return 1 end
function Source:getFreeBufferCount() return self.free end
function Source:queue() self.free = math.max(0, self.free - 1) end

local function newSource(what, mode)
  if type(what) == "string" and not assets[what] then
    error("could not open file " .. what, 0)
  end
  local src = setmetatable({
    file = what, mode = mode, plays = 0, free = 0, queueable = false,
  }, Source)
  sources[#sources + 1] = src
  return src
end

local SoundData = {}
SoundData.__index = SoundData
function SoundData:setSample(index, a, b)
  self.samples[index] = b or a
end
function SoundData:getSample(index) return self.samples[index] or 0 end
function SoundData:getSampleCount() return self.count end

love.audio = {
  newSource = newSource,
  newQueueableSource = function()
    local src = setmetatable({
      plays = 0, free = 32, queueable = true,
    }, Source)
    sources[#sources + 1] = src
    return src
  end,
}
love.sound = {
  newSoundData = function(count, rate, bits, channels)
    return setmetatable({
      samples = {}, count = count, rate = rate, bits = bits,
      channels = channels,
    }, SoundData)
  end,
}

local function lastSource()
  return sources[#sources]
end

local function resetSources()
  for index = #sources, 1, -1 do sources[index] = nil end
end

local ChipAsm = require("src.audio.ChipAsm")
local ChipAudio = require("src.core.ChipAudio")
local Music = require("src.core.Music")
local Sound = require("src.core.Sound")
local Logger = require("src.core.Logger")
local Loader = require("src.mods.Loader")
local Runtime = require("src.mods.Runtime")

local savedEvents, savedHooks = Runtime.events, Runtime.hooks
local savedErrors = Runtime.errors

local function loggedCount(fragment)
  local count = 0
  for _, line in ipairs(Logger.history) do
    if line:find(fragment, 1, true) then count = count + 1 end
  end
  return count
end

-- ------- ChipAsm: the encoding oracle
-- Byte-for-byte expectations read off the command table Channel:nextEvent
-- decodes, so a change in either one breaks this.

local dslSong = ChipAsm.song{
  tempo = 0x100,
  channels = {
    { hw = 1,
      program = {
        { duty = 2 },
        { notetype = { speed = 12, volume = 12, fade = 1 } },
        { octave = 4 },
        { label = "body" },
        { note = "C#", len = 4 },
        { rest = 2 },
        { vibrato = { delay = 6, depth = 3, rate = 4 } },
        { slide = { len = 2, octave = 4, note = "E" } },
        { call = "riff" },
        { loop = { count = 0, to = "body" } },
      },
      subroutines = { riff = { { note = "G", len = 2 }, { ret = true } } } },
    { hw = 4, program = { { drum = 3, len = 8 }, { loop = { count = 0, to = 1 } } } },
  },
}

local function hex(blob)
  local out = {}
  for index = 1, #blob do out[#out + 1] = ("%02X"):format(blob:byte(index)) end
  return table.concat(out, " ")
end

check(hex(dslSong.chip.blob) ==
  "ED 01 00 EC 02 DC C1 E4 13 C1 EA 06 34 EB 02 44 FD 17 40 FE 00 08 40 " ..
  "71 FF 37 FE 00 19 40",
  "ChipAsm encodes the documented program byte for byte")
check(dslSong.chip.channels[1].number == 1
  and dslSong.chip.channels[1].address == 0x4000,
  "first channel is based at the 0x4000 window")
check(dslSong.chip.channels[2].number == 4
  and dslSong.chip.channels[2].address == 0x4019,
  "the second channel starts after the first one's bytes")
check(dslSong.chip.engine == 1, "engine defaults to 1")

-- an sfx program lives on channels 5-8 so the interpreter reads the effect
-- command set
local dslSfx = ChipAsm.sfx{
  channels = {
    { hw = 1, program = {
      { pitchSweep = { pace = 5, subtract = true, shift = 2 } },
      { squareNote = { len = 4, volume = 15, fade = 1, frequency = 0x123 } },
    } },
    { hw = 4, program = {
      { noiseNote = { len = 2, volume = 15, fade = -1, parameter = 0x44 } },
    } },
  },
}
check(hex(dslSfx.chip.blob) == "10 5A 23 F1 23 01 FF 21 F9 44 FF",
  "ChipAsm.sfx encodes sweep, square and noise notes")
check(dslSfx.chip.channels[1].number == 5
  and dslSfx.chip.channels[2].number == 8,
  "sfx channels are numbered 5-8")

-- terminator: a stream that can fall off its end gets the endchannel byte,
-- one that loops forever does not
check(ChipAsm.song{ channels = { { hw = 1, program = { { note = "C" } } } } }
  .chip.blob == string.char(0x00, 0xFF),
  "a finite stream is terminated with endchannel")

-- errors name the channel and the event index
local function failsWith(fragment, fn)
  local ok, err = pcall(fn)
  check(not ok, "expected a ChipAsm error: " .. fragment)
  check(tostring(err):find(fragment, 1, true),
    ("error %q does not mention %q"):format(tostring(err), fragment))
end

failsWith("channel 1 event 2: unknown note \"H\"", function()
  ChipAsm.song{ channels = { { hw = 1,
    program = { { note = "C" }, { note = "H" } } } } }
end)
failsWith("channel 2 event 1: len out of range 1-16", function()
  ChipAsm.song{ channels = {
    { hw = 1, program = { { note = "C" } } },
    { hw = 2, program = { { note = "C", len = 40 } } } } }
end)
failsWith("channel 1 event 1: drums only play on channel 4", function()
  ChipAsm.song{ channels = { { hw = 1, program = { { drum = 1 } } } } }
end)
failsWith("channel 1 event 3: unknown label \"nope\"", function()
  ChipAsm.song{ channels = { { hw = 1, program = {
    { note = "C" }, { note = "D" }, { call = "nope" } } } } }
end)
failsWith("channel 1 subroutine \"riff\" event 1: octave out of range", function()
  ChipAsm.song{ channels = { { hw = 1, program = { { call = "riff" } },
    subroutines = { riff = { { octave = 12 } } } } } }
end)

-- friendly drum rows become the segment shape Engine:noiseInstrument caches
local drumDef = ChipAsm.song{
  channels = { { hw = 4, program = { { drum = 3, len = 4 } } } },
  drums = { [3] = { { len = 4, volume = 13, fade = 2, parameter = 0x42 } } },
}
local segment = drumDef.chip.drums[3][1]
check(segment.startSample == 0 and segment.volume == 13
  and segment.fade == 2 and segment.parameter == 0x42,
  "drum rows assemble into cached noise segments")
check(segment.endSample > 0, "drum segment spans samples")

-- ------- ChipAudio: def-local blobs render without touching programs.bin

local blobData = { audio = {} }

local blobSong = ChipAsm.song{
  tempo = 0x100,
  channels = { { hw = 1, program = {
    { duty = 2 },
    { notetype = { speed = 12, volume = 12, fade = 0 } },
    { octave = 4 },
    { label = "body" },
    { note = "C", len = 8 },
    { note = "E", len = 8 },
    { loop = { count = 0, to = "body" } },
  } } },
}
local rendered = ChipAudio._renderMusicForTest(blobData, blobSong, 0.1)
local nonzero = 0
for index = 0, rendered:getSampleCount() - 1 do
  if rendered:getSample(index) ~= 0 then nonzero = nonzero + 1 end
end
check(nonzero > 0, "a blob def renders nonzero audio with no ROM banks")

local blobTrace = ChipAudio._traceFirstMusicSampleForTest(blobData, blobSong)
check(blobTrace[1].register == 1797 and blobTrace[1].volume == 12,
  "the blob's first note decodes to the C4 register")

-- def-local waves are honored over the ROM's wave banks
local flatWave = {}
for index = 1, 32 do flatWave[index] = 1 end
local waveSong = ChipAsm.song{
  channels = { { hw = 3, program = {
    { notetype = { speed = 12, waveLevel = 1, waveInstrument = 0 } },
    { octave = 4 },
    { note = "C", len = 8 },
  } } },
  waves = { flatWave },
}
local waveTrace = ChipAudio._traceFirstMusicSampleForTest(blobData, waveSong)
check(math.abs(waveTrace[1].value - 0.55) < 1e-9,
  "def-local waves drive the wave channel")

-- def-local drums are honored over the ROM's noise headers
local drumTrace = ChipAudio._traceFirstMusicSampleForTest(blobData, drumDef)
check(drumTrace[1].drumSegments == 1, "def-local drums reach the noise channel")

-- ------- data fixtures

local chipSong = ChipAsm.song{
  channels = { { hw = 1, program = {
    { notetype = { speed = 12, volume = 12, fade = 0 } },
    { octave = 4 },
    { note = "C", len = 8 },
    { loop = { count = 0, to = 1 } },
  } } },
}

local function fixtureData()
  return {
    audio = {
      songs = {
        Music_Chip = chipSong,
        Music_File = { file = "assets/theme.ogg" },
        Music_Split = { file = "assets/theme.ogg",
                        loopFile = "assets/theme_loop.ogg" },
        Music_Other = { file = "assets/other.ogg" },
        Music_Broken = { file = "assets/missing.ogg" },
        Music_BikeRiding = { file = "assets/other.ogg" },
        Music_PalletTown = { file = "assets/theme.ogg" },
      },
      sfx = {
        Beep = "assets/beep.wav",
        Chime = { file = "assets/chime.ogg", fanfare = true },
        Level_Up = "assets/beep.wav",
        Broken = { file = "assets/missing.ogg" },
        Chip_Sfx = ChipAsm.sfx{ channels = { { hw = 1, program = {
          { squareNote = { len = 8, volume = 15, fade = 1, frequency = 0x600 } },
        } } } },
      },
      cries = {},
      mapSongs = { PALLET_TOWN = "Music_PalletTown" },
      battle = { wild = "Music_Chip", wildWin = "Music_File" },
    },
  }
end

local function reset(data)
  Sound.invalidate()
  Music.reload()
  resetSources()
  return data
end

-- ------- dispatch: the branch follows the definition, not a global flag

local data = reset(fixtureData())

Music.play(data, "Music_Chip")
check(lastSource() and lastSource().queueable,
  "a chip def streams through ChipAudio")
check(lastSource().playing, "the chip song started")
local chipSource = lastSource()

Music.play(data, "Music_File")
check(lastSource() and not lastSource().queueable
  and lastSource().file == "assets/theme.ogg",
  "a file def becomes a stream source")
check(not chipSource.playing, "the outgoing chip song was stopped")
check(lastSource().looping == true, "a looping file song loops")

-- intro/loop chaining now works regardless of import mode
Music.play(data, "Music_Split")
local intro = sources[#sources - 1]
local body = sources[#sources]
check(intro.file == "assets/theme.ogg" and body.file == "assets/theme_loop.ogg",
  "a split def loads both files")
check(intro.looping == false and body.looping == true,
  "the intro plays once and the body loops")
check(intro.playing and not body.playing, "the loop body waits for the intro")
intro.playing = false
Music.update(data)
check(body.playing, "update() chains the intro into the loop body")

-- a file song never latches chip playback off for the songs around it
Music.play(data, "Music_Chip")
check(lastSource().queueable and lastSource().playing,
  "a chip song still plays after a file song")
check(not body.playing, "the outgoing file song was stopped")

-- sfx shape dispatch
check(Sound.play(data, "Beep") == nil, "Sound.play returns nothing")
check(lastSource().file == "assets/beep.wav", "a bare string sfx is a static source")
resetSources()
Sound.play(data, "Chip_Sfx")
check(lastSource() and lastSource().mode == "static"
  and type(lastSource().file) == "table",
  "a chip sfx renders to a static source")

-- ------- failure isolation: a bad def costs one log line, nothing else

data = reset(fixtureData())
Music.play(data, "Music_File")
local playing = lastSource()
local before = loggedCount("bad song def")
Music.play(data, "Music_Broken")
Music.play(data, "Music_File")
Music.play(data, "Music_Broken")
check(loggedCount("bad song def") == before + 1,
  "a broken song def is logged exactly once")
check(playing.playing, "the previous song keeps playing through a bad def")
Music.play(data, "Music_Other")
check(lastSource().file == "assets/other.ogg" and lastSource().playing,
  "a bad def does not disable the rest of the music")

local sfxBefore = loggedCount("bad sfx def")
Sound.play(data, "Broken")
Sound.play(data, "Broken")
check(loggedCount("bad sfx def") == sfxBefore + 1,
  "a broken sfx def is logged exactly once")
resetSources()
Sound.play(data, "Beep")
check(lastSource() and lastSource().file == "assets/beep.wav",
  "a bad sfx does not disable the rest of the effects")

-- ------- cries: every authoring variant plays

data = reset(fixtureData())
data.audio.cries.RHYDON = {
  header = { address = 0x4000, bank = 2, engine = 1 }, pitch = 0, length = 0,
}
data.audio.cries.CHIPMON = { chip = ChipAsm.sfx{ channels = { { hw = 1,
  program = { { squareNote = { len = 8, volume = 15, fade = 1,
                               frequency = 0x600 } } } } } }.chip,
  pitch = 0, length = 0 }
data.audio.cries.SHELLORD = { base = "CHIPMON", pitch = 0x2A, length = 0x50 }
data.audio.cries.FILEMON = { file = "assets/cry.ogg", pitch = 1.1 }
data.audio.cries.CHAINMON = { base = "SHELLORD" }

check(Sound.playCry(data, "CHIPMON"), "a chip cry plays")
check(Sound.playCry(data, "SHELLORD"), "a derived cry plays")
check(Sound.playCry(data, "CHAINMON"), "a derived cry chain resolves")
local fileCry = Sound.playCry(data, "FILEMON")
check(fileCry and fileCry.file == "assets/cry.ogg", "a file cry plays")
check(fileCry.pitch == 1.1, "a file cry honors its playback rate")
check(Sound.playCry(data, "NOBODY") == nil, "an unregistered species is silent")

-- GROWL/ROAR layer their own tempo shift on top of any cry shape
Sound.playMoveCry(data, "FILEMON", 0xC0)
check(math.abs(fileCry.pitch - 256 / (128 + 0xC0)) < 1e-9,
  "playMoveCry layers the move's tempo shift onto a file cry")

data.audio.cries.ORPHAN = { base = "MISSING" }
local cryBefore = loggedCount("bad cry def")
check(Sound.playCry(data, "ORPHAN") == nil, "a dangling base cry is silent")
check(loggedCount("bad cry def") == cryBefore + 1,
  "a dangling base cry is logged once")

-- ------- song literals: data tables win, module fallbacks preserve vanilla

data = reset(fixtureData())
check(Music.special(data, "title") == "Music_TitleScreen",
  "special song roles fall back to the vanilla labels")
check(Music.special(data, "bike") == "Music_BikeRiding",
  "the bike role falls back to Music_BikeRiding")
Music.playMap(data, "PALLET_TOWN", true, false)
check(lastSource().file == "assets/other.ogg",
  "the fallback outdoor set engages the bike theme")

data = reset(fixtureData())
data.audio.special = { bike = "Music_File" }
data.audio.outdoorSongs = { Music_PalletTown = true }
Music.playMap(data, "PALLET_TOWN", true, false)
check(lastSource().file == "assets/theme.ogg",
  "a renamed bike theme engages on outdoor maps")
check(Music.special(data, "title") == "Music_TitleScreen",
  "roles the data table omits still fall back")

data = reset(fixtureData())
data.audio.outdoorSongs = {}
Music.playMap(data, "PALLET_TOWN", true, false)
check(lastSource().file == "assets/theme.ogg",
  "a map outside the outdoor set keeps its own theme on the bike")

-- fanfare ducking: the shared table or the definition's own flag
data = reset(fixtureData())
local ducked = {}
local realDuck = Music.duckForFanfare
Music.duckForFanfare = function(src) ducked[#ducked + 1] = src end
Sound.play(data, "Level_Up")
check(#ducked == 1, "a vanilla fanfare ducks the music")
Sound.play(data, "Chime")
check(#ducked == 2, "a def with fanfare = true ducks without a table edit")
Sound.play(data, "Beep")
check(#ducked == 2, "an ordinary sfx does not duck")
data.audio.fanfares = { Beep = true }
Sound.invalidate()
Sound.play(data, "Beep")
check(#ducked == 3, "data.audio.fanfares supersedes the fallback table")
Music.duckForFanfare = realDuck

-- ------- cache invalidation

data = reset(fixtureData())
Sound.play(data, "Beep")
local firstBeep = lastSource()
Sound.play(data, "Beep")
check(lastSource() == firstBeep, "sources are cached across plays")
Sound.invalidate("Beep")
Sound.play(data, "Beep")
check(lastSource() ~= firstBeep, "Sound.invalidate drops the cached source")

data = reset(fixtureData())
Music.play(data, "Music_Broken")
check(#sources == 0, "a broken def creates no source")
data.audio.songs.Music_Broken = { file = "assets/other.ogg" }
Music.play(data, "Music_Broken")
check(#sources == 0, "a failed label stays negatively cached")
Music.reload()
Music.play(data, "Music_Broken")
check(lastSource() and lastSource().file == "assets/other.ogg",
  "Music.reload re-resolves a repaired def")
ChipAudio.invalidate()

-- ------- the music.select hook and the audio events

local events = require("src.mods.Events").new()
local hooks = require("src.mods.Hooks").new()
Runtime.install(events, hooks)

data = reset(fixtureData())
check(not Runtime.wantsHook("music.select"),
  "with no wrapper the hook builds no context")

local seen = {}
hooks:wrap("music.select", function(nextLink, song, ctx)
  seen[#seen + 1] = { song = song, reason = ctx.reason, mapId = ctx.mapId,
                      kind = ctx.kind, trainerId = ctx.trainerId,
                      onBike = ctx.onBike }
  return nextLink(song, ctx)
end, nil, "test")

Music.playMap(data, "PALLET_TOWN", false, false)
check(seen[1].reason == "map" and seen[1].mapId == "PALLET_TOWN"
  and seen[1].song == "Music_PalletTown",
  "playMap reaches the hook with the map context")
Music.playBattle(data, "wild", "OPP_RIVAL3")
check(seen[2].reason == "battle" and seen[2].kind == "wild"
  and seen[2].trainerId == "OPP_RIVAL3",
  "playBattle threads the battle kind and trainer")
Music.playVictory(data, "wild")
check(seen[3].reason == "victory" and seen[3].kind == "wild",
  "playVictory reaches the hook")
Music.playOnce(data, "Music_Other")
check(seen[4].reason == "once", "playOnce reaches the hook")
Music.play(data, "Music_Split")
check(seen[5].reason == "direct", "a direct play defaults to the direct reason")

-- returning nil silences the cue; returning a label plays that label
Music.reload()
resetSources()
hooks:removeOwner("test")
hooks:wrap("music.select", function() return nil end, nil, "silencer")
Music.play(data, "Music_File")
check(#sources == 0, "a hook returning nil silences the cue")
hooks:removeOwner("silencer")

hooks:wrap("music.select", function(nextLink, song, ctx)
  if song == "Music_File" then return nextLink("Music_Other", ctx) end
  return nextLink(song, ctx)
end, nil, "swap")
Music.play(data, "Music_File")
check(lastSource().file == "assets/other.ogg", "a hook may swap the label")
-- the swapped label is what dedupe compares, so re-asking still restarts
-- nothing but a genuinely different choice does
Music.play(data, "Music_Chip")
check(lastSource().queueable, "an unswapped label still plays")

-- a throwing wrapper is skipped and the chain continues
hooks:wrap("music.select", function() error("boom", 0) end, nil, "thrower")
Music.reload()
resetSources()
Music.play(data, "Music_File")
check(lastSource() and lastSource().file == "assets/other.ogg",
  "a throwing wrapper is skipped and the surviving chain still runs")
hooks:removeOwner("thrower")
hooks:removeOwner("swap")

-- events
Music.reload()
resetSources()
local started, stopped, played = {}, {}, {}
events:on("music.started", function(p) started[#started + 1] = p end, nil, "test")
events:on("music.stopped", function(p) stopped[#stopped + 1] = p end, nil, "test")
events:on("sound.played", function(p) played[#played + 1] = p end, nil, "test")

Music.playMap(data, "PALLET_TOWN", false, false)
check(started[1] and started[1].song == "Music_PalletTown"
  and started[1].reason == "map" and started[1].chip == false,
  "music.started carries the song, reason and chip flag")
Music.play(data, "Music_Chip")
check(started[2].previous == "Music_PalletTown" and started[2].chip == true,
  "music.started names the song it replaced")
Music.stop()
check(#stopped == 1 and stopped[1].song == "Music_Chip",
  "music.stopped names the song that was playing")
Music.stop()
check(#stopped == 1, "stopping silence emits nothing")

Sound.play(data, "Beep")
check(played[1] and played[1].kind == "sfx" and played[1].name == "Beep",
  "sound.played fires for an sfx")
Sound.playMove(data, { sound = "Chip_Sfx", pitch = 0x10, tempo = 0x90 })
check(played[2].kind == "move" and played[2].name == "Chip_Sfx",
  "sound.played fires for a move sound")
data.audio.cries.FILEMON = { file = "assets/cry.ogg" }
Sound.playCry(data, "FILEMON")
check(played[3].kind == "cry" and played[3].species == "FILEMON",
  "sound.played fires for a cry")

Runtime.install(savedEvents, savedHooks)
check(not Runtime.wants("music.started"),
  "with no listener the event site allocates no payload")

-- ------- registries: the granular merge into data.audio

local function memfs(files)
  return {
    read = function(path) return files[path] end,
    getInfo = function(path)
      if files[path] then return { type = "file" } end
      local prefix = path .. "/"
      for key in pairs(files) do
        if key:sub(1, #prefix) == prefix then return { type = "directory" } end
      end
      return nil
    end,
    load = function(path)
      if not files[path] then return nil, "no file: " .. path end
      return load(files[path], path)
    end,
    getDirectoryItems = function(path)
      local seen, items = {}, {}
      local prefix = path .. "/"
      for key in pairs(files) do
        if key:sub(1, #prefix) == prefix then
          local child = key:sub(#prefix + 1):match("^[^/]+")
          if child and not seen[child] then
            seen[child] = true
            items[#items + 1] = child
          end
        end
      end
      table.sort(items)
      return items
    end,
  }
end

local function manifestJson(id, api, deps)
  return ([[{"id":"%s","name":"%s","version":"1.0.0","entry":"main.lua","dependencies":%s,"api":%d}]])
    :format(id, id, deps or "[]", api)
end

local granularFiles = {
  ["mods/coast/manifest.json"] = manifestJson("coast", 2),
  ["mods/coast/main.lua"] = [[
return function(mod)
  mod.content.music:register("Music_CoastTown", {
    file = "assets/theme.ogg", loopFile = "assets/theme_loop.ogg" })
  mod.content.sfx:register("Shell_Found", {
    file = "assets/chime.ogg", fanfare = true })
  mod.content.cries:register("SHELLORD", {
    header = { address = 16696, bank = 2, engine = 1 }, pitch = 42, length = 80 })
  mod.content.cries:register("REEFMON", { file = "assets/cry.ogg" })
  mod.content.map_songs:override("PALLET_TOWN", "Music_CoastTown")
  mod.content.cries:patch("RHYDON", { pitch = 200 })
  mod.content.sfx:remove("Beep")
end
]],
}
local merged = fixtureData()
merged.audio.cries.RHYDON = {
  header = { address = 1, bank = 2, engine = 1 }, pitch = 0, length = 9,
}
local granular = Loader.new({ fs = memfs(granularFiles) })
check(granular:load(merged) == true,
  "the granular audio mod loads: " .. table.concat(granular.errors, "; "))
check(merged.audio.songs.Music_CoastTown.loopFile == "assets/theme_loop.ogg",
  "music merges into data.audio.songs")
check(merged.audio.sfx.Shell_Found.fanfare == true,
  "sfx merges into data.audio.sfx")
check(merged.audio.cries.SHELLORD.pitch == 42,
  "cries merge into data.audio.cries")
check(merged.audio.mapSongs.PALLET_TOWN == "Music_CoastTown",
  "map_songs merge into data.audio.mapSongs")
check(merged.audio.cries.RHYDON.pitch == 200
  and merged.audio.cries.RHYDON.length == 9,
  "patch is field-precise on a cry record")
check(merged.audio.sfx.Beep == nil, "remove tombstones an sfx")

-- the merged map song plays through the ordinary map path
reset(merged)
Music.playMap(merged, "PALLET_TOWN", false, false)
check(sources[1] and sources[1].file == "assets/theme.ogg" and sources[1].playing,
  "a mod's map song plays on the map it claims")

-- a brand-new species sounds everywhere a vanilla one does
local reefCry = Sound.playCry(merged, "REEFMON")
check(reefCry and reefCry.file == "assets/cry.ogg" and reefCry.playing,
  "a species the mod invented plays its registered cry")

-- and the hook can still take the map theme away from it
local mapHooks = require("src.mods.Hooks").new()
Runtime.install(require("src.mods.Events").new(), mapHooks)
mapHooks:wrap("music.select", function(nextLink, song, ctx)
  if ctx.reason == "map" then return nextLink("Music_Other", ctx) end
  return nextLink(song, ctx)
end, nil, "night")
reset(merged)
Music.playMap(merged, "PALLET_TOWN", false, false)
check(lastSource().file == "assets/other.ogg",
  "music.select overrides the track for a map")
Runtime.install(savedEvents, savedHooks)

-- bootstrap: a dataset with no audio namespace at all
local bootstrapFiles = {
  ["mods/tc/manifest.json"] = manifestJson("tc", 2),
  ["mods/tc/main.lua"] = [[
return function(mod)
  mod.content.music:register("Music_TC", { file = "assets/theme.ogg" })
  mod.content.map_songs:register("TC_TOWN", "Music_TC")
end
]],
}
local bare = {}
local bootstrap = Loader.new({ fs = memfs(bootstrapFiles) })
check(bootstrap:load(bare) == true,
  "an audio-only conversion loads against a dataset with no audio: "
  .. table.concat(bootstrap.errors, "; "))
check(bare.audio and bare.audio.songs.Music_TC
  and bare.audio.mapSongs.TC_TOWN == "Music_TC",
  "the audio namespace is created when the base cache never shipped one")

-- the v1 whole-table registry still works and loses to a granular
-- registration of the same id
local v1Files = {
  ["mods/legacy/manifest.json"] = manifestJson("legacy", 1),
  ["mods/legacy/main.lua"] = [[
return function(mod)
  mod.content.audio:override("sfx", { Beep = "assets/other.ogg",
                                      Legacy_Only = "assets/beep.wav" })
end
]],
  ["mods/modern/manifest.json"] = manifestJson("modern", 2, '["legacy"]'),
  ["mods/modern/main.lua"] = [[
return function(mod)
  mod.content.sfx:override("Beep", "assets/chime.ogg")
end
]],
}
local v1Data = fixtureData()
local v1Loader = Loader.new({ fs = memfs(v1Files) })
check(v1Loader:load(v1Data) == true,
  "the v1 audio registry still loads: " .. table.concat(v1Loader.errors, "; "))
check(v1Data.audio.sfx.Legacy_Only == "assets/beep.wav",
  "the v1 whole-table replacement still applies")
check(v1Data.audio.sfx.Beep == "assets/chime.ogg",
  "a granular registration beats a v1 whole-table replacement")
check(v1Data.audio._owners.sfx.Beep == "modern",
  "the granular writer owns the id even when a v1 table landed on it first")

-- attribution: the owner map the merge stamps names the mod in the log and
-- in Loader.errors, which is the only feed the mod manager's errors screen
-- and its errored-mod glyph read
local function errorsMentioning(loader, fragment)
  local count = 0
  for _, line in ipairs(loader.errors) do
    if line:find(fragment, 1, true) then count = count + 1 end
  end
  return count
end

-- the defs are registered through a real load, not planted in the data, so
-- the provenance under test is the one the merge produced
local badFiles = {
  ["mods/coast/manifest.json"] = manifestJson("coast", 2),
  ["mods/coast/main.lua"] = [[
return function(mod)
  mod.content.music:register("Music_Bad", { file = "assets/missing.ogg" })
  mod.content.sfx:register("Sfx_Bad", { file = "assets/missing.ogg" })
  mod.content.sfx:register("Loop_Bad", { file = "assets/missing.ogg" })
  mod.content.cries:register("BADMON", { file = "assets/missing.ogg" })
  mod.content.sfx:register("Gone", { file = "assets/missing.ogg" })
  mod.content.sfx:remove("Gone")
end
]],
}
local badData = fixtureData()
local badLoader = Loader.new({ fs = memfs(badFiles) })
check(badLoader:load(badData) == true,
  "the mod shipping the broken defs loads: "
  .. table.concat(badLoader.errors, "; "))
check(badData.audio._owners.songs.Music_Bad == "coast"
  and badData.audio._owners.sfx.Sfx_Bad == "coast"
  and badData.audio._owners.sfx.Loop_Bad == "coast"
  and badData.audio._owners.cries.BADMON == "coast",
  "the merge stamps every def a mod registered with its owner")
check(badData.audio._owners.sfx.Gone == nil,
  "a tombstoned id keeps no provenance behind it")
check(badData.audio._owners.sfx.Beep == nil,
  "an id no mod touched stays unattributed")

reset(badData)
local attributedBefore = loggedCount("(mod coast)")
local errorsBefore = #badLoader.errors
Music.play(badData, "Music_Bad")
Sound.play(badData, "Sfx_Bad")
Sound.playCry(badData, "BADMON")
Sound.startLoop(badData, "Loop_Bad")
check(loggedCount("(mod coast)") == attributedBefore + 4,
  "a bad def is logged against the mod that registered it")
check(#badLoader.errors == errorsBefore + 4,
  "every play-time audio failure reaches Loader.errors")
check(errorsMentioning(badLoader, 'coast: audio: bad song def "Music_Bad"') == 1
  and errorsMentioning(badLoader, 'coast: audio: bad sfx def "Sfx_Bad"') == 1
  and errorsMentioning(badLoader, 'coast: audio: bad cry def "BADMON"') == 1
  and errorsMentioning(badLoader, 'coast: audio: bad sfx def "Loop_Bad"') == 1,
  "Loader.errors names the owning mod and the def that failed")

-- replaying a known-bad def is silent: the negative cache keeps the errors
-- screen from filling up with one broken def
Music.play(badData, "Music_Bad")
Sound.play(badData, "Sfx_Bad")
Sound.playCry(badData, "BADMON")
Sound.startLoop(badData, "Loop_Bad")
check(#badLoader.errors == errorsBefore + 4,
  "a known-bad def reports to Loader.errors once, not per play")

-- an engine-owned def has no mod to blame, so it stays a console line
badData.audio.songs.Music_BaseBad = { file = "assets/missing.ogg" }
Music.play(badData, "Music_BaseBad")
check(loggedCount("bad song def") > 0 and #badLoader.errors == errorsBefore + 4,
  "a base-owned failure never lands in Loader.errors")

-- ------- restore the ambient stubs for the suites that follow

Sound.invalidate()
Music.reload()
Runtime.install(savedEvents, savedHooks, savedErrors)
love.audio, love.sound = savedAudio, savedSound

S.finish()
