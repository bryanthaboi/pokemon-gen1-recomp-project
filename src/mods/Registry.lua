-- Ordered, namespaced content registries used by the native mod API.
-- Each registry stores an op log per id (register/override/patch/remove)
-- folded over the base record at read/merge time, so patches stack across
-- mods in load order and undoing a failed mod is just dropping its ops.
-- The loader merges effective values into the live data only after every
-- enabled mod has initialized successfully.
local Merge = require("src.mods.Merge")

local Registry = {}
Registry.__index = Registry

-- exposed to mods as mod.DELETE: a patch value that unsets a field
Registry.DELETE = Merge.DELETE

-- spec comes from Schemas.REGISTRIES[name]; bare Registry.new(name) keeps
-- the v1 record behavior for standalone use in tests and tools
function Registry.new(name, spec)
  return setmetatable({
    name = name,
    spec = spec or { semantics = "record" },
    ops = {},      -- id -> ordered { op, value, owner }
    owners = {},   -- id -> last-writing owner (provenance for errors)
    order = {},    -- ids in first-touch order, for array-rebuilding targets
    seen = {},     -- id -> true, keeps order free of duplicates
    cache = {},    -- id -> { value } memoized fold
    base = nil,    -- installed by the loader: fn() -> base table or nil
    frozen = false,
  }, Registry)
end

