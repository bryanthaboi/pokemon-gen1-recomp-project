-- No-mod parity gate for the registry catalog (21-testing-and-ci "parity
-- gate for every extension point", constraint 2).
--
-- De-hard-coding a literal into a registry is the single riskiest move in
-- the whole plan: the value a consumer reads has to come out of the
-- registry byte-identical to the literal it replaced.  The gate that
-- proves it is this one -- load zero mods over a dataset and assert that
-- every record the dataset already had survives untouched, and that the
-- namespaces which appear contain nothing but engine-owned records.
--
-- Namespaces DO appear (statuses, move_effects, growth_rates, balls, ...):
-- those are the engine's own vanilla records for rules that used to be
-- inline, which is the point.  What must never happen is a base record
-- changing value.

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local Schemas = require("src.mods.Schemas")
local Registry = require("src.mods.Registry")

-- stable structural render, so "unchanged" compares by value and is
-- readable when it fails
local function snapshot(value, seen)
  if type(value) ~= "table" then return tostring(value) end
  seen = seen or {}
  if seen[value] then return "<cycle>" end
  local nested = {}
  for k in pairs(seen) do nested[k] = true end
  nested[value] = true
  local keys = {}
  for key in pairs(value) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local out = {}
  for _, key in ipairs(keys) do
    out[#out + 1] = tostring(key) .. "=" .. snapshot(value[key], nested)
  end
  return "{" .. table.concat(out, ",") .. "}"
end

local registries = T.catalog.registries()
T.check(#registries > 0, "the registry catalog is non-empty")

-- 1. every declared registry is instantiated on a fresh loader
local data = T.fixtures.fresh()
local before = {}
for key, value in pairs(data) do before[key] = snapshot(value) end

local run = T.sdk.loadNone({ data = data })
T.eq(#run.errors, 0, "a zero-mod load reports no errors")

for _, name in ipairs(registries) do
  local registry = run.loader.content[name]
  T.check(registry ~= nil, "registry is instantiated: " .. name)
  if registry then
    T.eq(registry.spec, Schemas.REGISTRIES[name], "registry carries its catalog spec: " .. name)
  end
end

-- 2. the parity claim: nothing the dataset already held changed value.
-- Added keys are legal and expected (the engine's own records for rules
-- that used to be literals -- type_chart.types is the type-category list
-- lifted out of Damage.lua); a key that existed before and now reads
-- differently is the parity break this gate exists to catch.
local function assertUnchanged(oldValue, newValue, path)
  if type(oldValue) ~= "table" then
    T.eq(snapshot(newValue), snapshot(oldValue),
      "zero-mod load leaves base data unchanged: " .. path)
    return
  end
  if type(newValue) ~= "table" then
    T.check(false, "zero-mod load replaced a table with a scalar: " .. path)
    return
  end
  for key, value in pairs(oldValue) do
    assertUnchanged(value, newValue[key], path .. "." .. tostring(key))
  end
end

local pristine = T.fixtures.fresh()
for key in pairs(before) do
  assertUnchanged(pristine[key], data[key], key)
end

-- 3. everything a zero-mod load wrote is engine-owned.  A record under any
-- other owner after loading no mods would mean the merge invented one.
for _, name in ipairs(registries) do
  local registry = run.loader.content[name]
  local foreign = {}
  for id, list in pairs((registry and registry.ops) or {}) do
    for _, entry in ipairs(list) do
      if entry.owner and entry.owner ~= Schemas.ENGINE then
        foreign[#foreign + 1] = tostring(id) .. "@" .. tostring(entry.owner)
      end
    end
  end
  T.eq(#foreign, 0,
    ("no non-engine record after a zero-mod load: %s (%s)"):format(name, table.concat(foreign, ",")))
end

-- 4. a registry nobody wrote to leaves its target absent rather than
-- materializing an empty namespace, so the shape of Data still reflects
-- what actually has content behind it
for _, name in ipairs(registries) do
  local registry = run.loader.content[name]
  local spec = Schemas.REGISTRIES[name]
  if registry and spec and spec.target and next(registry.ops) == nil then
    local node, missing = data, false
    for part in spec.target:gmatch("[^%.]+") do
      if type(node) ~= "table" or node[part] == nil then missing = true break end
      node = node[part]
    end
    T.check(missing or before[spec.target:match("^[^%.]+")] ~= nil,
      "an unwritten registry materializes no namespace: " .. name)
  end
end

run.release()

-- 5. Schemas.check takes the spec FIRST; called with the wrong arity it
-- silently returns true, so a suite that gets this backwards validates
-- nothing.  Pin the signature here rather than discovering it per-suite.
do
  local spec = Schemas.REGISTRIES.pokemon
  T.check(spec ~= nil, "the pokemon registry has a spec")

  -- validate a record the dataset already ships: hand-rolling one here
  -- would only test whatever fields this file happened to remember
  local ok = Schemas.check(spec, "pokemon", "FIXMON_A", pristine.pokemon.FIXMON_A, "register")
  T.check(ok, "a shipped fixture record validates against its own schema")

  local bad = Schemas.check(spec, "pokemon", "FIXMON_A", { id = 42 }, "register")
  T.check(not bad, "a record with a wrong-typed field fails validation")

  -- the arity trap: spec-first is the signature, and calling it the other
  -- way round returns true for a record that just failed
  local reversed = Schemas.check("pokemon", "FIXMON_A", { id = 42 }, "register")
  T.check(reversed, "the wrong arity silently passes -- spec must come first")
end

-- 6. the tombstone sentinel is the documented one; a suite that invents
-- its own DELETE would silently write a literal table into the data
T.check(Registry.DELETE ~= nil, "Registry exposes the DELETE tombstone")
T.eq(Registry.DELETE, require("src.mods.Merge").DELETE,
  "Registry.DELETE is Merge.DELETE, not a private copy")

T.finish("gate_registries")
