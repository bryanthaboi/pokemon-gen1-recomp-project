local bit = require("bit")
local ImageWriter = require("src.import.ImageWriter")
local LuaWriter = require("src.import.LuaWriter")
local Rom = require("src.import.Rom")

local RomExtractor = {}
RomExtractor.__index = RomExtractor

local STAGE_COUNT = 17

local function copy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local result = {}
  seen[value] = result
  for key, item in pairs(value) do result[copy(key, seen)] = copy(item, seen) end
  return result
end

local function append(target, source)
  for _, value in ipairs(source) do target[#target + 1] = value end
end

local function unique(values)
  local result, seen = {}, {}
  for _, value in ipairs(values) do
    if not seen[value] then
      seen[value] = true
      result[#result + 1] = value
    end
  end
  return result
end

local function sorted(values)
  table.sort(values)
  return values
end

local function startsWith(value, prefix)
  return value:sub(1, #prefix) == prefix
end

local function round(value)
  return math.floor(value + 0.5)
end

local function hex(prefix, value)
  return ("%s_%02X"):format(prefix, value)
end

function RomExtractor.new(romData, manifest, progress)
  return setmetatable({
    rom = Rom.new(romData),
    manifest = manifest,
    symbols = manifest.symbols,
    progress = progress,
    stage = 0,
  }, RomExtractor)
end

function RomExtractor:symbol(name)
  local location = self.symbols[name]
  if not location then error("required symbol is missing: " .. tostring(name)) end
  return { bank = location[1], address = location[2], name = name }
end

function RomExtractor:beginStage(name)
  self.stage = self.stage + 1
  if self.progress then self.progress(self.stage - 1, STAGE_COUNT, name, 0, 1) end
end

function RomExtractor:tick(name, current, total)
  if self.progress then
    self.progress(self.stage - 1 + current / total, STAGE_COUNT,
      name, current, total)
  end
end

function RomExtractor:write(name, value)
  LuaWriter.write("data/generated/" .. name .. ".lua", value)
end

function RomExtractor:save(image, relative)
  ImageWriter.save(image, "assets/generated/" .. relative)
end

function RomExtractor:readTerminated(bank, address, terminator, limit)
  local out = {}
  for offset = 0, (limit or 256) - 1 do
    local value = self.rom:byte(bank, address + offset)
    if value == terminator then return out end
    out[#out + 1] = value
  end
  error(("unterminated byte list at %02X:%04X"):format(bank, address))
end

function RomExtractor:write2bpp(raw, width, height, relative, transparent)
  local image = ImageWriter.decode2bpp(raw, width, height, transparent)
  self:save(image, relative)
end

function RomExtractor:writeCompressedPic(label, relative)
  local symbol = self:symbol(label)
  local compressed = self.rom:bytes(
    symbol.bank, symbol.address, 0x8000 - symbol.address)
  local raw, width = Rom.decompressPic(compressed)
  local image = ImageWriter.matteColor0(
    ImageWriter.decode2bpp(raw, width * 8, width * 8))
  self:save(image, relative)
  return width
end

function RomExtractor:extractConstants()
  self:beginStage("Game constants")
  local data = self.manifest.constants
  self:write("constants", data)
  self:tick("Game constants", 1, 1)
  return data
end

function RomExtractor:extractTilesets()
  self:beginStage("World tiles")
  local manifest = self.manifest
  local order = manifest.constants.tilesetOrder
  local metadata = manifest.tilesets
  local animations = manifest.tileAnimations
  assert(#metadata == #order, "tileset metadata count does not match constants")

  local headers = self:symbol("Tilesets")
  local warpPointers = self:symbol("WarpTileIDPointers")
  local doorPointers = self:symbol("DoorTileIDPointers")
  local doors, address = {}, doorPointers.address
  while true do
    local tilesetId = self.rom:byte(doorPointers.bank, address)
    if tilesetId == 0xFF then break end
    local pointer = self.rom:word(doorPointers.bank, address + 1)
    doors[tilesetId] = self:readTerminated(
      doorPointers.bank, pointer, 0)
    address = address + 3
  end

  local out, written = {}, {}
  for index, constName in ipairs(order) do
    local spec = metadata[index]
    assert(spec.id == constName, "tileset metadata is out of order")
    local rowAddress = headers.address + (index - 1) * 12
    local gfxBank = self.rom:byte(headers.bank, rowAddress)
    local blockPointer = self.rom:word(headers.bank, rowAddress + 1)
    local gfxPointer = self.rom:word(headers.bank, rowAddress + 3)
    local collisionPointer = self.rom:word(headers.bank, rowAddress + 5)
    local counters = self.rom:bytes(headers.bank, rowAddress + 7, 3)
    local grass = self.rom:byte(headers.bank, rowAddress + 10)
    local animationId = self.rom:byte(headers.bank, rowAddress + 11)
    assert(animationId < #animations, constName .. ": unknown tile animation")

    local blocksRaw = self.rom:bytes(
      gfxBank, blockPointer, spec.blockCount * 16)
    local blocks = {}
    for offset = 1, #blocksRaw, 16 do
      local block = {}
      for pos = offset, offset + 15 do block[#block + 1] = blocksRaw[pos] end
      blocks[#blocks + 1] = block
    end
    local walkable = sorted(self:readTerminated(
      0, collisionPointer, 0xFF))
    local warpPointer = self.rom:word(
      warpPointers.bank, warpPointers.address + (index - 1) * 2)
    local warpTiles = unique(self:readTerminated(
      warpPointers.bank, warpPointer, 0xFF))
    sorted(warpTiles)

    local base = spec.imageBase
    if not written[base] then
      local byteLength = spec.imageWidth * spec.imageHeight / 4
      local storedLength = blockPointer - gfxPointer
      assert(storedLength >= 0 and storedLength <= byteLength
        and storedLength % 16 == 0,
        constName .. ": invalid stored tileset graphics length")
      local pixels = self.rom:bytes(gfxBank, gfxPointer, storedLength)
      while #pixels < byteLength do pixels[#pixels + 1] = 0 end
      self:write2bpp(pixels, spec.imageWidth, spec.imageHeight,
        "tilesets/" .. base .. ".png")
      written[base] = true
    end

    local counterTiles = {}
    for _, value in ipairs(counters) do
      if value ~= 0xFF then counterTiles[#counterTiles + 1] = value end
    end
    local grassTile
    if grass ~= 0xFF then grassTile = grass end
    out[constName] = {
      id = constName,
      source = ("ROM:Tilesets[%d]"):format(index - 1),
      image = "assets/generated/tilesets/" .. base .. ".png",
      imageWidth = spec.imageWidth,
      imageHeight = spec.imageHeight,
      tilesPerRow = spec.imageWidth / 8,
      blocks = blocks,
      walkable = walkable,
      counterTiles = counterTiles,
      grassTile = grassTile,
      doorTiles = sorted(copy(doors[index - 1] or {})),
      warpTiles = warpTiles,
      animation = animations[animationId + 1],
    }
    self:tick("World tiles", index, #order + 4)
  end
  for number = 1, 3 do
    local symbol = self:symbol("FlowerTile" .. number)
    self:write2bpp(self.rom:bytes(symbol.bank, symbol.address, 16),
      8, 8, "tilesets/flower" .. number .. ".png")
    self:tick("World tiles", #order + number, #order + 4)
  end
  local spinner = self:symbol("SpinnerArrowAnimTiles")
  self:write2bpp(self.rom:bytes(spinner.bank, spinner.address, 64),
    32, 8, "tilesets/spinners.png")
  self:write("tilesets", out)
  self:tick("World tiles", #order + 4, #order + 4)
  return out
end

function RomExtractor:extractMaps()
  self:beginStage("Maps")
  local manifest = self.manifest
  local mapOrder = manifest.constants.mapOrder
  local dimensions = manifest.constants.maps
  local metadata = manifest.maps
  local tilesets = manifest.constants.tilesetOrder
  local sprites = manifest.constants.spriteOrder
  local movementNames = { [0xFE] = "WALK", [0xFF] = "STAY" }
  local rangeNames = {
    [0x00] = "ANY_DIR", [0x01] = "UP_DOWN", [0x02] = "LEFT_RIGHT",
    [0x10] = "BOULDER_MOVEMENT_BYTE_2", [0xD0] = "DOWN",
    [0xD1] = "UP", [0xD2] = "LEFT", [0xD3] = "RIGHT", [0xFF] = "NONE",
  }
  local directions = {
    { "north", 0x08 }, { "south", 0x04 },
    { "west", 0x02 }, { "east", 0x01 },
  }
  local function signed(value) return value >= 0x80 and value - 0x100 or value end
  local function mapId(value)
    if value == 0xFF then return "LAST_MAP" end
    assert(value < #mapOrder, ("unknown map id $%02X"):format(value))
    return mapOrder[value + 1]
  end

  local keys = {}
  for key in pairs(metadata) do keys[#keys + 1] = key end
  table.sort(keys)
  local out = {}
  for mapIndex, constName in ipairs(keys) do
    local spec, dims = metadata[constName], dimensions[constName]
    local label = spec.label
    local header = self:symbol(label .. "_h")
    local address = header.address
    local tilesetId = self.rom:byte(header.bank, address)
    local height = self.rom:byte(header.bank, address + 1)
    local width = self.rom:byte(header.bank, address + 2)
    assert(width == dims.width and height == dims.height,
      constName .. ": ROM dimensions do not match metadata")
    assert(tilesetId < #tilesets, constName .. ": unknown tileset id")
    local blockPointer = self.rom:word(header.bank, address + 3)
    local connectionFlags = self.rom:byte(header.bank, address + 9)
    address = address + 10

    local connections = {}
    for _, directionSpec in ipairs(directions) do
      local direction, flag = directionSpec[1], directionSpec[2]
      if bit.band(connectionFlags, flag) ~= 0 then
        local targetId = self.rom:byte(header.bank, address)
        local yOffset = signed(self.rom:byte(header.bank, address + 7))
        local xOffset = signed(self.rom:byte(header.bank, address + 8))
        local encoded = (direction == "north" or direction == "south")
          and xOffset or yOffset
        assert(encoded % 2 == 0, constName .. ": odd connection offset")
        connections[direction] = {
          map = mapId(targetId),
          offset = -encoded / 2,
        }
        address = address + 11
      end
    end
    assert(bit.band(connectionFlags, 0xF0) == 0,
      constName .. ": unknown connection flags")
    local objectPointer = self.rom:word(header.bank, address)
    local objectAddress = objectPointer
    local borderBlock = self.rom:byte(header.bank, objectAddress)
    objectAddress = objectAddress + 1

    local warpCount = self.rom:byte(header.bank, objectAddress)
    objectAddress = objectAddress + 1
    local warps = {}
    for _ = 1, warpCount do
      local row = self.rom:bytes(header.bank, objectAddress, 4)
      warps[#warps + 1] = {
        x = row[2], y = row[1],
        destMap = mapId(row[4]), destWarp = row[3] + 1,
      }
      objectAddress = objectAddress + 4
    end

    local signCount = self.rom:byte(header.bank, objectAddress)
    objectAddress = objectAddress + 1
    assert(signCount == #spec.signTexts, constName .. ": sign count mismatch")
    local signs = {}
    for _, signText in ipairs(spec.signTexts) do
      local row = self.rom:bytes(header.bank, objectAddress, 3)
      signs[#signs + 1] = { x = row[2], y = row[1], text = signText }
      objectAddress = objectAddress + 3
    end

    local objectCount = self.rom:byte(header.bank, objectAddress)
    objectAddress = objectAddress + 1
    assert(objectCount == #spec.objects, constName .. ": object count mismatch")
    local objects = {}
    for index, objectSpec in ipairs(spec.objects) do
      local row = self.rom:bytes(header.bank, objectAddress, 6)
      local spriteId, y, x = row[1], row[2], row[3]
      local movementId, rangeId, textId = row[4], row[5], row[6]
      assert(spriteId >= 1 and spriteId <= #sprites,
        constName .. ": unknown object sprite")
      assert(movementNames[movementId] and rangeNames[rangeId],
        constName .. ": unknown movement encoding")
      local object = {
        index = index, x = x - 4, y = y - 4,
        sprite = sprites[spriteId],
        movement = movementNames[movementId],
        range = rangeNames[rangeId],
        text = objectSpec.text,
      }
      objectAddress = objectAddress + 6
      if bit.band(textId, 0x80) ~= 0 then
        assert(objectSpec.item, constName .. ": unexpected item payload")
        object.item = objectSpec.item
        objectAddress = objectAddress + 1
      elseif bit.band(textId, 0x40) ~= 0 then
        local extra = self.rom:bytes(header.bank, objectAddress, 2)
        objectAddress = objectAddress + 2
        if objectSpec.trainerClass then
          object.trainerClass = objectSpec.trainerClass
          object.trainerParty = type(objectSpec.trainerParty) == "string"
            and objectSpec.trainerParty or extra[2]
        elseif objectSpec.pokemon then
          object.pokemon = objectSpec.pokemon
          object.level = extra[2]
        else
          error(constName .. ": unexpected trainer or Pokemon payload")
        end
      else
        assert(not objectSpec.item and not objectSpec.trainerClass
          and not objectSpec.pokemon, constName .. ": missing extra payload")
      end
      if objectSpec.name then object.name = objectSpec.name end
      if objectSpec.hidden ~= nil then object.hidden = objectSpec.hidden end
      objects[#objects + 1] = object
    end

    local expectedBlocks = width * height
    assert(spec.blockLength <= expectedBlocks,
      constName .. ": block payload exceeds map dimensions")
    local blocks = self.rom:bytes(
      header.bank, blockPointer, spec.blockLength)
    while #blocks < expectedBlocks do blocks[#blocks + 1] = borderBlock end

    out[constName] = {
      id = constName, label = label, index = dims.index,
      source = ("ROM:%02X:%04X"):format(header.bank, header.address),
      tileset = tilesets[tilesetId + 1],
      width = width, height = height, blocks = blocks,
      borderBlock = borderBlock, connections = connections,
      warps = warps, signs = signs, objects = objects,
    }
    self:tick("Maps", mapIndex, #keys)
  end
  self:write("maps", out)
  return out
end

function RomExtractor:extractFont()
  self:beginStage("Fonts")
  local mainSymbol = self:symbol("FontGraphics")
  local raw = self.rom:bytes(mainSymbol.bank, mainSymbol.address, 128 * 8)
  local image = ImageWriter.blank(128, 64, 0, 0, 0, 0)
  for tile = 0, 127 do
    local tileX, tileY = tile % 16 * 8, math.floor(tile / 16) * 8
    for y = 0, 7 do
      local row = raw[tile * 8 + y + 1]
      for x = 0, 7 do
        if bit.band(row, 2 ^ (7 - x)) ~= 0 then
          image:setPixel(tileX + x, tileY + y, 0, 0, 0, 1)
        end
      end
    end
  end
  self:save(image, "fonts/font.png")
  self:tick("Fonts", 1, 2)

  local extraSymbol = self:symbol("TextBoxGraphics")
  local shaded = ImageWriter.decode2bpp(
    self.rom:bytes(extraSymbol.bank, extraSymbol.address, 32 * 16),
    128, 16)
  local extra = ImageWriter.blank(128, 16, 0, 0, 0, 0)
  for y = 0, 15 do
    for x = 0, 127 do
      local r = shaded:getPixel(x, y)
      if r < 0.5 then extra:setPixel(x, y, 0, 0, 0, 1) end
    end
  end
  local pokedex = self:symbol("PokedexTileGraphics")
  local dex = ImageWriter.decode2bpp(
    self.rom:bytes(pokedex.bank, pokedex.address, 32), 16, 8)
  for y = 0, 7 do
    for x = 0, 15 do
      local r = dex:getPixel(x, y)
      extra:setPixel(x, y, 0, 0, 0, r < 0.5 and 1 or 0)
    end
  end
  self:save(extra, "fonts/font_extra.png")
  local data = {
    source = "ROM:FontGraphics, TextBoxGraphics, PokedexTileGraphics",
    image = "assets/generated/fonts/font.png",
    imageExtra = "assets/generated/fonts/font_extra.png",
    mainBase = 0x80, extraBase = 0x60, glyphsPerRow = 16,
    charmap = self.manifest.fontCharmap,
  }
  self:write("font", data)
  self:tick("Fonts", 2, 2)
  return data
end

function RomExtractor:extractSprites()
  self:beginStage("Overworld sprites")
  local order = self.manifest.constants.spriteOrder
  local metadata = self.manifest.sprites.order
  local pointerTable = self:symbol("SpriteSheetPointerTable")
  assert(#metadata == #order, "sprite metadata count does not match constants")
  local out, written = {}, {}
  for index, constName in ipairs(order) do
    local spec = metadata[index]
    assert(spec.id == constName, "sprite metadata is out of order")
    local address = pointerTable.address + (index - 1) * 4
    local pointer = self.rom:word(pointerTable.bank, address)
    local firstHalf = self.rom:byte(pointerTable.bank, address + 2)
    local bank = self.rom:byte(pointerTable.bank, address + 3)
    local byteLength = spec.imageWidth * spec.imageHeight / 4
    local frames = spec.imageHeight / 16
    local expected = firstHalf * (frames >= 6 and 2 or 1)
    assert(byteLength == expected, constName .. ": sprite length mismatch")
    local base = spec.imageBase
    if not written[base] then
      self:write2bpp(self.rom:bytes(bank, pointer, byteLength),
        spec.imageWidth, spec.imageHeight,
        "sprites/" .. base .. ".png", true)
      written[base] = true
    end
    out[constName] = {
      id = constName,
      source = ("ROM:SpriteSheetPointerTable[%d]"):format(index - 1),
      image = "assets/generated/sprites/" .. base .. ".png",
      frames = frames, walker = frames >= 6,
    }
    self:tick("Overworld sprites", index, #order + 1)
  end
  local bike = self.manifest.sprites.bike
  local bikeSymbol = self:symbol(bike.label)
  self:write2bpp(
    self.rom:bytes(bikeSymbol.bank, bikeSymbol.address,
      bike.imageWidth * bike.imageHeight / 4),
    bike.imageWidth, bike.imageHeight,
    "sprites/" .. bike.imageBase .. ".png", true)
  local bikeFrames = bike.imageHeight / 16
  out.SPRITE_RED_BIKE = {
    id = "SPRITE_RED_BIKE", source = "ROM:RedBikeSprite",
    image = "assets/generated/sprites/red_bike.png",
    frames = bikeFrames, walker = bikeFrames >= 6,
  }
  self:write("sprites", out)
  self:tick("Overworld sprites", #order + 1, #order + 1)
  return out
end

function RomExtractor:animationFlags(count)
  local pointerTable = self:symbol("AttackAnimationPointers")
  local flags = {}
  for index = 0, count - 1 do
    local address = self.rom:word(
      pointerTable.bank, pointerTable.address + index * 2)
    local shake, flash, ended = false, false, false
    for _ = 1, 256 do
      local first = self.rom:byte(pointerTable.bank, address)
      if first == 0xFF then ended = true; break end
      if first >= 0xD8 then
        shake = shake or first == 0xFB
        flash = flash or first == 0xF8 or first == 0xFE
        address = address + 2
      else
        address = address + 3
      end
    end
    assert(ended, "unterminated move animation " .. (index + 1))
    flags[#flags + 1] = { shake, flash }
  end
  return flags
end

function RomExtractor:extractMoves()
  self:beginStage("Moves")
  local order = self.manifest.constants.moveOrder
  local types = {}
  for name, value in pairs(self.manifest.constants.types) do types[value] = name end
  local effects = self.manifest.moveEffects
  local charmap = self.manifest.charmap
  local moves = self:symbol("Moves")
  local names = self:symbol("MoveNames")
  local sounds = self:symbol("MoveSoundTable")
  local flags = self:animationFlags(#order)
  local decodedNames, address = {}, names.address
  for _ = 1, #order do
    local value, consumed = self.rom:readString(
      names.bank, address, charmap, 0x50, 32)
    decodedNames[#decodedNames + 1] = value
    address = address + consumed
  end
  local out = {}
  for index, moveId in ipairs(order) do
    local row = self.rom:bytes(moves.bank, moves.address + (index - 1) * 6, 6)
    assert(row[1] == index, "Moves row stores wrong animation id")
    local effect = effects[row[2] + 1] or hex("EFFECT", row[2])
    local typeName = types[row[4]] or hex("TYPE", row[4])
    local soundId, pitch, tempo = unpack(self.rom:bytes(
      sounds.bank, sounds.address + (index - 1) * 3, 3))
    local animation = {
      sound = self.manifest.sfxKeys[tostring(soundId)] or hex("SFX", soundId),
      pitch = pitch, tempo = tempo,
    }
    if flags[index][1] then animation.shake = true end
    if flags[index][2] then animation.flash = true end
    out[moveId] = {
      id = moveId, index = index, name = decodedNames[index],
      source = ("ROM:Moves[%d]"):format(index),
      effect = effect, power = row[3], type = typeName,
      accuracy = round(row[5] * 100 / 255), pp = row[6],
      anim = animation,
    }
    self:tick("Moves", index, #order)
  end
  self:write("moves", out)
  return out
end

function RomExtractor:extractBattleAnimations()
  self:beginStage("Battle animations")
  local metadata = self.manifest.battleAnimations
  local moveOrder = self.manifest.constants.moveOrder
  assert(#moveOrder == metadata.moveCount,
    "battle animation move count does not match constants")
  local total = metadata.baseCoordCount + metadata.frameBlockCount
    + metadata.subanimCount + metadata.moveCount
    + #metadata.miscAnimations + 3
  local completed = 0
  local function tick()
    completed = completed + 1
    self:tick("Battle animations", completed, total)
  end

  local coordsSymbol = self:symbol("FrameBlockBaseCoords")
  local baseCoords = {}
  for index = 0, metadata.baseCoordCount - 1 do
    local row = self.rom:bytes(
      coordsSymbol.bank, coordsSymbol.address + index * 2, 2)
    baseCoords[index] = { y = row[1], x = row[2] }
    tick()
  end

  local blocksSymbol = self:symbol("FrameBlockPointers")
  local frameBlocks = {}
  for index = 0, metadata.frameBlockCount - 1 do
    local address = self.rom:word(
      blocksSymbol.bank, blocksSymbol.address + index * 2)
    local count = self.rom:byte(blocksSymbol.bank, address)
    address = address + 1
    local entries = {}
    for _ = 1, count do
      local row = self.rom:bytes(blocksSymbol.bank, address, 4)
      local attrs = row[4]
      local entry = {
        y = row[1], x = row[2], tile = row[3],
        xflip = bit.band(attrs, 0x20) ~= 0,
        yflip = bit.band(attrs, 0x40) ~= 0,
      }
      if bit.band(attrs, 0x80) ~= 0 then entry.prio = true end
      if bit.band(attrs, 0x10) ~= 0 then entry.pal1 = true end
      entries[#entries + 1] = entry
      address = address + 4
    end
    frameBlocks[index] = entries
    tick()
  end

  local subanimSymbol = self:symbol("SubanimationPointers")
  local subanims = {}
  for index = 0, metadata.subanimCount - 1 do
    local address = self.rom:word(
      subanimSymbol.bank, subanimSymbol.address + index * 2)
    local packed = self.rom:byte(subanimSymbol.bank, address)
    local typeId = math.floor(packed / 0x20)
    local count = packed % 0x20
    local typeName = metadata.subanimTypes[typeId + 1]
    assert(typeName, "subanimation " .. index .. " has unknown type")
    address = address + 1
    local entries = {}
    for _ = 1, count do
      local row = self.rom:bytes(subanimSymbol.bank, address, 3)
      assert(row[1] < metadata.frameBlockCount,
        "subanimation " .. index .. " has invalid frame block")
      assert(row[2] < metadata.baseCoordCount,
        "subanimation " .. index .. " has invalid base coord")
      entries[#entries + 1] = {
        block = row[1], coord = row[2], mode = row[3],
      }
      address = address + 3
    end
    subanims[index] = { type = typeName, blocks = entries }
    tick()
  end

  local tilesTable = self:symbol("MoveAnimationTilesPointers")
  assert(#metadata.tilesheets == 3,
    "expected three battle animation tilesheets")
  local tileRows = {}
  for index = 0, 2 do
    local row = self.rom:bytes(
      tilesTable.bank, tilesTable.address + index * 4, 4)
    assert(row[4] == 0xFF,
      "battle animation tilesheet " .. index .. " has invalid padding")
    local pointer = row[2] + row[3] * 0x100
    local expected = self:symbol("MoveAnimationTiles" .. index)
    assert(expected.bank == tilesTable.bank and expected.address == pointer,
      "battle animation tilesheet " .. index .. " pointer differs")
    tileRows[index] = {
      count = row[1], pointer = pointer,
      spec = metadata.tilesheets[index + 1],
    }
  end

  local imagePayloads = {}
  for index = 0, 2 do
    local row = tileRows[index]
    local path = row.spec.path
    local payload = imagePayloads[path]
    if payload then
      assert(payload.pointer == row.pointer,
        "shared battle animation atlas has two pointers")
    else
      payload = { pointer = row.pointer, tiles = 0, spec = row.spec }
      imagePayloads[path] = payload
    end
    payload.tiles = math.max(payload.tiles, row.count)
  end
  local prefix = "assets/generated/"
  for path, payload in pairs(imagePayloads) do
    local spec = payload.spec
    local byteLength = spec.width * spec.height / 4
    local storedLength = payload.tiles * 16
    assert(storedLength <= byteLength,
      path .. ": battle animation atlas is too large")
    local raw = self.rom:bytes(
      tilesTable.bank, payload.pointer, storedLength)
    while #raw < byteLength do raw[#raw + 1] = 0 end
    assert(startsWith(path, prefix), "invalid generated asset path")
    self:write2bpp(raw, spec.width, spec.height,
      path:sub(#prefix + 1), true)
  end

  local tilesheets = {}
  for index = 0, 2 do
    local row, spec = tileRows[index], tileRows[index].spec
    tilesheets[index] = {
      path = spec.path, width = spec.width, height = spec.height,
      tiles = row.count, source = spec.source,
    }
    tick()
  end

  local moveNames = copy(moveOrder)
  append(moveNames, metadata.miscAnimations)
  local pointerTable = self:symbol("AttackAnimationPointers")
  local moveAnims = {}
  for index, name in ipairs(moveNames) do
    local address = self.rom:word(
      pointerTable.bank, pointerTable.address + (index - 1) * 2)
    local sequence, ended = {}, false
    for _ = 1, 256 do
      local first = self.rom:byte(pointerTable.bank, address)
      if first == 0xFF then ended = true; break end
      local sound = self.rom:byte(pointerTable.bank, address + 1)
      local row
      if first >= metadata.firstSpecialEffect then
        local effect = metadata.specialEffects[tostring(first)]
        assert(effect, name .. ": unknown special effect")
        row = { effect = effect }
        address = address + 2
      else
        local subanim = self.rom:byte(pointerTable.bank, address + 2)
        local delay = first % 0x40
        local tileset = math.floor(first / 0x40)
        assert(delay > 0, name .. ": zero animation delay")
        assert(subanim < metadata.subanimCount,
          name .. ": unknown subanimation")
        assert(tilesheets[tileset],
          name .. ": unknown animation tileset")
        row = { subanim = subanim, tileset = tileset, delay = delay }
        address = address + 3
      end
      if sound ~= 0xFF then
        assert(sound < #moveOrder, name .. ": unknown animation sound")
        row.sound = moveOrder[sound + 1]
      end
      sequence[#sequence + 1] = row
    end
    assert(ended, name .. ": unterminated battle animation")
    moveAnims[name] = {
      source = ("ROM:AttackAnimationPointers[%d]"):format(index - 1),
      seq = sequence,
    }
    tick()
  end

  for name, anim in pairs(moveAnims) do
    for _, row in ipairs(anim.seq) do
      if row.subanim then
        local sheet = tilesheets[row.tileset]
        for _, blockRef in ipairs(subanims[row.subanim].blocks) do
          for _, tile in ipairs(frameBlocks[blockRef.block]) do
            assert(tile.tile < sheet.tiles,
              name .. ": animation tile is out of range")
          end
        end
      end
    end
  end

  local out = {
    tilesheets = tilesheets,
    baseCoords = baseCoords,
    frameBlocks = frameBlocks,
    subanims = subanims,
    moveAnims = moveAnims,
  }
  self:write("battle_anims", out)
  return out
end

function RomExtractor:nybbles(raw, count)
  local out = {}
  for _, value in ipairs(raw) do
    out[#out + 1], out[#out + 2] = math.floor(value / 16), value % 16
  end
  while #out > count do table.remove(out) end
  return out
end

function RomExtractor:extractItems()
  self:beginStage("Items")
  local order = self.manifest.items
  local charmap = self.manifest.charmap
  local names = self:symbol("ItemNames")
  local prices = self:symbol("ItemPrices")
  local keyFlags = self:symbol("KeyItemFlags")
  local tmPrices = self:symbol("TechnicalMachinePrices")
  local decodedNames, address = {}, names.address
  for _ = 1, #order do
    local value, consumed = self.rom:readString(
      names.bank, address, charmap, 0x50, 32)
    decodedNames[#decodedNames + 1] = value
    address = address + consumed
  end
  local numItems = self.manifest.numItems
  local flags = self.rom:bytes(
    keyFlags.bank, keyFlags.address, math.floor((numItems + 7) / 8))
  local out = {}
  for index, itemId in ipairs(order) do
    local entry = {
      id = itemId, index = index, name = decodedNames[index],
      price = Rom.bcd(self.rom:bytes(
        prices.bank, prices.address + (index - 1) * 3, 3)),
      source = ("ROM:ItemNames[%d]"):format(index),
    }
    if index <= numItems
        and bit.band(flags[math.floor((index - 1) / 8) + 1],
          2 ^ ((index - 1) % 8)) ~= 0 then
      entry.keyItem = true
    end
    out[itemId] = entry
  end
  for number, move in ipairs(self.manifest.hms) do
    local itemId = "HM_" .. move
    out[itemId] = {
      id = itemId, name = ("HM%02d"):format(number), price = 0,
      machine = { kind = "HM", number = number, move = move },
      source = "ROM metadata manifest (HM mapping)",
    }
  end
  local packed = self.rom:bytes(tmPrices.bank, tmPrices.address,
    math.floor((#self.manifest.tms + 1) / 2))
  local pricesByTm = self:nybbles(packed, #self.manifest.tms)
  for number, move in ipairs(self.manifest.tms) do
    local itemId = "TM_" .. move
    out[itemId] = {
      id = itemId, name = ("TM%02d"):format(number),
      price = pricesByTm[number] * 1000,
      machine = { kind = "TM", number = number, move = move },
      source = ("ROM:TechnicalMachinePrices[%d]"):format(number),
    }
  end
  self:write("items", out)
  self:tick("Items", 1, 1)
  return out
end

function RomExtractor:extractTypeChart()
  self:beginStage("Types")
  local types = {}
  for name, value in pairs(self.manifest.constants.types) do types[value] = name end
  local effects = self:symbol("TypeEffects")
  local address, matchups = effects.address, {}
  while self.rom:byte(effects.bank, address) ~= 0xFF do
    local row = self.rom:bytes(effects.bank, address, 3)
    matchups[#matchups + 1] = {
      attacker = types[row[1]] or hex("TYPE", row[1]),
      defender = types[row[2]] or hex("TYPE", row[2]),
      multiplier = row[3],
    }
    address = address + 3
  end
  local names, seen = {}, {}
  for _, label in ipairs(self.manifest.typeNameLabels) do
    local symbol = self:symbol(label)
    local location = symbol.bank .. ":" .. symbol.address
    if not seen[location] then
      seen[location] = true
      names[#names + 1] = self.rom:readString(
        symbol.bank, symbol.address, self.manifest.charmap, 0x50, 16)
    end
  end
  local data = {
    source = "ROM:TypeEffects + TypeNames",
    matchups = matchups, names = names,
  }
  self:write("type_chart", data)
  self:tick("Types", 1, 1)
  return data
end

function RomExtractor:extractPalettes()
  self:beginStage("Color palettes")
  local order = self.manifest.paletteOrder
  local paletteTable = self:symbol("SuperPalettes")
  local function scale5(value) return round(value * 255 / 31) end
  local palettes = {}
  for index, name in ipairs(order) do
    local colors = {}
    for color = 0, 3 do
      local value = self.rom:word(paletteTable.bank,
        paletteTable.address + (index - 1) * 8 + color * 2)
      colors[#colors + 1] = {
        scale5(bit.band(value, 0x1F)),
        scale5(bit.band(bit.rshift(value, 5), 0x1F)),
        scale5(bit.band(bit.rshift(value, 10), 0x1F)),
      }
    end
    palettes[name] = colors
  end
  local monsterTable = self:symbol("MonsterPalettes")
  local monsterPalettes = {}
  for index, species in ipairs(self.manifest.dexOrder) do
    local paletteId = self.rom:byte(
      monsterTable.bank, monsterTable.address + index)
    monsterPalettes[species] = order[paletteId + 1]
  end
  local data = {
    source = "ROM:SuperPalettes + MonsterPalettes",
    palettes = palettes, order = order, pokemon = monsterPalettes,
  }
  self:write("palettes", data)
  self:tick("Color palettes", 1, 1)
  return data
end

function RomExtractor:extractIcons()
  self:beginStage("Party icons")
  local iconTable = self:symbol("MonPartyData")
  local count = #self.manifest.dexOrder
  local packed = self.rom:bytes(iconTable.bank, iconTable.address,
    math.floor((count + 1) / 2))
  local values = self:nybbles(packed, count)
  local byDex = {}
  for _, value in ipairs(values) do
    byDex[#byDex + 1] = self.manifest.iconOrder[value + 1]
      or ("ICON_%X"):format(value)
  end
  local icons = {
    MON = "assets/generated/sprites/monster.png",
    BALL = "assets/generated/sprites/poke_ball.png",
    HELIX = "assets/generated/sprites/fossil.png",
    FAIRY = "assets/generated/sprites/fairy.png",
    BIRD = "assets/generated/sprites/bird.png",
    WATER = "assets/generated/sprites/seel.png",
    BUG = "assets/generated/icons/bug.png",
    GRASS = "assets/generated/icons/plant.png",
    SNAKE = "assets/generated/icons/snake.png",
    QUADRUPED = "assets/generated/icons/quadruped.png",
  }
  local frames = {
    { "bug", "BugIconFrame1", "BugIconFrame2" },
    { "plant", "PlantIconFrame1", "PlantIconFrame2" },
    { "snake", "SnakeIconFrame1", "SnakeIconFrame2" },
    { "quadruped", "QuadrupedIconFrame1", "QuadrupedIconFrame2" },
  }
  for index, spec in ipairs(frames) do
    local raw = {}
    for labelIndex = 2, 3 do
      local symbol = self:symbol(spec[labelIndex])
      append(raw, self.rom:bytes(symbol.bank, symbol.address, 32))
    end
    local half = ImageWriter.decode2bpp(raw, 8, 32, true)
    local image = ImageWriter.blank(16, 32, 1, 1, 1, 0)
    for frame = 0, 1 do
      ImageWriter.blit(image, half, 0, frame * 16, 0, frame * 16, 8, 16)
      ImageWriter.blit(image, half, 8, frame * 16, 0, frame * 16, 8, 16, true)
    end
    self:save(image, "icons/" .. spec[1] .. ".png")
    self:tick("Party icons", index, #frames)
  end
  local data = { source = "ROM:MonPartyData", byDex = byDex, icons = icons }
  self:write("icons", data)
  return data
end

function RomExtractor:species(value)
  local order = self.manifest.constants.speciesOrder
  if value < 1 or value > #order then return hex("SPECIES", value) end
  return order[value]
end

function RomExtractor:item(value)
  local order = self.manifest.items
  if value < 1 or value > #order then return hex("ITEM", value) end
  return order[value]
end

function RomExtractor:move(value)
  if value == 0 then return nil end
  local order = self.manifest.constants.moveOrder
  if value < 1 or value > #order then return hex("MOVE", value) end
  return order[value]
end

function RomExtractor:typesById()
  local result = {}
  for name, value in pairs(self.manifest.constants.types) do
    result[value] = name
  end
  return result
end

function RomExtractor:decodeEvolutionsAndMoves(index)
  local pointerTable = self:symbol("EvosMovesPointerTable")
  local address = self.rom:word(
    pointerTable.bank, pointerTable.address + (index - 1) * 2)
  local evolutions = {}
  while true do
    local method = self.rom:byte(pointerTable.bank, address)
    address = address + 1
    if method == 0 then break end
    if method == 1 then
      local row = self.rom:bytes(pointerTable.bank, address, 2)
      address = address + 2
      evolutions[#evolutions + 1] = {
        method = "LEVEL", level = row[1], species = self:species(row[2]),
      }
    elseif method == 2 then
      local row = self.rom:bytes(pointerTable.bank, address, 3)
      address = address + 3
      evolutions[#evolutions + 1] = {
        method = "ITEM", item = self:item(row[1]), level = row[2],
        species = self:species(row[3]),
      }
    elseif method == 3 then
      local row = self.rom:bytes(pointerTable.bank, address, 2)
      address = address + 2
      evolutions[#evolutions + 1] = {
        method = "TRADE", level = row[1], species = self:species(row[2]),
      }
    else
      error(("unknown evolution method %d for species index %d")
        :format(method, index))
    end
  end

  local learnset = {}
  while true do
    local level = self.rom:byte(pointerTable.bank, address)
    address = address + 1
    if level == 0 then break end
    local move = self.rom:byte(pointerTable.bank, address)
    address = address + 1
    learnset[#learnset + 1] = { level = level, move = self:move(move) }
  end
  return evolutions, learnset
end

function RomExtractor:dexEntry(index, species)
  local pointerTable = self:symbol("PokedexEntryPointers")
  local address = self.rom:word(
    pointerTable.bank, pointerTable.address + (index - 1) * 2)
  local kind, consumed = self.rom:readString(
    pointerTable.bank, address, self.manifest.charmap, 0x50, 32)
  address = address + consumed
  local heightFt = self.rom:byte(pointerTable.bank, address)
  local heightIn = self.rom:byte(pointerTable.bank, address + 1)
  local weight = self.rom:word(pointerTable.bank, address + 2)
  address = address + 4
  assert(self.rom:byte(pointerTable.bank, address) == 0x17,
    "dex entry " .. index .. " has no TX_FAR command")
  local textAddress = self.rom:word(pointerTable.bank, address + 1)
  local textBank = self.rom:byte(pointerTable.bank, address + 3)
  local textLabel = self.manifest.dexEntryLabels[species]
    or ("_DexEntry_%02X_%04X"):format(textBank, textAddress)
  return {
    kind = kind, heightFt = heightFt, heightIn = heightIn,
    weight = weight, text = textLabel,
  }
end

function RomExtractor:extractPokemon()
  self:beginStage("Pokemon")
  local speciesOrder = self.manifest.constants.speciesOrder
  local dexBySpecies = {}
  for index, species in ipairs(self.manifest.dexOrder) do
    dexBySpecies[species] = index
  end
  local typeById = self:typesById()
  local names = self:symbol("MonsterNames")
  local baseStats = self:symbol("BaseStats")
  local mewStats = self:symbol("MewBaseStats")
  local decodedNames = {}
  for index = 1, #speciesOrder do
    decodedNames[index] = self.rom:decodeText(
      self.rom:bytes(names.bank, names.address + (index - 1) * 10, 10),
      self.manifest.charmap)
  end

  local out, writtenFront, writtenBack = {}, {}, {}
  local completed = 0
  for index, species in ipairs(speciesOrder) do
    local skip = startsWith(species, "MISSINGNO")
      or startsWith(species, "UNUSED")
      or startsWith(species, "FOSSIL_")
      or startsWith(species, "MON_GHOST")
    if not skip then
      local dex = assert(dexBySpecies[species],
        "missing dex number for " .. species)
      local row
      if species == "MEW" then
        row = self.rom:bytes(mewStats.bank, mewStats.address, 28)
      else
        row = self.rom:bytes(
          baseStats.bank, baseStats.address + (dex - 1) * 28, 28)
      end
      assert(row[1] == dex, species .. ": base stats dex mismatch")

      local level1Moves = {}
      for position = 16, 19 do
        if row[position] ~= 0 then
          level1Moves[#level1Moves + 1] = self:move(row[position])
        end
      end
      local tmhm = {}
      for moveIndex, move in ipairs(self.manifest.tmhmMoves) do
        local byte = row[21 + math.floor((moveIndex - 1) / 8)]
        if bit.band(byte, 2 ^ ((moveIndex - 1) % 8)) ~= 0 then
          tmhm[#tmhm + 1] = move
        end
      end
      local evolutions, learnset = self:decodeEvolutionsAndMoves(index)
      local asset = self.manifest.pokemonAssets[species]
      local front, back = asset.front, asset.back
      if front and not writtenFront[front] then
        local size = self:writeCompressedPic(
          asset.frontLabel, "battle/front/" .. front .. ".png")
        assert(size == math.floor(row[11] / 16),
          species .. ": front picture size mismatch")
        writtenFront[front] = true
      end
      if back and not writtenBack[back] then
        self:writeCompressedPic(
          asset.backLabel, "battle/back/" .. back .. ".png")
        writtenBack[back] = true
      end
      local speciesTypes = unique({
        typeById[row[7]] or hex("TYPE", row[7]),
        typeById[row[8]] or hex("TYPE", row[8]),
      })
      out[species] = {
        id = species, index = index, dex = dex,
        name = decodedNames[index],
        source = ("ROM:BaseStats[%d]"):format(dex),
        types = speciesTypes,
        baseStats = {
          hp = row[2], attack = row[3], defense = row[4],
          speed = row[5], special = row[6],
        },
        catchRate = row[9], baseExp = row[10],
        level1Moves = level1Moves,
        growthRate = self.manifest.growthRates[row[20] + 1],
        tmhm = tmhm, learnset = learnset, evolutions = evolutions,
        spriteFront = front
          and "assets/generated/battle/front/" .. front .. ".png" or nil,
        spriteBack = back
          and "assets/generated/battle/back/" .. back .. ".png" or nil,
        frontSize = math.floor(row[11] / 16),
        dexEntry = self:dexEntry(index, species),
      }
      completed = completed + 1
      self:tick("Pokemon", completed, #self.manifest.dexOrder + 10)
    end
  end

  for _, spec in ipairs({
    { "FossilAerodactylPic", "fossilaerodactyl" },
    { "FossilKabutopsPic", "fossilkabutops" },
    { "GhostPic", "ghost" },
  }) do
    self:writeCompressedPic(spec[1], "battle/front/" .. spec[2] .. ".png")
    completed = completed + 1
    self:tick("Pokemon", completed, #self.manifest.dexOrder + 10)
  end
  for _, spec in ipairs({
    { "RedPicBack", "redb" }, { "OldManPicBack", "oldmanb" },
  }) do
    self:writeCompressedPic(spec[1], "battle/" .. spec[2] .. ".png")
    completed = completed + 1
    self:tick("Pokemon", completed, #self.manifest.dexOrder + 10)
  end
  local balls = self:symbol("PokeballTileGraphics")
  self:write2bpp(self.rom:bytes(balls.bank, balls.address, 64),
    32, 8, "battle/balls.png", true)
  completed = completed + 1
  self:tick("Pokemon", completed, #self.manifest.dexOrder + 10)

  for _, spec in ipairs({
    { "TrainerInfoTextBoxTileGraphics", "trainer_info.png", 24, 24, false },
    { "GymLeaderFaceAndBadgeTileGraphics", "badges.png", 16, 256, true },
    { "BadgeNumbersTileGraphics", "badge_numbers.png", 16, 32, true },
    { "CircleTile", "circle_tile.png", 8, 8, true },
  }) do
    local symbol = self:symbol(spec[1])
    self:write2bpp(
      self.rom:bytes(symbol.bank, symbol.address, spec[3] * spec[4] / 4),
      spec[3], spec[4], "trainer_card/" .. spec[2], spec[5])
    completed = completed + 1
    self:tick("Pokemon", completed, #self.manifest.dexOrder + 10)
  end
  self:writeCompressedPic("RedPicFront", "trainer_card/red.png")
  self:write("pokemon", out)
  self:tick("Pokemon", #self.manifest.dexOrder + 10,
    #self.manifest.dexOrder + 10)
  return out
end

function RomExtractor:trainerParties(bank, startAddress, endAddress)
  local parties, address = {}, startAddress
  while address < endAddress do
    local first = self.rom:byte(bank, address)
    address = address + 1
    local party = {}
    if first == 0xFF then
      while true do
        local level = self.rom:byte(bank, address)
        address = address + 1
        if level == 0 then break end
        local species = self.rom:byte(bank, address)
        address = address + 1
        party[#party + 1] = {
          level = level, species = self:species(species),
        }
      end
    else
      while true do
        local species = self.rom:byte(bank, address)
        address = address + 1
        if species == 0 then break end
        party[#party + 1] = {
          level = first, species = self:species(species),
        }
      end
    end
    parties[#parties + 1] = party
  end
  assert(address == endAddress,
    ("trainer party data overran %02X:%04X"):format(bank, endAddress))
  return parties
end

function RomExtractor:extractTrainers()
  self:beginStage("Trainers")
  local order = self.manifest.trainers
  local names = self:symbol("TrainerNames")
  local pointers = self:symbol("TrainerDataPointers")
  local money = self:symbol("TrainerPicAndMoneyPointers")
  local choices = self:symbol("TrainerClassMoveChoiceModifications")
  local decodedNames, address = {}, names.address
  for _ = 1, #order do
    local name, consumed = self.rom:readString(
      names.bank, address, self.manifest.charmap, 0x50, 32)
    decodedNames[#decodedNames + 1] = name
    address = address + consumed
  end

  local aiMods = {}
  address = choices.address
  for _ = 1, #order do
    local mods = {}
    while true do
      local value = self.rom:byte(choices.bank, address)
      address = address + 1
      if value == 0 then break end
      mods[#mods + 1] = value
    end
    aiMods[#aiMods + 1] = mods
  end
  local partyStarts = {}
  for index = 0, #order - 1 do
    partyStarts[#partyStarts + 1] = self.rom:word(
      pointers.bank, pointers.address + index * 2)
  end
  local partyEnds = {}
  for index = 2, #partyStarts do partyEnds[#partyEnds + 1] = partyStarts[index] end
  partyEnds[#partyEnds + 1] = self:symbol("TrainerAI").address

  local out, written = {}, {}
  for index, label in ipairs(order) do
    local trainerId = "OPP_" .. label
    local rawMoney = self.rom:bytes(
      money.bank, money.address + (index - 1) * 5 + 2, 3)
    local picture = self.manifest.trainerPics[index]
    if picture and not written[picture.imageBase] then
      self:writeCompressedPic(picture.label,
        "battle/trainers/" .. picture.imageBase .. ".png")
      written[picture.imageBase] = true
    end
    out[trainerId] = {
      id = trainerId, index = index, name = decodedNames[index],
      source = "ROM:TrainerDataPointers",
      pic = picture and picture.path or nil,
      baseMoney = math.floor(Rom.bcd(rawMoney) / 100),
      aiMods = aiMods[index],
      parties = self:trainerParties(
        pointers.bank, partyStarts[index], partyEnds[index]),
    }
    self:tick("Trainers", index, #order)
  end
  self:write("trainers", out)
  return out
end

function RomExtractor:wildTable(bank, address)
  local grassRate = self.rom:byte(bank, address)
  address = address + 1
  local grass = { rate = grassRate, slots = {} }
  if grassRate ~= 0 then
    for _ = 1, 10 do
      local row = self.rom:bytes(bank, address, 2)
      address = address + 2
      grass.slots[#grass.slots + 1] = {
        level = row[1], species = self:species(row[2]),
      }
    end
  end
  local waterRate = self.rom:byte(bank, address)
  address = address + 1
  local water = { rate = waterRate, slots = {} }
  if waterRate ~= 0 then
    for _ = 1, 10 do
      local row = self.rom:bytes(bank, address, 2)
      address = address + 2
      water.slots[#water.slots + 1] = {
        level = row[1], species = self:species(row[2]),
      }
    end
  end
  return grass, water
end

function RomExtractor:extractEncounters()
  self:beginStage("Wild Pokemon")
  local maps = self.manifest.constants.mapOrder
  local pointers = self:symbol("WildDataPointers")
  local nothing = self:symbol("NothingWildMons")
  local out = {}
  for index, mapId in ipairs(maps) do
    local address = self.rom:word(
      pointers.bank, pointers.address + (index - 1) * 2)
    if address ~= nothing.address then
      local grass, water = self:wildTable(pointers.bank, address)
      local entry = {
        source = ("ROM:%02X:%04X"):format(pointers.bank, address),
      }
      if grass.rate ~= 0 or #grass.slots > 0 then entry.grass = grass end
      if water.rate ~= 0 or #water.slots > 0 then entry.water = water end
      out[mapId] = entry
    end
    self:tick("Wild Pokemon", index, #maps)
  end
  self:write("encounters", out)
  return out
end

local TEXT_GLYPH_OVERRIDES = {
  [0x4B] = "{_CONT}", [0x4C] = "{SCROLL}",
  [0x6D] = "{COLON}", [0xF0] = "¥",
}

function RomExtractor:textGlyph(value)
  if TEXT_GLYPH_OVERRIDES[value] then return TEXT_GLYPH_OVERRIDES[value] end
  local glyph = self.manifest.charmap[tostring(value)]
    or ("{BYTE:%02X}"):format(value)
  if glyph:sub(1, 1) == "<" and glyph:sub(-1) == ">" then
    return "{" .. glyph:sub(2, -2) .. "}"
  end
  return glyph
end

function RomExtractor:decodeTextCommands(symbol, substitutions)
  local address = symbol.address
  local pending = 1
  local out = {}
  for _ = 1, 4096 do
    local command = self.rom:byte(symbol.bank, address)
    address = address + 1
    if command == 0x50 then
      assert(pending > #substitutions,
        symbol.name .. ": unused dynamic text substitutions")
      return table.concat(out)
    elseif command == 0 then
      while true do
        local value = self.rom:byte(symbol.bank, address)
        address = address + 1
        if value == 0x50 then break end
        if value == 0x57 or value == 0x58 or value == 0x5F then
          assert(pending > #substitutions,
            symbol.name .. ": unused dynamic text substitutions")
          return table.concat(out)
        end
        out[#out + 1] = self:textGlyph(value)
      end
    elseif command == 1 or command == 2 or command == 9 then
      local expected = substitutions[pending]
      assert(expected, symbol.name .. ": missing dynamic text substitution")
      assert(command == expected[1],
        symbol.name .. ": dynamic text command mismatch")
      out[#out + 1] = expected[2]
      pending = pending + 1
      address = address + (command == 1 and 2 or 3)
    else
      error(("%s: unsupported text command $%02X")
        :format(symbol.name, command))
    end
  end
  error(symbol.name .. ": text command stream is too long")
end

function RomExtractor:extractText()
  self:beginStage("Dialogue")
  local metadata = self.manifest.text
  local texts = {}
  for index, label in ipairs(metadata.labels) do
    texts[label] = self:decodeTextCommands(
      self:symbol(label), metadata.dynamic[label] or {})
    self:tick("Dialogue", index, #metadata.labels)
  end
  local trainerHeaders = {}
  for mapLabel, headers in pairs(metadata.trainerHeaders) do
    local converted = {}
    for index, header in pairs(headers) do converted[tonumber(index)] = header end
    trainerHeaders[mapLabel] = converted
  end
  self:write("text", texts)
  self:write("text_pointers", metadata.pointers)
  self:write("trainer_headers", trainerHeaders)
  return {
    texts = texts, pointers = metadata.pointers,
    trainerHeaders = trainerHeaders,
  }
end

function RomExtractor:raw2bpp(label, width, height, relative, options)
  options = options or {}
  local expected = width * height / 4
  local length = options.storedLength or expected
  local symbol = self:symbol(label)
  local raw = self.rom:bytes(symbol.bank, symbol.address, length)
  while #raw < expected do raw[#raw + 1] = 0 end
  if options.columns then
    raw = ImageWriter.columnsToRows(raw, width / 8, height / 8)
  end
  local image = ImageWriter.decode2bpp(
    raw, width, height, options.transparent)
  if options.matte then image = ImageWriter.matteColor0(image) end
  self:save(image, relative)
  return image
end

function RomExtractor:raw1bpp(label, width, height, relative, transparent)
  local symbol = self:symbol(label)
  local raw = self.rom:bytes(
    symbol.bank, symbol.address, width * height / 8)
  local image = ImageWriter.decode1bpp(raw, width, height, transparent)
  self:save(image, relative)
  return image
end

function RomExtractor:extractField()
  self:beginStage("Interface artwork")
  local done, total = 0, 48
  local function tick()
    done = done + 1
    self:tick("Interface artwork", math.min(done, total), total)
  end

  self:raw2bpp("PokemonLogoGraphics", 128, 56,
    "title/pokemon_logo.png"); tick()
  self:raw1bpp("Version_GFX", 80, 8,
    "title/red_version.png"); tick()
  self:raw2bpp("PlayerCharacterTitleGraphics", 40, 56,
    "title/player.png", { matte = true }); tick()
  self:raw2bpp("NintendoCopyrightLogoGraphics", 152, 8,
    "title/copyright.png"); tick()
  self:raw2bpp("GameFreakLogoGraphics", 72, 8,
    "title/gamefreak_inc.png"); tick()

  local fallingStar = self:raw2bpp(
    "FallingStar", 8, 8, "intro/falling_star.png",
    { transparent = true })
  tick()
  local blink = ImageWriter.blank(8, 8, 1, 1, 1, 0)
  for y = 0, 7 do
    for x = 0, 7 do
      local r, g, b, a = fallingStar:getPixel(x, y)
      if a ~= 0 and math.abs(r - 2 / 3) < 0.001 then
        blink:setPixel(x, y, r, g, b, a)
      end
    end
  end
  self:save(blink, "intro/falling_star_blink.png"); tick()

  local gameFreak = self:symbol("GameFreakIntro")
  local presentsLength = 104 * 8 / 4
  local presents = ImageWriter.decode2bpp(
    self.rom:bytes(gameFreak.bank, gameFreak.address, presentsLength),
    104, 8, true)
  self:save(presents, "intro/gamefreak_presents.png"); tick()
  self:save(ImageWriter.decode2bpp(
    self.rom:bytes(gameFreak.bank,
      gameFreak.address + presentsLength, 16 * 24 / 4),
    16, 24, true), "intro/gamefreak_logo.png"); tick()

  local textImage = ImageWriter.blank(80, 8, 1, 1, 1, 0)
  local textTiles = { 0, 1, 2, 3, false, 4, 5, 3, 1, 6 }
  for index, tile in ipairs(textTiles) do
    if tile then
      ImageWriter.blit(textImage, presents, (index - 1) * 8, 0,
        tile * 8, 0, 8, 8)
    end
  end
  self:save(textImage, "intro/gamefreak_text.png"); tick()

  local moveTiles = self:symbol("MoveAnimationTiles1")
  local star = ImageWriter.blank(16, 16, 1, 1, 1, 0)
  for _, spec in ipairs({ { 0, 3 }, { 1, 19 } }) do
    local tile = ImageWriter.decode2bpp(self.rom:bytes(
      moveTiles.bank, moveTiles.address + spec[2] * 16, 16),
      8, 8, true)
    ImageWriter.blit(star, tile, 0, spec[1] * 8)
    ImageWriter.blit(star, tile, 8, spec[1] * 8, 0, 0, 8, 8, true)
  end
  self:save(star, "intro/big_star.png"); tick()

  local gengar = self:symbol("FightIntroBackMon")
  local gengarRaw = self.rom:bytes(
    gengar.bank, gengar.address, 96 * 16)
  local gengarTiles = {}
  for offset = 1, #gengarRaw, 16 do
    local raw = {}
    for index = offset, offset + 15 do raw[#raw + 1] = gengarRaw[index] end
    gengarTiles[#gengarTiles + 1] = ImageWriter.decode2bpp(raw, 8, 8)
  end
  for number = 1, 3 do
    local tilemap = self:symbol("GengarIntroTiles" .. number)
    local tileIds = self.rom:bytes(tilemap.bank, tilemap.address, 49)
    local pose = ImageWriter.blank(56, 56, 0, 0, 0, 0)
    for index, tileId in ipairs(tileIds) do
      ImageWriter.blit(pose, gengarTiles[tileId + 1],
        (index - 1) % 7 * 8, math.floor((index - 1) / 7) * 8)
    end
    pose = ImageWriter.matteColor0(pose)
    self:save(pose, "intro/gengar_" .. number .. ".png"); tick()
  end

  for number, label in ipairs({
    "FightIntroFrontMon", "FightIntroFrontMon2", "FightIntroFrontMon3",
  }) do
    self:raw2bpp(label, 48, 48,
      "intro/red_nidorino_" .. number .. ".png",
      { transparent = true, columns = true })
    tick()
  end
  for number = 1, 2 do
    self:writeCompressedPic(
      "ShrinkPic" .. number, "intro/shrink" .. number .. ".png")
    tick()
  end

  self:raw2bpp("SlotMachineTiles1", 128, 24,
    "slots/red_slots_1.png", { storedLength = 0x250 }); tick()
  local slotSheet = self:raw2bpp(
    "SlotMachineTiles2", 32, 48, "slots/red_slots_2.png")
  tick()
  local transparentSlots = ImageWriter.blank(32, 48, 1, 1, 1, 0)
  for y = 0, 47 do
    for x = 0, 31 do
      local r, g, b, a = slotSheet:getPixel(x, y)
      transparentSlots:setPixel(x, y, r, g, b,
        r == 1 and g == 1 and b == 1 and a == 1 and 0 or a)
    end
  end
  local slotOrder = self.manifest.field.slotSymbols.order
  local symbolSheet = ImageWriter.blank(#slotOrder * 16, 16, 1, 1, 1, 0)
  for index, name in ipairs(slotOrder) do
    local value = self.manifest.field.slotSymbols.symbols[name].tiles
    local high, low = math.floor(value / 0x100), value % 0x100
    for _, row in ipairs({ { 0, high }, { 1, low } }) do
      local x, y = row[2] % 4 * 8, math.floor(row[2] / 4) * 8
      ImageWriter.blit(symbolSheet, transparentSlots,
        (index - 1) * 16, row[1] * 8, x, y, 16, 8)
    end
  end
  self:save(symbolSheet, "slots/symbols.png"); tick()

  local emotes = ImageWriter.blank(48, 16, 1, 1, 1, 0)
  for index, label in ipairs({
    "ShockEmote", "QuestionEmote", "HappyEmote",
  }) do
    local symbol = self:symbol(label)
    local image = ImageWriter.decode2bpp(
      self.rom:bytes(symbol.bank, symbol.address, 64), 16, 16, true)
    ImageWriter.blit(emotes, image, (index - 1) * 16, 0)
  end
  self:save(emotes, "emotes.png"); tick()

  self:raw1bpp("LedgeHoppingShadow", 8, 8,
    "fx/shadow.png", true); tick()
  for _, spec in ipairs({
    { "RedFishingRodTiles", 8, 24, "fishing_rod.png" },
    { "RedFishingTilesSide", 16, 8, "red_fish_side.png" },
    { "RedFishingTilesFront", 16, 8, "red_fish_front.png" },
    { "RedFishingTilesBack", 16, 8, "red_fish_back.png" },
    { "PokeCenterFlashingMonitorAndHealBall", 8, 16, "heal_machine.png" },
    { "SSAnneSmokePuffTile", 8, 8, "smoke.png" },
  }) do
    self:raw2bpp(spec[1], spec[2], spec[3],
      "fx/" .. spec[4], { transparent = true })
    tick()
  end
  self:raw2bpp("BattleTransitionTile", 8, 8,
    "fx/battle_transition.png"); tick()
  self:raw2bpp("PokedexTileGraphics", 24, 48,
    "fx/pokedex.png"); tick()

  self:raw2bpp("HpBarAndStatusGraphics", 120, 16,
    "battle/font_battle_extra.png", { transparent = true }); tick()
  for number, label in ipairs({
    "BattleHudTiles1", "BattleHudTiles2", "BattleHudTiles3",
  }) do
    self:raw1bpp(label, 24, 8,
      "battle/battle_hud_" .. number .. ".png", true)
    tick()
  end

  local theEnd = self:symbol("TheEndGfx")
  local interleaved = self.rom:bytes(
    theEnd.bank, theEnd.address, 160)
  local reordered = {}
  for column = 0, 4 do
    for offset = 1, 16 do
      reordered[column * 16 + offset] =
        interleaved[column * 32 + offset]
      reordered[(column + 5) * 16 + offset] =
        interleaved[column * 32 + 16 + offset]
    end
  end
  self:save(ImageWriter.decode2bpp(reordered, 40, 16),
    "credits/the_end.png"); tick()
  self:raw2bpp("WorldMapTileGraphics", 32, 32,
    "townmap/tiles.png"); tick()
  self:raw1bpp("TownMapCursor", 16, 16,
    "townmap/cursor.png", true); tick()

  local data = copy(self.manifest.field)
  local adjacency = data.hiddenExtras.trashCans.adjacent
  local converted = {}
  for index, values in pairs(adjacency) do converted[tonumber(index)] = values end
  data.hiddenExtras.trashCans.adjacent = converted
  data.source = "canonical Pokemon Red ROM + bundled port metadata"
  self:write("field", data)
  self:tick("Interface artwork", total, total)
  return data
end

function RomExtractor:extractAudio()
  self:beginStage("Sound programs")
  local metadata = copy(self.manifest.audio)
  local bankOrder = { 2, 8, 31 }
  local chunks = {}
  for index, bank in ipairs(bankOrder) do
    local first = Rom.offset(bank, 0x4000) + 1
    chunks[index] = self.rom.data:sub(first, first + 0x3FFF)
    self:tick("Sound programs", index, #bankOrder + 2)
  end
  local ok, writeError = love.filesystem.createDirectory(
    "assets/generated/audio")
  if ok == false then error("could not create audio cache: " .. tostring(writeError)) end
  ok, writeError = love.filesystem.write(
    "assets/generated/audio/programs.bin", table.concat(chunks))
  if not ok then error("could not write audio programs: " .. tostring(writeError)) end

  local songs = {}
  for name, header in pairs(metadata.musicHeaders) do
    songs[name] = header
  end
  local cries = {}
  local cryData = metadata.cryData
  for index, species in ipairs(self.manifest.constants.speciesOrder) do
    local row = self.rom:bytes(
      cryData.bank, cryData.address + (index - 1) * 3, 3)
    if not startsWith(species, "MISSINGNO")
        and not startsWith(species, "UNUSED") then
      cries[species] = {
        header = metadata.cryHeaders[tostring(row[1])],
        pitch = row[2],
        length = row[3],
      }
    end
  end
  metadata.runtime = true
  metadata.programFile = "assets/generated/audio/programs.bin"
  metadata.bankOrder = bankOrder
  metadata.songs = songs
  metadata.sfx = metadata.sfxHeaders
  metadata.cries = cries
  metadata.source = "canonical Pokemon Red ROM sound programs"
  self:write("audio", metadata)
  self:tick("Sound programs", #bankOrder + 2, #bankOrder + 2)
  return metadata
end

function RomExtractor:run()
  local results = {}
  results.constants = self:extractConstants()
  results.tilesets = self:extractTilesets()
  results.maps = self:extractMaps()
  results.font = self:extractFont()
  results.sprites = self:extractSprites()
  results.moves = self:extractMoves()
  results.battle_anims = self:extractBattleAnimations()
  results.items = self:extractItems()
  results.type_chart = self:extractTypeChart()
  results.palettes = self:extractPalettes()
  results.icons = self:extractIcons()
  results.pokemon = self:extractPokemon()
  results.trainers = self:extractTrainers()
  results.encounters = self:extractEncounters()
  results.text = self:extractText()
  results.field = self:extractField()
  results.audio = self:extractAudio()
  if self.progress then
    self.progress(STAGE_COUNT, STAGE_COUNT, "Ready", 1, 1)
  end
  return results
end

return RomExtractor
