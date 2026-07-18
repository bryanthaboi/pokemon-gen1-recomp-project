local Rom = {}
Rom.__index = Rom

local BANK_SIZE = 0x4000

function Rom.new(data)
  assert(type(data) == "string", "ROM data must be a string")
  return setmetatable({ data = data }, Rom)
end

function Rom.offset(bank, address)
  if bank == 0 then
    assert(address >= 0 and address < BANK_SIZE,
      ("ROM0 address out of range: $%04X"):format(address))
    return address
  end
  assert(address >= BANK_SIZE and address < BANK_SIZE * 2,
    ("bank %02X address out of range: $%04X"):format(bank, address))
  return bank * BANK_SIZE + address - BANK_SIZE
end

function Rom:byte(bank, address)
  local value = self.data:byte(Rom.offset(bank, address) + 1)
  assert(value, ("ROM read past end at %02X:%04X"):format(bank, address))
  return value
end

function Rom:word(bank, address)
  return self:byte(bank, address) + self:byte(bank, address + 1) * 0x100
end

function Rom:bytes(bank, address, length)
  local first = Rom.offset(bank, address) + 1
  local last = first + length - 1
  assert(last <= #self.data,
    ("ROM read past end at %02X:%04X + %d"):format(bank, address, length))
  local out = {}
  for index = 1, length do
    out[index] = self.data:byte(first + index - 1)
  end
  return out
end

function Rom:decodeText(raw, charmap, stop)
  local out = {}
  stop = stop or 0x50
  for _, value in ipairs(raw) do
    if value == stop then break end
    out[#out + 1] = charmap[tostring(value)]
      or ("{BYTE:%02X}"):format(value)
  end
  return table.concat(out)
end

function Rom:readString(bank, address, charmap, stop, maxLength)
  local out = {}
  stop = stop or 0x50
  maxLength = maxLength or 4096
  for offset = 0, maxLength - 1 do
    local value = self:byte(bank, address + offset)
    if value == stop then return table.concat(out), offset + 1 end
    out[#out + 1] = charmap[tostring(value)]
      or ("{BYTE:%02X}"):format(value)
  end
  error(("unterminated string at %02X:%04X"):format(bank, address))
end

function Rom.bcd(raw)
  local value = 0
  for _, byte in ipairs(raw) do
    value = value * 100 + math.floor(byte / 16) * 10 + byte % 16
  end
  return value
end

local BitReader = {}
BitReader.__index = BitReader

function BitReader.new(data)
  return setmetatable({ data = data, byte = 1, bit = 7 }, BitReader)
end

function BitReader:read(count)
  local value = 0
  for _ = 1, count or 1 do
    local byte = self.data[self.byte]
    if not byte then error("compressed picture ended unexpectedly") end
    value = value * 2 + math.floor(byte / 2 ^ self.bit) % 2
    self.bit = self.bit - 1
    if self.bit < 0 then
      self.byte = self.byte + 1
      self.bit = 7
    end
  end
  return value
end

local function fillPicPlane(reader, width)
  local mode = reader:read()
  local groupCount = width * width * 0x20
  local groups = {}
  while #groups < groupCount do
    if mode ~= 0 then
      while #groups < groupCount do
        local group = reader:read(2)
        if group == 0 then break end
        groups[#groups + 1] = group
      end
    else
      local prefix = 0
      while reader:read() ~= 0 do
        prefix = prefix + 1
        if prefix >= 16 then error("invalid compressed picture zero run") end
      end
      local zeroCount = 2 ^ (prefix + 1) - 1 + reader:read(prefix + 1)
      for _ = 1, math.min(zeroCount, groupCount - #groups) do
        groups[#groups + 1] = 0
      end
    end
    mode = 1 - mode
  end

  local reordered = {}
  for y = 0, width - 1 do
    for x = 0, width * 8 - 1 do
      for group = 0, 3 do
        local source = (y * 4 + group) * width * 8 + x
        reordered[#reordered + 1] = groups[source + 1]
      end
    end
  end
  local packed = {}
  for index = 0, width * width * 8 - 1 do
    local start = index * 4
    packed[index + 1] = reordered[start + 1] * 0x40
      + reordered[start + 2] * 0x10
      + reordered[start + 3] * 4
      + reordered[start + 4]
  end
  return packed
end

local PIC_CODES = {
  { 0x0, 0x1, 0x3, 0x2, 0x7, 0x6, 0x4, 0x5,
    0xF, 0xE, 0xC, 0xD, 0x8, 0x9, 0xB, 0xA },
  { 0xF, 0xE, 0xC, 0xD, 0x8, 0x9, 0xB, 0xA,
    0x0, 0x1, 0x3, 0x2, 0x7, 0x6, 0x4, 0x5 },
}

local function unfilterPicPlane(plane, width)
  for x = 0, width * 8 - 1 do
    local bit = 0
    for y = 0, width - 1 do
      local index = y * width * 8 + x + 1
      local high = PIC_CODES[bit + 1][math.floor(plane[index] / 16) + 1]
      bit = high % 2
      local low = PIC_CODES[bit + 1][plane[index] % 16 + 1]
      bit = low % 2
      plane[index] = high * 16 + low
    end
  end
end

local function transposePicTiles(data, width)
  local tileCount = width * width
  for index = 0, tileCount - 1 do
    local other = (index * width + math.floor(index / width)) % tileCount
    if index < other then
      for offset = 1, 16 do
        local left = index * 16 + offset
        local right = other * 16 + offset
        data[left], data[right] = data[right], data[left]
      end
    end
  end
end

function Rom.decompressPic(data)
  local reader = BitReader.new(data)
  local width, height = reader:read(4), reader:read(4)
  if width == 0 or width ~= height then
    error(("compressed picture is not a non-empty square (%dx%d)")
      :format(width, height))
  end

  local order = reader:read()
  local planes = {}
  planes[order + 1] = fillPicPlane(reader, width)
  local mode = reader:read()
  if mode ~= 0 then mode = mode + reader:read() end
  planes[(1 - order) + 1] = fillPicPlane(reader, width)

  unfilterPicPlane(planes[order + 1], width)
  if mode ~= 1 then unfilterPicPlane(planes[(1 - order) + 1], width) end
  if mode ~= 0 then
    for index = 1, width * width * 8 do
      planes[(1 - order) + 1][index] =
        bit.bxor(planes[(1 - order) + 1][index], planes[order + 1][index])
    end
  end

  local output = {}
  for index = 1, width * width * 8 do
    output[#output + 1] = planes[1][index]
    output[#output + 1] = planes[2][index]
  end
  transposePicTiles(output, width)
  return output, width
end

return Rom
