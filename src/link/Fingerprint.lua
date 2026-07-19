-- Deterministic digest of the link surface: the slice of merged data whose
-- value decides whether two lockstep simulations stay identical and whether a
-- traded mon is rebuilt the same way on both machines (D8).  Peers whose
-- digests agree may battle; peers whose digests differ negotiate a trade
-- subset instead of desyncing three turns in.
--
-- Everything is serialized through an explicit sorted key order.  pairs()
-- order differs between two runs of the same build, so a digest that
-- inherited it would reject identical peers at random -- that is the whole
-- reason this file exists instead of a hash over tostring(data).
--
-- Deliberately excluded: sprite paths and `source` (install-specific
-- generated paths that differ between two otherwise identical machines),
-- names, dex entries, learnsets and TM/HM lists (they change no battle math
-- and no trade rebuild).

local Runtime = require("src.mods.Runtime")

local Fingerprint = {}

-- ------- FNV-1a, two lanes

-- Two 32-bit lanes with different offset bases, concatenated into a 64-bit
-- hex digest.  Pure arithmetic: the 32-bit product is split so every
-- intermediate stays inside a double's exact integer range, and the low-byte
-- xor runs off a nibble table -- LuaJIT has bit ops, plain 5.1 does not, and
-- tools load this file outside the game.
local PRIME = 16777619
local LANE_A, LANE_B = 2166136261, 2654435769

local XOR4 = {}
for a = 0, 15 do
  XOR4[a] = {}
  for b = 0, 15 do
    local x, y, r = a, b, 0
    for place = 0, 3 do
      if x % 2 ~= y % 2 then r = r + 2 ^ place end
      x, y = math.floor(x / 2), math.floor(y / 2)
    end
    XOR4[a][b] = r
  end
end

local function xor8(a, b)
  return XOR4[math.floor(a / 16)][math.floor(b / 16)] * 16 + XOR4[a % 16][b % 16]
end

local function step(h, byte)
  local lo = h % 65536
  local hi = (h - lo) / 65536
  lo = lo - lo % 256 + xor8(lo % 256, byte)
  return (lo * PRIME + (hi * PRIME % 65536) * 65536) % 4294967296
end

local function digest(text)
  local a, b = LANE_A, LANE_B
  for i = 1, #text do
    local byte = text:byte(i)
    a = step(a, byte)
    b = step(b, byte)
  end
  return ("%08x%08x"):format(a, b)
end

Fingerprint.digest = digest

-- ------- canonical serialization

-- %.17g is exact for every integer stat involved and is the same format the
-- wire encoder uses, so a value that survives JSON hashes the same
local function number(v)
  return ("%.17g"):format(v)
end

local writeValue

