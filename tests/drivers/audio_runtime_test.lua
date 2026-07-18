return function(game)
  local U = dofile("tests/drivers/util.lua")
  local ChipAudio = require("src.core.ChipAudio")
  assert(game.data.audio and game.data.audio.runtime,
    "runtime ROM audio data was not loaded")
  local battleAnims = assert(game.data.battle_anims,
    "runtime ROM battle animation data was not loaded")
  local ImageWriter = require("src.import.ImageWriter")
  local transparentTile = ImageWriter.decode2bpp({
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
  }, 8, 8, true)
  local _, _, _, alpha = transparentTile:getPixel(0, 0)
  assert(alpha == 0, "runtime 2bpp color 0 is not transparent")
  local encodedTile = assert(transparentTile:encode("png"))
  local decodedTile = assert(love.image.newImageData(encodedTile))
  local _, _, _, encodedAlpha = decodedTile:getPixel(0, 0)
  assert(encodedAlpha == 0, "runtime PNG encoding discarded transparency")
  local animCount = 0
  for _ in pairs(battleAnims.moveAnims) do animCount = animCount + 1 end
  assert(animCount == 202,
    "runtime ROM battle animation table is incomplete")
  for _, sheet in pairs(battleAnims.tilesheets) do
    assert(love.filesystem.getInfo(sheet.path, "file"),
      "runtime ROM battle animation atlas is missing")
    local image = assert(love.image.newImageData(sheet.path))
    local hasTransparentPixel = false
    image:mapPixel(function(x, y, r, g, b, a)
      hasTransparentPixel = hasTransparentPixel or a == 0
      return r, g, b, a
    end)
    assert(hasTransparentPixel,
      "runtime ROM battle animation atlas has no transparency")
  end
  local gengar = assert(
    game.data.field.intro.gengar.frame1,
    "runtime ROM Gengar intro frame metadata is missing")
  local gengarImage = assert(love.image.newImageData(gengar.path))
  local hasClearEdge, hasOpaqueWhite = false, false
  gengarImage:mapPixel(function(x, y, r, g, b, a)
    hasClearEdge = hasClearEdge or a == 0
    hasOpaqueWhite = hasOpaqueWhite
      or (r == 1 and g == 1 and b == 1 and a == 1)
    return r, g, b, a
  end)
  assert(hasClearEdge,
    "runtime ROM Gengar intro frame has an opaque background")
  assert(hasOpaqueWhite,
    "runtime ROM Gengar intro matte removed interior white details")
  local AnimPlayer = require("src.battle.AnimPlayer")
  local player = AnimPlayer.new(battleAnims)
  player:start("THUNDERBOLT", true)
  assert(#player.steps > 4,
    "runtime ROM THUNDERBOLT animation did not compile")

  local title = assert(game.data.audio.songs.Music_TitleScreen)
  local pallet = assert(game.data.audio.songs.Music_PalletTown)
  local palletTrace = ChipAudio._traceFirstMusicSampleForTest(
    game.data, pallet)
  assert(palletTrace[1].register == 1782,
    "Pallet Town B note was not decoded as a tone")

  local insideTrace = ChipAudio._traceFirstSfxSampleForTest(
    game.data, assert(game.data.audio.sfx.Go_Inside))
  assert(insideTrace[1].noiseParameter == 0x44
      and insideTrace[1].volume == 15
      and insideTrace[1].fade == 1,
    "Go Inside did not preserve its first NR42/NR43 register values")

  local collisionTrace = ChipAudio._traceFirstSfxSampleForTest(
    game.data, assert(game.data.audio.sfx.Collision))
  local sweep = assert(collisionTrace[1].sweep,
    "Collision did not preserve its NR10 sweep")
  assert(sweep.pace == 5 and sweep.subtract and sweep.shift == 2,
    "Collision NR10 sweep was decoded incorrectly")

  local music = assert(ChipAudio.playMusic(game.data, title, true))
  assert(music:getFreeBufferCount() < 8, "title music queued no samples")
  assert(music:isPlaying(), "title music source did not start")

  local sfx = assert(ChipAudio.newSfx(game.data, "Press_AB"))
  assert(sfx:getDuration() > 0.01, "menu sound is empty")
  sfx:play()

  local cry = assert(ChipAudio.newCry(game.data, "PIKACHU"))
  assert(cry:getDuration() > 0.01, "Pikachu cry is empty")
  cry:play()

  local fanfare = assert(ChipAudio.newSfx(game.data, "Level_Up"))
  assert(fanfare:getDuration() > 2.1 and fanfare:getDuration() < 2.3,
    ("Level Up timing is wrong: %.3fs"):format(fanfare:getDuration()))

  if os.getenv("POKEPORT_AUDIO_EXHAUSTIVE") == "1" then
    local sfxCount, cryCount = 0, 0
    for name in pairs(game.data.audio.sfx) do
      assert(ChipAudio.newSfx(game.data, name),
        "could not synthesize SFX " .. name)
      sfxCount = sfxCount + 1
    end
    for species in pairs(game.data.audio.cries) do
      assert(ChipAudio.newCry(game.data, species),
        "could not synthesize cry " .. species)
      cryCount = cryCount + 1
    end
    print(("[audio] exhaustive synthesis: %d SFX, %d cries")
      :format(sfxCount, cryCount))
  end

  print(("[audio] title queued; Press_AB %.3fs; Pikachu %.3fs; Level_Up %.3fs")
    :format(sfx:getDuration(), cry:getDuration(), fanfare:getDuration()))
  ChipAudio.stopMusic()
  U.wait(2)
end
