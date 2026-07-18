-- The into-battle transition (engine/battle/battle_transitions.asm):
-- one of the original's eight wipes selected by three bits,  trainer
-- battle (bit 0), enemy at least 3 levels above the lead (bit 1),
-- dungeon map (bit 2):
--   %000 DoubleCircle  %001 Spiral(in)  %010 Circle    %011 Spiral(out)
--   %100 HStripes      %101 Shrink      %110 VStripes  %111 Split
-- Only the two circle wipes flash the screen first (only they call
-- BattleTransition_FlashScreen); the spiral runs inward unless the
-- enemy is stronger (wBattleTransitionSpiralDirection).
-- Pushed above the overworld; pops itself and runs onDone at the end.

local BattleTransition = {}
BattleTransition.__index = BattleTransition
BattleTransition.isOpaque = false -- draws over the frozen overworld

-- BattleTransition_FlashScreenPalettes: fade to black and back, then to
-- white and back; each palette held 2 frames, whole sequence played 3
-- times. Positive = black overlay strength, negative = white.
local FLASH_STEPS = { 1 / 3, 2 / 3, 1, 2 / 3, 1 / 3, 0,
                      -1 / 3, -2 / 3, -1, -2 / 3, -1 / 3, 0 }
local FLASH_HOLD = 2   -- frames per palette step
local FLASH_CYCLES = 3

local TILE = 8
local COLS, ROWS = 160 / TILE, 144 / TILE -- 20 x 18 tiles