-- tables are written array part first (order is meaning there: type chart
-- rows, evolution lists), then named keys in sorted order
writeValue = function(out, v)
  local t = type(v)
  if t == "number" then
    out[#out + 1] = "#" .. number(v)
  elseif t == "string" then
    out[#out + 1] = "$" .. v
  elseif t == "boolean" then
    out[#out + 1] = v and "T" or "F"
  elseif t == "table" then
    out[#out + 1] = "("
    local n = #v
    for i = 1, n do writeValue(out, v[i]) end
    local keys = {}
    for k in pairs(v) do
      if not (type(k) == "number" and k >= 1 and k <= n and k % 1 == 0) then
        keys[#keys + 1] = k
      end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
      out[#out + 1] = "." .. tostring(k)
      writeValue(out, v[k])
    end
    out[#out + 1] = ")"
  else
    -- a handler's bytes are not portably hashable; mods bump the record's
    -- rev instead, and the mod version is the backstop when they forget
    out[#out + 1] = "?"
  end
end

-- an absent field is skipped identically on both sides, so a record that
-- never had the key and one whose mod removed it agree
local function writeFields(out, record, fields)
  for _, field in ipairs(fields) do
    local v = record[field]
    if v ~= nil then
      out[#out + 1] = "." .. field
      writeValue(out, v)
    end
  end
end

local function sortedIds(map)
  local ids = {}
  for id in pairs(map or {}) do ids[#ids + 1] = id end
  table.sort(ids)
  return ids
end

-- ------- the link surface

local SPECIES_FIELDS = { "baseStats", "types", "catchRate", "baseExp",
                         "growthRate", "evolutions" }
local MOVE_FIELDS = { "power", "type", "accuracy", "pp", "effect", "category",
                      "priority", "highCrit", "fixedDamage", "multiHit",
                      "counterable", "semiInvulnerable" }
-- catchBonus/shakeBonus are this engine's names for the plan's catchModifier
local STATUS_FIELDS = { "rev", "catchBonus", "shakeBonus", "statPenalty",
                        "cureOnSwitch", "beforeMovePriority" }
local EFFECT_FIELDS = { "rev", "kind", "accuracyChecked" }
local CONSTANT_FIELDS = { "partyMax", "moveMax", "levelCap", "dexSize",
                          "badgeBoosts" }

local RECORD_FIELDS = { pokemon = SPECIES_FIELDS, moves = MOVE_FIELDS,
                        statuses = STATUS_FIELDS, move_effects = EFFECT_FIELDS }

Fingerprint.FIELDS = RECORD_FIELDS

local function writeSection(out, data, kind)
  local map = data[kind]
  if map == nil then return end
  local fields = RECORD_FIELDS[kind]
  out[#out + 1] = "[" .. kind .. "]"
  for _, id in ipairs(sortedIds(map)) do
    local record = map[id]
    if type(record) == "table" then
      out[#out + 1] = "@" .. id
      writeFields(out, record, fields)
    end
  end
end

-- the chart rows are an ordered array whose order the merge rebuilds from
-- registration history, so they hash in place; the type records ride along
-- because `category` decides the physical/special split
local function writeTypeChart(out, data)
  local chart = data.type_chart
  if not chart then return end
  out[#out + 1] = "[type_chart]"
  for _, row in ipairs(chart.matchups or {}) do
    out[#out + 1] = ("@%s>%s"):format(tostring(row.attacker), tostring(row.defender))
    writeValue(out, row.multiplier)
  end
  for _, id in ipairs(sortedIds(chart.types)) do
    local record = chart.types[id]
    if type(record) == "table" then
      out[#out + 1] = "@" .. id
      writeFields(out, record, { "category", "index" })
    end
  end
end

local function writeConstants(out, data)
  if not data.constants then return end
  out[#out + 1] = "[constants]"
  writeFields(out, data.constants, CONSTANT_FIELDS)
end

-- a mod that wants an extra mon field to force agreement declares it here;
-- only the author revision is hashable, the pack/unpack pair is not
local function writeLinkFields(out, data)
  local fields = data.link_fields
  if not fields then return end
  out[#out + 1] = "[link_fields]"
  for _, id in ipairs(sortedIds(fields)) do
    local record = fields[id]
    if type(record) == "table" then
      out[#out + 1] = "@" .. id
      writeFields(out, record, { "rev" })
    end
  end
end

-- id@version of every enabled mod that touches the link surface: the
-- backstop for a logic-only change whose author forgot to bump a rev
local function modKey(mods)
  local parts = {}
  for _, mod in ipairs(mods or {}) do
    if mod.affectsLink ~= false then
      parts[#parts + 1] = ("%s@%s"):format(tostring(mod.id),
                                           tostring(mod.version or "?"))
    end
  end
  table.sort(parts)
  return table.concat(parts, ",")
end

Fingerprint.modKey = modKey

-- ------- public API

-- memoized per merged-data identity: the digest is only ever asked for on
-- entry to link play, and vanilla single-player must not pay for it at all
local cache = setmetatable({}, { __mode = "k" })

local function surface(data, mods)
  local out = {}
  writeSection(out, data, "pokemon")
  writeSection(out, data, "moves")
  writeTypeChart(out, data)
  writeSection(out, data, "statuses")
  writeSection(out, data, "move_effects")
  writeConstants(out, data)
  writeLinkFields(out, data)
  out[#out + 1] = "[mods]" .. modKey(mods)
  return table.concat(out)
end

Fingerprint.surface = surface

-- mods: { { id, version, affectsLink } } -- the hello's mod array
function Fingerprint.compute(data, mods)
  if not data then return digest("") end
  local key = modKey(mods)
  local hit = cache[data]
  if hit and hit.key == key then return hit.value end
  local value = Runtime.call("link.fingerprint", function(d, m)
    return digest(surface(d, m))
  end, data, mods)
  cache[data] = { key = key, value = value }
  return value
end

-- per-record digests over the same allowlist, so two peers can agree on
-- exactly which species and moves they rebuild identically
local recordCache = setmetatable({}, { __mode = "k" })

function Fingerprint.records(data, kind)
  local fields = RECORD_FIELDS[kind]
  assert(fields, "no record allowlist for " .. tostring(kind))
  local perData = recordCache[data]
  if not perData then
    perData = {}
    recordCache[data] = perData
  end
  if perData[kind] then return perData[kind] end
  local map = data[kind] or {}
  local out = {}
  for id, record in pairs(map) do
    if type(record) == "table" then
      local buf = { "@" .. id }
      writeFields(buf, record, fields)
      out[id] = digest(table.concat(buf))
    end
  end
  perData[kind] = out
  return out
end

function Fingerprint.forget(data)
  cache[data] = nil
  recordCache[data] = nil
end

return Fingerprint
