local ImageWriter = {}

local SHADES = {
  { 1, 1, 1, 1 },
  { 2 / 3, 2 / 3, 2 / 3, 1 },
  { 1 / 3, 1 / 3, 1 / 3, 1 },
  { 0, 0, 0, 1 },
}

local function assertDimensions(raw, width, height, bits)
  assert(width % 8 == 0 and height % 8 == 0,
    ("%dbpp dimensions must be tile-aligned: %dx%d")
      :format(bits, width, height))
  local expected = width * height * bits / 8
  assert(#raw == expected,
    ("%dbpp payload is %d bytes, expected %d")
      :format(bits, #raw, expected))
end

function ImageWriter.decode2bpp(raw, width, height, transparent)
  assertDimensions(raw, width, height, 2)
  local image = love.image.newImageData(width, height)
  local tilesPerRow = width / 8
  for tile = 0, #raw / 16 - 1 do
    local tileX = tile % tilesPerRow * 8
    local tileY = math.floor(tile / tilesPerRow) * 8
    for y = 0, 7 do
      local low = raw[tile * 16 + y * 2 + 1]
      local high = raw[tile * 16 + y * 2 + 2]
      for x = 0, 7 do
        local divisor = 2 ^ (7 - x)
        local shade = math.floor(high / divisor) % 2 * 2
          + math.floor(low / divisor) % 2
        local color = SHADES[shade + 1]
        local alpha = color[4]
        if transparent and shade == 0 then alpha = 0 end
        image:setPixel(tileX + x, tileY + y,
          color[1], color[2], color[3], alpha)
      end
    end
  end
  return image
end

function ImageWriter.decode1bpp(raw, width, height, transparent)
  assertDimensions(raw, width, height, 1)
  local image = love.image.newImageData(width, height)
  local tilesPerRow = width / 8
  for tile = 0, #raw / 8 - 1 do
    local tileX = tile % tilesPerRow * 8
    local tileY = math.floor(tile / tilesPerRow) * 8
    for y = 0, 7 do
      local row = raw[tile * 8 + y + 1]
      for x = 0, 7 do
        local filled = math.floor(row / 2 ^ (7 - x)) % 2 ~= 0
        local value = filled and 0 or 1
        local alpha = 1
        if transparent and not filled then alpha = 0 end
        image:setPixel(tileX + x, tileY + y,
          value, value, value, alpha)
      end
    end
  end
  return image
end

function ImageWriter.blank(width, height, r, g, b, a)
  local image = love.image.newImageData(width, height)
  image:mapPixel(function() return r or 0, g or 0, b or 0, a or 0 end)
  return image
end

function ImageWriter.blit(target, source, targetX, targetY,
    sourceX, sourceY, width, height, flipX)
  sourceX, sourceY = sourceX or 0, sourceY or 0
  width, height = width or source:getWidth(), height or source:getHeight()
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local sampleX = flipX and sourceX + width - 1 - x or sourceX + x
      target:setPixel(targetX + x, targetY + y,
        source:getPixel(sampleX, sourceY + y))
    end
  end
end

function ImageWriter.matteColor0(image)
  local width, height = image:getDimensions()
  local queueX, queueY, head = {}, {}, 1
  local seen = {}
  local function add(x, y)
    local key = y * width + x
    if seen[key] then return end
    local r, g, b, a = image:getPixel(x, y)
    if r == 1 and g == 1 and b == 1 and a == 1 then
      seen[key] = true
      queueX[#queueX + 1], queueY[#queueY + 1] = x, y
    end
  end
  for x = 0, width - 1 do add(x, 0); add(x, height - 1) end
  for y = 0, height - 1 do add(0, y); add(width - 1, y) end
  while head <= #queueX do
    local x, y = queueX[head], queueY[head]
    head = head + 1
    image:setPixel(x, y, 1, 1, 1, 0)
    if x > 0 then add(x - 1, y) end
    if x + 1 < width then add(x + 1, y) end
    if y > 0 then add(x, y - 1) end
    if y + 1 < height then add(x, y + 1) end
  end
  return image
end

function ImageWriter.columnsToRows(raw, tilesWide, tilesHigh, bytesPerTile)
  bytesPerTile = bytesPerTile or 16
  local out = {}
  for y = 0, tilesHigh - 1 do
    for x = 0, tilesWide - 1 do
      local source = (x * tilesHigh + y) * bytesPerTile
      local target = (y * tilesWide + x) * bytesPerTile
      for offset = 1, bytesPerTile do
        out[target + offset] = raw[source + offset]
      end
    end
  end
  return out
end

function ImageWriter.save(image, path)
  local ok, fileData = pcall(image.encode, image, "png")
  if not ok then error("could not encode " .. path .. ": " .. tostring(fileData)) end
  -- CacheFs routes this to the OS save directory (normal builds) or straight
  -- into the game folder (portable installs), creating parent directories as
  -- needed.  io.* needs the bytes as a string; love.filesystem would also
  -- take the FileData, but getString() keeps one code path.
  local CacheFs = require("src.import.CacheFs")
  local written, writeError = CacheFs.write(path, fileData:getString())
  if not written then
    error("could not write " .. path .. ": " .. tostring(writeError))
  end
  return fileData
end

return ImageWriter
