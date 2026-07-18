-- Map browser: view any map, follow its warps, and set the save's spawn
-- point / remembered outdoor or heal spot by clicking cells on the
-- rendered map. Reuses the game's own MapLoader/TileRenderer/Warp so the
-- editor's view matches what the player would actually see.

local MapLoader = require("src.world.MapLoader")
local Warp = require("src.world.Warp")

local MapBrowser = {}

local LIST_W, LIST_H, ROW_H = 200, 300, 20
local MAX_ROWS = math.floor(LIST_H / ROW_H)
local VIEW_W, VIEW_H = 480, 432

local function clampZoom(z)
  if z < 1 then return 1 end
  if z > 4 then return 4 end
  return z
end

-- Point the camera so (cx,cy) lands in the middle of the viewport.
local function centerOn(S, cx, cy)
  S.mapCamX = cx * 16 - VIEW_W / (2 * S.mapZoom)
  S.mapCamY = cy * 16 - VIEW_H / (2 * S.mapZoom)
end

-- Detect outdoor the same way the game treats LAST_MAP sources:
-- OVERWORLD/PLATEAU tilesets, or maps with connections / visited fly spots.
local function isOutdoor(S, map)
  if map.def.tileset == "OVERWORLD" or map.def.tileset == "PLATEAU" then
    return true
  end
  if next(map.def.connections or {}) ~= nil then return true end
  return (S.save.visited and S.save.visited[map.id]) or false
end

local function sortedMapIds(data)
  local ids = {}
  for id in pairs(data.maps) do table.insert(ids, id) end
  table.sort(ids)
  return ids
end

-- LAST_MAP warps resolve against the remembered outdoor spot; skip with
-- a status message if the save has none (fresh games, or old saves).
-- Mirrors the game: leaving an OVERWORLD/PLATEAU map via a warp updates
-- lastOutdoor so building exits (Indigo lobby, Route 22 Gate, …) return
-- to the map you entered from.
local OUTSIDE_TILESETS = { OVERWORLD = true, PLATEAU = true }

local function goToWarp(S, warp)
  local def = warp.def
  local fromMap = S.data.maps[S.mapId]
  if fromMap and OUTSIDE_TILESETS[fromMap.tileset]
     and def.destMap ~= "LAST_MAP" and def.destMap ~= S.mapId then
    S.save.lastOutdoor = { id = S.mapId, x = def.x, y = def.y }
  end
  if def.destMap == "LAST_MAP" and not S.save.lastOutdoor then
    S.status = "Can't follow warp: no remembered outdoor map (lastOutdoor unset)"
    return
  end
  local ok, destMap, dx, dy = pcall(Warp.destination, S.data, def, S.save.lastOutdoor)
  if not ok then
    S.status = "Warp failed: " .. tostring(destMap)
    return
  end
  S.mapId = destMap
  S.mapClickCell = nil
  centerOn(S, dx, dy)
  S.status = "Followed warp to " .. destMap
end

-- Screen-space point inside the viewport -> map cell, or nil if the
-- point is outside the viewport or off the edge of the map.
local function cellAtScreen(S, map, Kit, vx, vy)
  if Kit.mouseX < vx or Kit.mouseX >= vx + VIEW_W
     or Kit.mouseY < vy or Kit.mouseY >= vy + VIEW_H then
    return nil
  end
  local wx = (Kit.mouseX - vx) / S.mapZoom + S.mapCamX
  local wy = (Kit.mouseY - vy) / S.mapZoom + S.mapCamY
  local cx, cy = math.floor(wx / 16), math.floor(wy / 16)
  if not map:inBounds(cx, cy) then return nil end
  return cx, cy
end

-- Wired from App.wheelmoved while the Map tab is active.
function MapBrowser.wheelmoved(S, dy)
  S.mapZoom = clampZoom((S.mapZoom or 2) + (dy > 0 and 0.25 or -0.25))
end

local PAN_KEYS = {
  up = { 0, -16 }, w = { 0, -16 },
  down = { 0, 16 }, s = { 0, 16 },
  left = { -16, 0 }, a = { -16, 0 },
  right = { 16, 0 }, d = { 16, 0 },
}

-- Wired from App.keypressed while the Map tab is active.
function MapBrowser.keypressed(S, key)
  local d = PAN_KEYS[key]
  if not d then return end
  S.mapCamX = (S.mapCamX or 0) + d[1]
  S.mapCamY = (S.mapCamY or 0) + d[2]
end

