local function le16(value)
  return string.char(value % 256, math.floor(value / 256) % 256)
end

local function le32(value)
  return le16(value % 65536) .. le16(math.floor(value / 65536))
end

local function writeWav(path, soundData, channels)
  local raw = soundData:getString()
  local rate, bits = soundData:getSampleRate(), soundData:getBitDepth()
  local header = table.concat({
    "RIFF", le32(36 + #raw), "WAVE",
    "fmt ", le32(16), le16(1), le16(channels), le32(rate),
    le32(rate * channels * bits / 8), le16(channels * bits / 8),
    le16(bits), "data", le32(#raw),
  })
  local file = assert(io.open(path, "wb"))
  file:write(header, raw)
  file:close()
end

return function(game)
  local ChipAudio = require("src.core.ChipAudio")
  local out = assert(os.getenv("POKEPORT_AUDIO_CAPTURE_DIR"))
  local audio = assert(game.data.audio)

  for _, song in ipairs({ "Music_TitleScreen", "Music_PalletTown" }) do
    for _, event in ipairs(ChipAudio._traceFirstMusicSampleForTest(
        game.data, audio.songs[song])) do
      print(("[audio-trace] %s ch%d value=%.4f reg=%s duration=%.4f drum=%s")
        :format(song, event.number, event.value,
          tostring(event.register), event.duration or 0,
          tostring(event.drumSegments)))
    end
  end

  writeWav(out .. "/title-runtime.wav",
    ChipAudio._renderMusicForTest(
      game.data, audio.songs.Music_TitleScreen, 8), 2)
  writeWav(out .. "/pallet-runtime.wav",
    ChipAudio._renderMusicForTest(
      game.data, audio.songs.Music_PalletTown, 8), 2)
  for channel = 1, 4 do
    writeWav(("%s/title-ch%d-runtime.wav"):format(out, channel),
      ChipAudio._renderMusicChannelForTest(
        game.data, audio.songs.Music_TitleScreen, 8, channel), 1)
  end
  for channel = 1, 3 do
    writeWav(("%s/pallet-ch%d-runtime.wav"):format(out, channel),
      ChipAudio._renderMusicChannelForTest(
        game.data, audio.songs.Music_PalletTown, 8, channel), 1)
  end
  writeWav(out .. "/go-inside-runtime.wav",
    ChipAudio._renderSfxForTest(
      game.data, audio.sfx.Go_Inside, 0.4), 1)
  writeWav(out .. "/go-outside-runtime.wav",
    ChipAudio._renderSfxForTest(
      game.data, audio.sfx.Go_Outside, 0.7), 1)
  print("[audio] captured runtime comparison WAVs")
end
