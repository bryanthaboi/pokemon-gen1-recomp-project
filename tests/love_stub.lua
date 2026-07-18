-- Minimal love API stub so game logic can run headless under plain Lua
-- (lua5.4 tests/run_tests.lua).  Graphics calls are no-ops that record
-- enough state for assertions.

local stub = {}

local function noop() end

local Image = {}
Image.__index = Image
function Image:getDimensions() return self.w, self.h end
function Image:getWidth() return self.w end
function Image:getHeight() return self.h end

-- read PNG dimensions from the file header (no decoder needed)
local function pngSize(path)
  local f = io.open(path, "rb")
  if not f then return 8, 8 end
  local header = f:read(24)
  f:close()
  if not header or #header < 24 then return 8, 8 end
  local function be32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
  end
  return be32(header, 17), be32(header, 21)
end

local files = {} -- in-memory love.filesystem

stub.graphics = {
  newImage = function(path)
    local w, h = pngSize(path)
    return setmetatable({ w = w, h = h, path = path }, Image)
  end,
  newQuad = function(x, y, w, h) return { x = x, y = y, w = w, h = h } end,
  newCanvas = function(w, h)
    return setmetatable({ w = w, h = h, setFilter = noop }, Image)
  end,
  newSpriteBatch = function(image, size)
    local batch = { image = image, sprites = {} }
    function batch:add(quad, x, y) table.insert(self.sprites, { quad, x, y }) end
    return batch
  end,
  draw = noop, rectangle = noop, setColor = noop, clear = noop,
  setCanvas = noop, setDefaultFilter = noop, print = noop,
  -- coordinate-transform + state stack used by the tilt-mode upright pass
  -- (billboards); plain no-ops here (tests that need to observe them swap
  -- in their own recorders, e.g. tests/parity_tilt.lua)
  push = noop, pop = noop, translate = noop, scale = noop,
  rotate = noop, origin = noop, setShader = noop, setScissor = noop,
  getDimensions = function() return 640, 576 end,
}

stub.math = {
  random = function(a, b)
    if a == nil then return math.random() end
    if b == nil then return math.random(a) end
    return math.random(a, b)
  end,
}

stub.filesystem = {
  write = function(name, content) files[name] = content return true end,
  read = function(name) return files[name] end,
  getInfo = function(name) return files[name] and { type = "file" } or nil end,
  load = function(name)
    if not files[name] then return nil, "no file" end
    return load(files[name], name)
  end,
}

stub.keyboard = { isDown = function() return false end }

stub.mouse = { getPosition = function() return 0, 0 end }

stub.timer = { getTime = function() return 0 end }

return stub
