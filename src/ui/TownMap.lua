-- TOWN MAP viewer (engine/menus/town_map.asm; location data from
-- data/maps/town_map_entries.asm via the extractor's field.townMap).
--
-- Grid mode (when field.townMap provides coordinates): the 20x18-tile
-- Kanto map with a filled square per known location -- routes lighter,
-- towns darker -- a blinking cursor the d-pad snaps between locations,
-- the selected name in a banner up top, and the player's current
-- location blinking.  List mode (townMap data missing): up/down through
-- an ordered list of fly towns instead.  B closes.

local Font = require("src.render.Font")
local Sound = require("src.core.Sound")

local TownMap = {}
TownMap.__index = TownMap
TownMap.isOpaque = true

-- SGB: PalPacket_TownMap, whole screen
function TownMap:sgbPalettes(game)
  return require("src.render.PaletteFX").wholeNamed(game.data, "TOWNMAP")
end

-- pull x/y out of a townMap entry regardless of the exact shape the
-- extractor settled on ({x=,y=}, {col=,row=} or {coords={x=,y=}})
local function entryCoords(e)
  if type(e) ~= "table" then return nil end
  local c = e.coords or e
  local x = tonumber(c.x or c.col)
  local y = tonumber(c.y or c.row)
  return x, y
end

local function entryName(e, mapId)
  local name = type(e) == "table" and (e.name or e.label) or nil
  return name or mapId:gsub("_", " ")
end

local function isRoute(loc)
  return loc.name:find("ROUTE", 1, true) ~= nil
end

-- Build the ordered location list.  Grid mode dedupes shared entries
-- (interior maps point at their town's square); list mode falls back to
-- the fly towns so the screen still works without townMap data.
local function buildLocations(game)
  local field = game.data.field or {}
  local townMap = field.townMap
  -- the extractor nests the per-map entries under .locations
  if type(townMap) == "table" and type(townMap.locations) == "table" then
    townMap = townMap.locations
  end
  local locs, byMap = {}, {}
  if type(townMap) == "table" and next(townMap) then
    local seen = {}
    for mapId, e in pairs(townMap) do
      local x, y = entryCoords(e)
      if x and y then
        local name = entryName(e, mapId)
        local key = ("%s:%d:%d"):format(name, x, y)
        local loc = seen[key]
        if not loc then
          loc = { name = name, x = x, y = y }
          seen[key] = loc
          table.insert(locs, loc)
        end
        byMap[mapId] = loc
      end
    end
    if #locs > 0 then
      table.sort(locs, function(a, b)
        if a.y ~= b.y then return a.y < b.y end
        if a.x ~= b.x then return a.x < b.x end
        return a.name < b.name
      end)
      return locs, byMap, "grid"
    end
  end
  -- fallback: towns from the fly order (deduped, outdoor maps only)
  local Map = require("src.world.Map")
  local seen = {}
  for _, mapId in ipairs(field.flyOrder or {}) do
    local def = game.data.maps and game.data.maps[mapId]
    if not seen[mapId] and def and Map.isOutdoor(def) then
      seen[mapId] = true
      local loc = { name = mapId:gsub("_", " ") }
      table.insert(locs, loc)
      byMap[mapId] = loc
    end
  end
  if #locs == 0 then locs = { { name = "KANTO" } } end
  return locs, byMap, "list"
end

-- load the extracted Kanto background (nil on stale asset builds)
local function loadBackground(game)
  local tm = (game.data.field or {}).townMap or {}
  local bg = tm.background
  if not (bg and bg.map and bg.tiles) then return nil end
  local ok, img = pcall(love.graphics.newImage, bg.tiles.path)
  if not ok then return nil end
  local quads = {}
  local iw, ih = img:getDimensions()
  local per = iw / 8
  for i = 0, per * (ih / 8) - 1 do
    quads[i] = love.graphics.newQuad((i % per) * 8,
                                     math.floor(i / per) * 8, 8, 8, iw, ih)
  end
  local cursor
  if bg.cursor then
    local okc, c = pcall(love.graphics.newImage, bg.cursor.path)
    cursor = okc and c or nil
  end
  return { img = img, quads = quads, map = bg.map, cursor = cursor }
end

-- town-map grid -> screen pixels (TownMapCoordsToOAMCoords: the 16x16
-- nybble grid sits 2 tiles in and 1 tile down on the 20x18 screen)
local function markerXY(loc)
  return loc.x * 8 + 16, loc.y * 8 + 8
end

-- opts.nestSpecies: the Pokédex AREA screen (LoadTownMap_Nest) --
-- blink a nest icon on every map whose wild slots hold the species
function TownMap.new(game, opts)
  opts = opts or {}
  local self = setmetatable({}, TownMap)
  self.game = game
  self.bg = loadBackground(game)
  self.locs, self.byMap, self.mode = buildLocations(game)
  if opts.nestSpecies then
    self.nestSpecies = opts.nestSpecies
    self.nests = {}
    local seen = {}
    for mapId, enc in pairs(game.data.encounters or {}) do
      local found = false
      for _, group in pairs(enc) do
        for _, slot in ipairs(group.slots or {}) do
          if slot.species == opts.nestSpecies then found = true break end
        end
        if found then break end
      end
      local loc = found and self.byMap[mapId]
      if loc and not seen[loc] then
        seen[loc] = true
        table.insert(self.nests, loc)
      end
    end
    -- field.townMap.nest lifts the icon path out of the engine
    local nest = ((game.data.field or {}).townMap or {}).nest
    local ok, img = pcall(love.graphics.newImage,
                          (nest and nest.path)
                          or "assets/generated/townmap/nest.png")
    self.nestIcon = ok and img or nil
  end
  -- the player's current location (guard: overworld may not be running)
  local mapId = game.overworld and game.overworld.map and game.overworld.map.id
  self.playerLoc = mapId and self.byMap[mapId] or nil
  self.sel = 1
  for i, loc in ipairs(self.locs) do
    if loc == self.playerLoc then self.sel = i break end
  end
  self.blink = 0
  return self
end

-- snap the cursor to the nearest location in the pressed direction
function TownMap:moveGrid(dx, dy)
  local cur = self.locs[self.sel]
  local best, bestScore
  for i, loc in ipairs(self.locs) do
    if i ~= self.sel then
      local ddx, ddy = loc.x - cur.x, loc.y - cur.y
      local fwd = ddx * dx + ddy * dy       -- progress along the d-pad axis
      local side = math.abs(ddx * dy) + math.abs(ddy * dx)
      if fwd > 0 then
        local score = fwd + side * 3        -- prefer staying on-axis
        if not best or score < bestScore then best, bestScore = i, score end
      end
    end
  end
  if best then
    self.sel = best
    Sound.play(self.game.data, "Tink")
  end
end

function TownMap:moveList(step)
  local n = #self.locs
  if n < 2 then return end
  self.sel = (self.sel - 1 + step) % n + 1
  Sound.play(self.game.data, "Tink")
end

function TownMap:update(dt)
  self.blink = (self.blink + 1) % 32
  local input = self.game.input
  if input:wasPressed("b") then
    Sound.play(self.game.data, "Press_AB")
    self.game.stack:pop()
    return
  end
  if self.nestSpecies then
    if input:wasPressed("a") then
      Sound.play(self.game.data, "Press_AB")
      self.game.stack:pop()
    end
  elseif self.mode == "grid" then
    if input:wasPressed("up") then self:moveGrid(0, -1)
    elseif input:wasPressed("down") then self:moveGrid(0, 1)
    elseif input:wasPressed("left") then self:moveGrid(-1, 0)
    elseif input:wasPressed("right") then self:moveGrid(1, 0)
    end
  else
    if input:wasPressed("up") then self:moveList(-1)
    elseif input:wasPressed("down") then self:moveList(1)
    end
  end
end

local function drawSquare(loc)
  if isRoute(loc) then
    love.graphics.setColor(0.62, 0.62, 0.62, 1)  -- routes lighter
  else
    love.graphics.setColor(0.25, 0.25, 0.25, 1)  -- towns darker
  end
  love.graphics.rectangle("fill", loc.x * 8 + 1, loc.y * 8 + 1, 6, 6)
end

function TownMap:draw()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 144)

  local selected = self.locs[self.sel]
  if self.mode == "grid" and self.bg then
    -- the real Kanto map (LoadTownMap's RLE tilemap)
    for i, t in ipairs(self.bg.map) do
      local col, row = (i - 1) % 20, math.floor((i - 1) / 20)
      love.graphics.draw(self.bg.img, self.bg.quads[t], col * 8, row * 8)
    end
    if self.nestSpecies then
      -- AREA mode: blinking nests, the species name up top
      if self.blink % 16 < 10 then
        for _, loc in ipairs(self.nests) do
          local x, y = markerXY(loc)
          if self.nestIcon then
            love.graphics.draw(self.nestIcon, x, y)
          else
            love.graphics.setColor(0, 0, 0, 1)
            love.graphics.rectangle("fill", x + 2, y + 2, 4, 4)
            love.graphics.setColor(1, 1, 1, 1)
          end
        end
      end
      love.graphics.rectangle("fill", 0, 0, 160, 8)
      love.graphics.setColor(0, 0, 0, 1)
      local def = self.game.data.pokemon[self.nestSpecies]
      local name = def and def.name or self.nestSpecies
      Font.draw(#self.nests > 0 and (name .. "'s NEST")
                or (name .. " AREA UNKNOWN"), 8, 0)
      love.graphics.setColor(1, 1, 1, 1)
      return
    end
    -- the player's current location blinks (slow phase)
    if self.playerLoc and self.blink < 20 then
      local x, y = markerXY(self.playerLoc)
      love.graphics.setColor(0.75, 0.1, 0.1, 1)
      love.graphics.rectangle("fill", x + 2, y + 2, 4, 4)
      love.graphics.setColor(1, 1, 1, 1)
    end
    -- blinking cursor on the selected location
    if selected and self.blink % 16 < 10 then
      local x, y = markerXY(selected)
      if self.bg.cursor then
        love.graphics.draw(self.bg.cursor, x, y)
      else
        love.graphics.setColor(0, 0, 0, 1)
        love.graphics.rectangle("line", x + 0.5, y + 0.5, 7, 7)
        love.graphics.setColor(1, 1, 1, 1)
      end
    end
    -- the name strip on row 0 (DisplayTownMap: ClearScreenArea + name)
    love.graphics.rectangle("fill", 0, 0, 160, 8)
    love.graphics.setColor(0, 0, 0, 1)
    if selected then Font.draw(selected.name, 8, 0) end
    love.graphics.setColor(1, 1, 1, 1)
    return
  end

  love.graphics.setColor(0, 0, 0, 1)
  Font.drawBox(0, 0, 20, 18)
  if self.mode == "grid" then
    -- stale assets (no background art): the old abstract squares
    for _, loc in ipairs(self.locs) do
      drawSquare(loc)
    end
    if self.playerLoc and self.blink < 20 then
      love.graphics.setColor(0.75, 0.1, 0.1, 1)
      love.graphics.rectangle("fill", self.playerLoc.x * 8 + 2,
                              self.playerLoc.y * 8 + 2, 4, 4)
    end
    if selected and self.blink % 16 < 10 then
      love.graphics.setColor(0, 0, 0, 1)
      love.graphics.rectangle("line", selected.x * 8 + 0.5,
                              selected.y * 8 + 0.5, 7, 7)
    end
  else
    -- list fallback: show a window of names, cursor on the selection
    love.graphics.setColor(0, 0, 0, 1)
    local rows = 6
    local first = math.max(1, math.min(self.sel - 2, #self.locs - rows + 1))
    for i = 0, rows - 1 do
      local loc = self.locs[first + i]
      if loc then
        local y = 40 + i * 16
        if first + i == self.sel and self.blink % 16 < 10 then
          Font.drawCode(0xED, 8, y)  -- the "▶" cursor glyph
        end
        Font.draw(loc.name, 24, y)
        if loc == self.playerLoc and self.blink < 20 then
          -- blinking marker on the player's current town
          love.graphics.rectangle("fill", 24 + #loc.name * 8 + 6, y + 2, 4, 4)
        end
      end
    end
  end

  -- name banner across the top
  Font.drawBox(0, 0, 20, 3)
  love.graphics.setColor(0, 0, 0, 1)
  if selected then Font.draw(selected.name, 8, 8) end
  love.graphics.setColor(1, 1, 1, 1)
end

return TownMap