local function append(self, id, op, value, owner)
  if self.frozen then
    error(self.name .. ": content is frozen after load")
  end
  assert(type(id) == "string" and id ~= "", self.name .. " id is required")
  local list = self.ops[id]
  if not list then
    list = {}
    self.ops[id] = list
  end
  -- a rolled-back id keeps its slot: order is registration history, not a
  -- live key set, so a resurrected id stays where it first appeared
  if not self.seen[id] then
    self.seen[id] = true
    self.order[#self.order + 1] = id
  end
  list[#list + 1] = { op = op, value = value, owner = owner }
  self.owners[id] = owner
  self.cache[id] = nil
  return value
end

-- spec.baseAt lets a registry whose ids do not map one-to-one onto target
-- keys (battle_anims routes by id prefix) resolve its own pristine value
local function baseValue(self, id)
  local base = self.base and self.base()
  if base == nil then return nil end
  if self.spec.baseAt then return self.spec.baseAt(base, id) end
  return base[id]
end

-- effective value = base plus the op list; a tombstone folds to nil and a
-- later register may resurrect the id
local function fold(self, value, opList)
  local deep = self.spec.semantics == "deep"
  for _, entry in ipairs(opList or {}) do
    local op = entry.op
    -- a payload that IS the sentinel folds as a delete, never a value;
    -- without this the bare DELETE table would leak into Data as a record
    if entry.value == Merge.DELETE then
      value = nil
    elseif op == "override" or (op == "register" and not deep) then
      value = entry.value
    elseif op == "register" or op == "patch" then
      -- deep registries treat register and patch alike; scalar payloads
      -- (a lone top-level value) replace outright
      if type(entry.value) == "table" then
        value = Merge.deepMerge(Merge.deepCopy(value == nil and {} or value),
          entry.value, self.spec.semantics)
      else
        value = entry.value
      end
    elseif op == "remove" then
      value = nil
    end
  end
  return value
end

function Registry:register(id, value, owner, replace)
  if replace then return self:override(id, value, owner) end -- v1 signature
  assert(value ~= nil, self.name .. " value is required for " .. tostring(id))
  -- duplicates collide against the base table too, forcing an explicit
  -- override; compose chains accumulate and deep keys merge instead
  if self.spec.semantics == "record" and self:get(id) ~= nil then
    error(("%s already registered: %s"):format(self.name, id))
  end
  return append(self, id, "register", value, owner)
end

function Registry:override(id, value, owner)
  assert(value ~= nil, self.name .. " value is required for " .. tostring(id))
  return append(self, id, "override", value, owner)
end

function Registry:patch(id, partial, owner)
  assert(partial ~= nil, self.name .. " patch value is required for " .. tostring(id))
  if self.spec.semantics == "compose" then
    error(self.name .. ": patch is not supported on compose registries")
  end
  return append(self, id, "patch", partial, owner)
end

-- tombstone: consumers treat the id as absent after the merge
function Registry:remove(id, owner)
  return append(self, id, "remove", nil, owner)
end

function Registry:get(id)
  if self.spec.semantics == "compose" then
    -- chain() sorts top priority first, so the head is the effective value
    local chain = self:chain(id)
    return chain[1]
  end
  local hit = self.cache[id]
  if hit then return hit.value end
  local value = fold(self, baseValue(self, id), self.ops[id])
  self.cache[id] = { value = value }
  return value
end

function Registry:has(id)
  return self:get(id) ~= nil
end

-- compose fold: the ordered entry list for an id.  Override is the
-- total-conversion escape hatch (09 4.4) -- it clears the whole chain, every
-- owner's entries alike, and installs itself as the only contribution;
-- remove tombstones the whole entry the same way but installs nothing.
-- Order is priority (higher first) then registration order.  The second
-- return says the chain was cleared, which is how a consumer holding an
-- out-of-band base contribution (MapScripts) knows to leave it out.
local function composed(self, id)
  local entries, replacesBase = {}, false
  for seq, entry in ipairs(self.ops[id] or {}) do
    if entry.op == "register" then
      entries[#entries + 1] = { value = entry.value, owner = entry.owner, seq = seq }
    elseif entry.op == "override" then
      for i = #entries, 1, -1 do entries[i] = nil end
      entries[1] = { value = entry.value, owner = entry.owner, seq = seq }
      replacesBase = true
    elseif entry.op == "remove" then
      -- owner-scoped removal would leave the consumer's own base
      -- contribution standing, so the map would still dispatch; 09 4.4
      -- makes remove a whole-entry tombstone.  A later register still
      -- resurrects the id, ops after this one survive the clear
      for i = #entries, 1, -1 do entries[i] = nil end
      replacesBase = true
    end
  end
  table.sort(entries, function(a, b)
    local pa = type(a.value) == "table" and a.value.priority or 0
    local pb = type(b.value) == "table" and b.value.priority or 0
    if pa ~= pb then return pa > pb end
    return a.seq < b.seq
  end)
  return entries, replacesBase
end

-- compose only: the ordered value list for an id
function Registry:chain(id)
  assert(self.spec.semantics == "compose",
    self.name .. ": chain is compose-only")
  local entries = composed(self, id)
  local values = {}
  for i = 1, #entries do values[i] = entries[i].value end
  return values
end

-- chain()'s owners, index-aligned with its values: consumers that
-- attribute dispatch (map_scripts runner sources) read both sides of the
-- same fold
function Registry:chainOwners(id)
  assert(self.spec.semantics == "compose",
    self.name .. ": chainOwners is compose-only")
  local entries = composed(self, id)
  local owners = {}
  for i = 1, #entries do owners[i] = entries[i].owner end
  return owners
end

-- compose only: true once an override has cleared this id's chain, so a
-- consumer that keeps its own base contribution outside the registry
-- (MapScripts' engine scripts) knows the total conversion excluded it
function Registry:chainReplacesBase(id)
  assert(self.spec.semantics == "compose",
    self.name .. ": chainReplacesBase is compose-only")
  local _, replacesBase = composed(self, id)
  return replacesBase
end

-- iterator over the merged view: base ids first, then op-only ids;
-- tombstoned ids are skipped.  No ordering guarantee.
function Registry:each()
  local ids, seen = {}, {}
  local base = self.base and self.base()
  if base then
    -- spec.baseIds names the ids hiding inside a structured target; without
    -- it the target's own keys are the id space
    if self.spec.baseIds then
      for _, id in ipairs(self.spec.baseIds(base)) do
        seen[id] = true
        ids[#ids + 1] = id
      end
    else
      for id in pairs(base) do
        seen[id] = true
        ids[#ids + 1] = id
      end
    end
  end
  for id in pairs(self.ops) do
    if not seen[id] then ids[#ids + 1] = id end
  end
  local i = 0
  return function()
    while true do
      i = i + 1
      local id = ids[i]
      if id == nil then return nil end
      local value = self:get(id)
      if value ~= nil then return id, value end
    end
  end
end

-- v1 compat: the values mods contributed, folded to their effective form
function Registry:items()
  local out = {}
  for id in pairs(self.ops) do out[id] = self:get(id) end
  return out
end

-- deletes every op an owner appended, in one pass; the loader calls this
-- before the merge so a failed mod leaves zero trace in Data
function Registry:rollback(owner)
  if owner == nil then return end
  for id, list in pairs(self.ops) do
    local touched = false
    for i = #list, 1, -1 do
      if list[i].owner == owner then
        table.remove(list, i)
        touched = true
      end
    end
    if touched then
      if #list == 0 then
        self.ops[id] = nil
        self.owners[id] = nil
      else
        self.owners[id] = list[#list].owner
      end
      self.cache[id] = nil
    end
  end
end

-- set once the boot merge has run; unlike the event/hook buses, content
-- stays deterministic by refusing registration after that point
function Registry:freeze()
  self.frozen = true
end

return Registry