function MapBrowser.draw(S, Kit, x, y)
  Kit.label(x, y, "Map: " .. tostring(S.mapId))

  -- ---- map id list (paginated; ~220 maps is too many for one page) ----
  local ids = sortedMapIds(S.data)
  S.mapListScroll = S.mapListScroll or 0
  local pageIds, selectedIdx = {}, nil
  for i = 1, MAX_ROWS do
    local id = ids[S.mapListScroll + i]
    if id then
      pageIds[#pageIds + 1] = id
      if id == S.mapId then selectedIdx = #pageIds end
    end
  end
  local clickIdx = Kit.list(x, y + 24, LIST_W, MAX_ROWS * ROW_H, pageIds, selectedIdx, ROW_H)
  if clickIdx and pageIds[clickIdx] then
    S.mapId = pageIds[clickIdx]
    S.mapClickCell = nil
    if S.save.player.map == S.mapId then
      centerOn(S, S.save.player.x, S.save.player.y)
    else
      S.mapCamX, S.mapCamY = 0, 0
    end
  end

  local listBottom = y + 24 + MAX_ROWS * ROW_H + 8
  if Kit.button(x, listBottom, 60, 24, "Prev") then
    S.mapListScroll = math.max(0, S.mapListScroll - MAX_ROWS)
  end
  if Kit.button(x + 64, listBottom, 60, 24, "Next") then
    if S.mapListScroll + MAX_ROWS < #ids then
      S.mapListScroll = S.mapListScroll + MAX_ROWS
    end
  end
  if Kit.button(x, listBottom + 30, LIST_W, 24, "Go to save location") then
    S.mapId = S.save.player.map
    S.mapClickCell = nil
    centerOn(S, S.save.player.x, S.save.player.y)
  end

  -- ---- map viewport ----
  local vx, vy = x + LIST_W + 20, y + 24
  local ok, map = pcall(MapLoader.load, S.data, S.mapId)
  if not ok then
    Kit.label(vx, vy, "Failed to load map: " .. tostring(map))
    return
  end

  -- love_stub (headless tests) lacks push/pop/scale/scissor; skip the
  -- actual render there but keep all click/button logic below running.
  if love.graphics.push then
    love.graphics.setScissor(vx, vy, VIEW_W, VIEW_H)
    love.graphics.push()
    love.graphics.translate(vx, vy)
    love.graphics.scale(S.mapZoom, S.mapZoom)
    map.renderer:draw(S.mapCamX, S.mapCamY)

    if S.save.player.map == S.mapId then
      love.graphics.setColor(1, 0.2, 0.2)
      love.graphics.rectangle("fill",
        S.save.player.x * 16 - S.mapCamX,
        S.save.player.y * 16 - S.mapCamY, 16, 16)
    end

    love.graphics.setColor(0.2, 0.8, 1, 0.5)
    for _, w in ipairs(map.def.warps) do
      love.graphics.rectangle("line",
        w.x * 16 - S.mapCamX, w.y * 16 - S.mapCamY, 16, 16)
    end

    if S.mapClickCell then
      love.graphics.setColor(1, 1, 0.2, 0.9)
      love.graphics.rectangle("line",
        S.mapClickCell.cx * 16 - S.mapCamX, S.mapClickCell.cy * 16 - S.mapCamY, 16, 16)
    end

    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.pop()
    love.graphics.setScissor()
  end

  -- ---- click handling: warp cells jump the view, others select ----
  if Kit.mouseClicked then
    local cx, cy = cellAtScreen(S, map, Kit, vx, vy)
    if cx then
      local warp = map:warpAtCell(cx, cy)
      if warp then
        goToWarp(S, warp)
      else
        S.mapClickCell = { cx = cx, cy = cy }
        S.status = string.format("Selected cell (%d,%d) on %s", cx, cy, S.mapId)
      end
    end
  end

  -- ---- info + set-location buttons ----
  local by = vy + VIEW_H + 8
  Kit.label(vx, by, S.mapClickCell
    and string.format("Selected: (%d,%d)  zoom %.2fx", S.mapClickCell.cx, S.mapClickCell.cy, S.mapZoom)
    or string.format("Click a cell to select it  zoom %.2fx", S.mapZoom))

  if Kit.button(vx, by + 22, 140, 26, "Set player here") then
    if S.mapClickCell then
      S.save.player.map = S.mapId
      S.save.player.x = S.mapClickCell.cx
      S.save.player.y = S.mapClickCell.cy
      S.dirty = true
      S.status = string.format("Player set to %s (%d,%d)", S.mapId, S.mapClickCell.cx, S.mapClickCell.cy)
    else
      S.status = "Click a cell first"
    end
  end

  if Kit.button(vx + 150, by + 22, 160, 26, "Set lastOutdoor here") then
    if not S.mapClickCell then
      S.status = "Click a cell first"
    elseif not isOutdoor(S, map) then
      S.status = S.mapId .. " doesn't look outdoor (no connections, not visited)"
    else
      S.save.lastOutdoor = { id = S.mapId, x = S.mapClickCell.cx, y = S.mapClickCell.cy }
      S.dirty = true
      S.status = "lastOutdoor set to " .. S.mapId
    end
  end

  if Kit.button(vx + 320, by + 22, 140, 26, "Set lastHeal here") then
    if S.mapClickCell then
      S.save.lastHeal = { map = S.mapId, x = S.mapClickCell.cx, y = S.mapClickCell.cy }
      S.dirty = true
      S.status = "lastHeal set to " .. S.mapId
    else
      S.status = "Click a cell first"
    end
  end

  if Kit.button(vx, by + 56, 120, 24, "Center on player") then
    if S.save.player.map == S.mapId then
      centerOn(S, S.save.player.x, S.save.player.y)
    else
      S.status = "Player isn't on this map"
    end
  end
  if Kit.button(vx + 130, by + 56, 60, 24, "Zoom -") then
    S.mapZoom = clampZoom((S.mapZoom or 2) - 0.5)
  end
  if Kit.button(vx + 196, by + 56, 60, 24, "Zoom +") then
    S.mapZoom = clampZoom((S.mapZoom or 2) + 0.5)
  end
end

return MapBrowser