-- outward spiral (%011): BattleTransition_OutwardSpiral_ walks from
-- (10,10) counterclockwise (right/up/left/down), turning whenever the
-- tile on its outer side is unfilled; 120 frames x 3 fills = 360 fills
-- on linear tilemap memory. At the screen edges the walk reads (and
-- fills) adjacent WRAM, so the left column and part of the top row stay
-- unfilled until the final blackout,  reproduced here by tracking those
-- cells but not drawing them.
local function outwardSpiralOrder()
  local order, filled = {}, {}
  local addr = 10 * COLS + 10 -- hlcoord 10,10
  local dir = 3               -- 0 up / 1 left / 2 down / 3 right
  local checkOff = { [0] = -1, [1] = COLS, [2] = 1, [3] = -COLS }
  local moveOff = { [0] = -COLS, [1] = -1, [2] = COLS, [3] = 1 }
  for _ = 1, COLS * ROWS do
    local checked = addr + checkOff[dir]
    if not filled[checked] then
      addr = checked
      dir = (dir + 1) % 4
    else
      addr = addr + moveOff[dir]
    end
    if not filled[addr] then
      filled[addr] = true
      if addr >= 0 and addr < COLS * ROWS then
        order[#order + 1] = { addr % COLS, math.floor(addr / COLS) }
      end
    end
  end
  return order
end

-- inward spiral (%001): BattleTransition_InwardSpiral starts at (0,0)
-- and walks the perimeter counterclockwise,  down the left edge, right
-- along the bottom, up the right edge, left along the top,  spiraling
-- in; 359 fills, the center tile is left for the final blackout
local function inwardSpiralOrder()
  local order = {}
  local x, y = 0, 0
  local function run(dx, dy, n)
    for _ = 1, n do
      order[#order + 1] = { x, y }
      x, y = x + dx, y + dy
    end
  end
  run(0, 1, 17) -- SCREEN_HEIGHT - 1
  local c = 18
  while true do
    c = c + 1
    run(1, 0, c)  -- right
    c = c - 2
    run(0, -1, c) -- up
    c = c + 1
    run(-1, 0, c) -- left
    c = c - 2
    if c == 0 then break end
    run(0, 1, c)  -- down
  end
  return order
end

-- sweep order (the Circle wipes): tiles sorted by angle from the center.
-- pokered sweeps counterclockwise starting at the right edge middle
-- (BattleTransition_HalfCircle1 runs (18,6) up over the top to (1,6);
-- HalfCircle2 continues (1,11) down under the bottom back to (18,11)).
-- arms = 1 (Circle, halves in sequence) or 2 (DoubleCircle, both halves
-- at once, so opposite arms)
local function sweepOrder(arms)
  local cx, cy = COLS / 2, ROWS / 2
  local tiles = {}
  for y = 0, ROWS - 1 do
    for x = 0, COLS - 1 do
      local a = math.atan2(cy - (y + 0.5), x + 0.5 - cx)
      if a < 0 then a = a + 2 * math.pi end
      if arms == 2 then a = a % math.pi end
      tiles[#tiles + 1] = { x, y, a }
    end
  end
  table.sort(tiles, function(p, q) return p[3] < q[3] end)
  return tiles
end

local ORDERS = {} -- cached per style

local function orderFor(style)
  if not ORDERS[style] then
    if style == "spiralout" then
      ORDERS[style] = outwardSpiralOrder()
    elseif style == "spiralin" then
      ORDERS[style] = inwardSpiralOrder()
    elseif style == "circle" then
      ORDERS[style] = sweepOrder(1)
    elseif style == "doublecircle" then
      ORDERS[style] = sweepOrder(2)
    end
  end
  return ORDERS[style]
end

-- opts: trainer (bool), stronger (bool), dungeon (bool)
function BattleTransition.new(game, onDone, opts)
  local self = setmetatable({}, BattleTransition)
  self.game = game
  self.onDone = onDone
  self.t = 0
  opts = opts or {}
  local bits = (opts.trainer and 1 or 0) + (opts.stronger and 2 or 0)
             + (opts.dungeon and 4 or 0)
  self.style = ({ [0] = "doublecircle", "spiralin", "circle", "spiralout",
                  "hstripes", "shrink", "vstripes", "split" })[bits]
  -- only the circle wipes flash first (battle_transitions.asm:585,628)
  self.phase = (self.style == "circle" or self.style == "doublecircle")
               and "flash" or "wipe"
  self.wipeLen = (self.style == "spiralin" or self.style == "spiralout"
                  or self.style == "circle"
                  or self.style == "doublecircle") and 40 or 24
  return self
end

function BattleTransition:update(dt)
  self.t = self.t + 1
  if self.phase == "flash" then
    if self.t >= FLASH_CYCLES * #FLASH_STEPS * FLASH_HOLD then
      self.phase = "wipe"
      self.t = 0
    end
  else
    if self.t >= self.wipeLen + 6 then
      self.game.stack:pop()
      if self.onDone then self.onDone() end
    end
  end
end

function BattleTransition:draw()
  if self.phase == "flash" then
    local step = math.floor(self.t / FLASH_HOLD) % #FLASH_STEPS + 1
    local v = FLASH_STEPS[step]
    if v ~= 0 then
      local shade = v > 0 and 0 or 1
      love.graphics.setColor(shade, shade, shade, math.abs(v))
      love.graphics.rectangle("fill", 0, 0, 160, 144)
      love.graphics.setColor(1, 1, 1, 1)
    end
    return
  end

  love.graphics.setColor(0, 0, 0, 1)
  local prog = math.min(1, self.t / self.wipeLen)
  local style = self.style

  local order = orderFor(style)
  if order then
    -- tile-order wipes: spiral / circle sweeps
    local n = math.floor(#order * prog)
    for i = 1, n do
      local c = order[i]
      love.graphics.rectangle("fill", c[1] * TILE, c[2] * TILE, TILE, TILE)
    end
  elseif style == "hstripes" then
    -- interlaced rows wipe from alternating sides
    local w = math.floor(160 * prog)
    for row = 0, ROWS - 1 do
      local y = row * TILE
      if row % 2 == 0 then
        love.graphics.rectangle("fill", 0, y, w, TILE)
      else
        love.graphics.rectangle("fill", 160 - w, y, w, TILE)
      end
    end
  elseif style == "vstripes" then
    -- interlaced columns wipe from alternating ends
    local h = math.floor(144 * prog)
    for col = 0, COLS - 1 do
      local x = col * TILE
      if col % 2 == 0 then
        love.graphics.rectangle("fill", x, 0, TILE, h)
      else
        love.graphics.rectangle("fill", x, 144 - h, TILE, h)
      end
    end
  elseif style == "shrink" then
    -- the image squashes toward the middle: the asm shifts rows and
    -- columns inward in the same loop, so bars close from all four
    -- edges at once
    local h = math.floor(72 * prog)
    local w = math.floor(80 * prog)
    love.graphics.rectangle("fill", 0, 0, 160, h)
    love.graphics.rectangle("fill", 0, 144 - h, 160, h)
    love.graphics.rectangle("fill", 0, 0, w, 144)
    love.graphics.rectangle("fill", 160 - w, 0, w, 144)
  else -- split: the quarters tear apart from the middle; the asm shifts
    -- rows and columns outward each loop, so a black cross grows from
    -- the center in both axes at once
    local h = math.floor(72 * prog)
    local w = math.floor(80 * prog)
    love.graphics.rectangle("fill", 0, 72 - h, 160, h * 2)
    love.graphics.rectangle("fill", 80 - w, 0, w * 2, 144)
  end

  if prog >= 1 then
    love.graphics.rectangle("fill", 0, 0, 160, 144)
  end
  love.graphics.setColor(1, 1, 1, 1)
end

return BattleTransition
