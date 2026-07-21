-- PokeBotBad route converter.
--
--   luajit tools/botconv/convert.lua <PokeBotBad checkout> [out.lua]
--
-- Reads PokeBotBad's data/red/paths.lua and emits a route data file for
-- the recomp: numeric pokered map ids become our string map names, tile
-- waypoints pass through unchanged (the coordinate systems are
-- identical), and every strategy/control step is classified by
-- table.lua into a generic op, a battle, a manual stub, or nothing.
--
-- The output is data, not code. tests/drivers/route.lua interprets it
-- against the live Game object. Anything table.lua does not cover is a
-- hard error -- the converter never silently drops a step.

local BOT = ... or arg[1]
assert(BOT, "usage: luajit tools/botconv/convert.lua <PokeBotBad checkout> [out]")
local OUT = arg[2] or "tests/drivers/bot_route.lua"

local TBL = dofile("tools/botconv/table.lua")
local mapOrder = dofile("data/generated/constants.lua").mapOrder

setmetatable(_G, { __index = function() return 0 end }) -- speedrun-only globals
local Paths = assert(loadfile(BOT .. "/data/red/paths.lua"))()

local stats = {
  waypoint = 0, dropped = 0, battle = 0, verb = 0, manual = 0, control = 0,
}
local manualSeen, unknown = {}, {}

local function face(v) return TBL.face[v] or v end

-- Translate one {s=...} / {c=...} step into an op, or nil to drop it.
local function convertStep(step)
  if step.s then
    local name = step.s
    if TBL.drop[name] then
      stats.dropped = stats.dropped + 1
      return nil
    end
    if TBL.battle[name] then
      stats.battle = stats.battle + 1
      return { op = "battle", face = step.dir and face(step.dir) or nil }
    end
    if TBL.manual[name] then
      stats.manual = stats.manual + 1
      manualSeen[name] = (manualSeen[name] or 0) + 1
      return { op = "manual", name = name }
    end
    local v = TBL.verb[name]
    if v then
      stats.verb = stats.verb + 1
      local out = { op = v.op }
      for k, val in pairs(v.fixed or {}) do out[k] = val end
      for botKey, ourKey in pairs(v.params or {}) do
        local val = step[botKey]
        if val ~= nil then
          out[ourKey] = (ourKey == "face") and face(val) or val
        end
      end
      return out
    end
    unknown[#unknown + 1] = "s=" .. name
    return nil
  end

  local name = step.c
  if TBL.controlDrop[name] then
    stats.dropped = stats.dropped + 1
    return nil
  end
  local cv = TBL.controlVerb[name]
  if cv then
    stats.control = stats.control + 1
    local out = { op = cv.op }
    if cv.mon ~= nil then out.mon = cv.mon end
    return out
  end
  unknown[#unknown + 1] = "c=" .. name
  return nil
end

-- ---------------------------------------------------------------------

-- PokeBotBad advances its path list sequentially whenever the map changes
-- (action/walk.lua:91-93) and only consults entry[1] when re-syncing after
-- a reset, so a wrong map id there never breaks its run -- and some are
-- wrong. Fix the ones we have verified rather than importing the typo:
-- entry 2 is labelled "Red's house" but carries 39 (BLUES_HOUSE); its
-- waypoints continue from Red's stairs, so it is REDS_HOUSE_1F (37).
local MAP_FIXUPS = { [2] = 37 }

local route = {}

for idx, entry in ipairs(Paths) do
  local mapId = MAP_FIXUPS[idx] or entry[1]
  local mapName = mapOrder[mapId + 1]
  assert(mapName, ("unmapped pokered map id %d"):format(mapId))

  local steps = {}
  for j = 2, #entry do
    local step = entry[j]
    if step.s or step.c then
      local op = convertStep(step)
      if op then steps[#steps + 1] = op end
    else
      -- a bare {x,y} waypoint. Negative coords are the route's idiom for
      -- "walk off the map edge into the connecting map"; the runtime
      -- clamps into the connection rather than pathfinding to a cell that
      -- does not exist.
      stats.waypoint = stats.waypoint + 1
      steps[#steps + 1] = { op = "goto", x = step[1], y = step[2] }
    end
  end
  route[#route + 1] = { map = mapName, steps = steps }
end

if #unknown > 0 then
  io.stderr:write("unclassified steps (add them to tools/botconv/table.lua):\n")
  local seen = {}
  for _, u in ipairs(unknown) do
    if not seen[u] then seen[u] = true; io.stderr:write("  " .. u .. "\n") end
  end
  os.exit(1)
end

-- ---------------------------------------------------------------------
-- emit
-- ---------------------------------------------------------------------

-- Param values are scalars, or a list of candidate strings -- the route
-- writes poke={"oddish","paras"} for "teach this to whichever of these we
-- actually caught". Anything else is a bug in table.lua's param mapping
-- (an unquoted WRAM address, say) and must not reach the output as a
-- stringified pointer.
local function quote(v)
  local t = type(v)
  if t == "string" then return ("%q"):format(v) end
  if t == "number" or t == "boolean" then return tostring(v) end
  if t == "table" then
    local parts = {}
    for i, item in ipairs(v) do
      assert(type(item) == "string",
        ("list param element %d is %s, expected string"):format(i, type(item)))
      parts[i] = ("%q"):format(item)
    end
    assert(#parts > 0, "empty list param")
    return "{ " .. table.concat(parts, ", ") .. " }"
  end
  error("unserializable param value of type " .. t)
end

local buf = {
  "-- Generated by tools/botconv/convert.lua from PokeBotBad's any% route.",
  "-- Do not edit; edit tools/botconv/table.lua and regenerate.",
  "return {",
}
for _, seg in ipairs(route) do
  buf[#buf + 1] = ("  { map = %q, steps = {"):format(seg.map)
  for _, s in ipairs(seg.steps) do
    local parts = {}
    local keys = {}
    for k in pairs(s) do if k ~= "op" then keys[#keys + 1] = k end end
    table.sort(keys)
    for _, k in ipairs(keys) do
      parts[#parts + 1] = ("%s = %s"):format(k, quote(s[k]))
    end
    buf[#buf + 1] = ("    { op = %q%s },"):format(
      s.op, #parts > 0 and (", " .. table.concat(parts, ", ")) or "")
  end
  buf[#buf + 1] = "  } },"
end
buf[#buf + 1] = "}"

local fh = assert(io.open(OUT, "w"))
fh:write(table.concat(buf, "\n"), "\n")
fh:close()

-- ---------------------------------------------------------------------
-- coverage report
-- ---------------------------------------------------------------------

print(("wrote %s  (%d map segments)"):format(OUT, #route))
print(("  goto      %4d"):format(stats.waypoint))
print(("  battle    %4d"):format(stats.battle))
print(("  verb      %4d"):format(stats.verb))
print(("  control   %4d"):format(stats.control))
print(("  dropped   %4d   (speedrun / streaming only)"):format(stats.dropped))
print(("  manual    %4d   <- runtime handlers required"):format(stats.manual))

local names = {}
for n in pairs(manualSeen) do names[#names + 1] = n end
table.sort(names)
print("\nhandlers tests/drivers/route.lua must implement:")
for _, n in ipairs(names) do
  print(("  %-20s x%d"):format(n, manualSeen[n]))
end
