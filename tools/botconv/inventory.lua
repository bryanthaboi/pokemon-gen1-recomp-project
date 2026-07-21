-- Inventory pass for the PokeBotBad route converter.
--
-- Reads PokeBotBad's data/red/paths.lua and reports every distinct step
-- shape it contains, so the conversion table is driven by what the route
-- actually uses rather than by guesswork.
--
--   luajit tools/botconv/inventory.lua /path/to/PokeBotBad
--
-- Route entries look like:
--   { <mapId>, {x,y}, {s="talk",dir="Up"}, {c="a",a="Brock's Gym"}, ... }
-- entry[1] is a numeric pokered map id; the rest are steps.

local botRoot = ... or arg[1]
assert(botRoot, "usage: luajit tools/botconv/inventory.lua <PokeBotBad checkout>")

-- paths.lua reads a few speedrun-only globals (client.speedmode targets).
-- They are dropped by the converter, so any value will do.
setmetatable(_G, { __index = function() return 0 end })

local pathsFile = botRoot .. "/data/red/paths.lua"
local Paths = assert(loadfile(pathsFile))()

local mapOrder = dofile("data/generated/constants.lua").mapOrder

local strategies, controls = {}, {}
local counts = { waypoint = 0, strategy = 0, control = 0, unknown = 0 }
local unknownMaps, sections = {}, {}

local function note(bucket, name, step, section)
  local rec = bucket[name]
  if not rec then
    rec = { n = 0, params = {}, sections = {} }
    bucket[name] = rec
  end
  rec.n = rec.n + 1
  rec.sections[section] = true
  for k in pairs(step) do
    if k ~= "s" and k ~= "c" then rec.params[k] = true end
  end
end

-- Section headers are comments, so recover them by scanning the source and
-- counting which route entry each header precedes.
local function sectionNames()
  local names, idx, fh = {}, 0, assert(io.open(pathsFile, "r"))
  local current = "0: INTRO"
  for line in fh:lines() do
    local header = line:match("^%-%-%s*(%d+:%s*.+)$")
    if header then current = header end
    if line:match("^%s*{%s*%-?%d+%s*,") then
      idx = idx + 1
      names[idx] = current
    end
  end
  fh:close()
  return names
end

local names = sectionNames()

for i, entry in ipairs(Paths) do
  local mapId = entry[1]
  local section = names[i] or "?"
  sections[section] = true
  local mapName = mapOrder[mapId + 1]
  if not mapName then unknownMaps[mapId] = true end

  for j = 2, #entry do
    local step = entry[j]
    if type(step) ~= "table" then
      counts.unknown = counts.unknown + 1
    elseif step.s then
      counts.strategy = counts.strategy + 1
      note(strategies, step.s, step, section)
    elseif step.c then
      counts.control = counts.control + 1
      note(controls, step.c, step, section)
    elseif type(step[1]) == "number" and type(step[2]) == "number" then
      counts.waypoint = counts.waypoint + 1
    else
      counts.unknown = counts.unknown + 1
    end
  end
end

local function dump(title, bucket)
  local keys = {}
  for k in pairs(bucket) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    if bucket[a].n ~= bucket[b].n then return bucket[a].n > bucket[b].n end
    return a < b
  end)
  print(("\n=== %s (%d distinct) ==="):format(title, #keys))
  for _, k in ipairs(keys) do
    local rec = bucket[k]
    local params = {}
    for p in pairs(rec.params) do params[#params + 1] = p end
    table.sort(params)
    local nsec = 0
    for _ in pairs(rec.sections) do nsec = nsec + 1 end
    print(("%-28s x%-4d sections:%-3d %s"):format(
      k, rec.n, nsec,
      #params > 0 and ("{" .. table.concat(params, ",") .. "}") or ""))
  end
end

print(("route entries: %d   sections: %d"):format(#Paths, (function()
  local n = 0; for _ in pairs(sections) do n = n + 1 end; return n
end)()))
print(("waypoints:%d  strategies:%d  controls:%d  unknown:%d"):format(
  counts.waypoint, counts.strategy, counts.control, counts.unknown))

local bad = {}
for id in pairs(unknownMaps) do bad[#bad + 1] = id end
if #bad > 0 then
  table.sort(bad)
  print("UNMAPPED MAP IDS: " .. table.concat(bad, ", "))
else
  print("all map ids resolve against data/generated/constants.lua mapOrder")
end

dump("STRATEGIES", strategies)
dump("CONTROLS", controls)
