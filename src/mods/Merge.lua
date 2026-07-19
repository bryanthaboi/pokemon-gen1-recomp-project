-- Deep-merge engine shared by Registry:patch, the deep registries, and the
-- save-migration runner.  Pure Lua, no love.*, so the headless loader and
-- offline tools can require it.
local Logger = require("src.core.Logger")

local Merge = {}

-- patch payloads carry this where a key must be unset; mods reach it as
-- mod.DELETE (assigning nil into a patch table would simply omit the key)
Merge.DELETE = setmetatable({}, { __tostring = function() return "<DELETE>" end })

-- arrays are contiguous 1..n; empty tables count as dictionaries so a bare
-- {} patch is a no-op instead of wiping the target list
local function isArray(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then return false end
    n = n + 1
  end
  if n == 0 then return false end
  for i = 1, n do
    if t[i] == nil then return false end
  end
  return true
end

Merge.isArray = isArray

-- the documented list-extension wrappers; a mod writes
-- { __append = {row} } where a bare list would replace, or __prepend to
-- reach the front, and the wrapper is unwrapped so it never reaches Data
local function isWrapper(t)
  return type(t) == "table" and (t.__append ~= nil or t.__prepend ~= nil)
end

Merge.isWrapper = isWrapper

local function extend(dst, src)
  if type(dst) ~= "table" then dst = {} end
  local rows = src.__prepend
  if type(rows) == "table" then
    for i = #rows, 1, -1 do table.insert(dst, 1, Merge.deepCopy(rows[i])) end
  end
  rows = src.__append
  if type(rows) == "table" then
    for _, element in ipairs(rows) do dst[#dst + 1] = Merge.deepCopy(element) end
  end
  return dst
end

-- deep registries accumulate lists so two mods adding rows to the same key
-- both land; a list arriving over a dictionary is still a shape clash
local function concat(dst, src, key)
  if type(dst) ~= "table" or (next(dst) ~= nil and not isArray(dst)) then
    if dst ~= nil then
      Logger.warn("merge: %slist replaces %s", key and (tostring(key) .. ": ") or "",
        type(dst) == "table" and "dictionary" or type(dst))
    end
    return Merge.deepCopy(src)
  end
  for _, element in ipairs(src) do dst[#dst + 1] = Merge.deepCopy(element) end
  return dst
end

function Merge.deepCopy(value, seen)
  if type(value) ~= "table" or value == Merge.DELETE then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local copy = {}
  seen[value] = copy
  for k, v in pairs(value) do copy[k] = Merge.deepCopy(v, seen) end
  return copy
end

-- dst is mutated and returned.  Dictionaries merge per key; DELETE unsets;
-- a table/non-table shape clash replaces with a warning so a typo'd patch
-- stays visible instead of silently nesting.  Arrays replace wholesale and
-- extend only through the __append/__prepend wrappers, except under "deep"
-- semantics, where lists append so two mods adding rows to one key both
-- land; there override is the verb that drops a list
function Merge.deepMerge(dst, src, semantics)
  if type(src) ~= "table" or src == Merge.DELETE then return src end
  -- an extension wrapper builds the list even where there was none, so it
  -- is resolved before the shape-clash guard below
  if isWrapper(src) then return extend(dst, src) end
  if type(dst) ~= "table" then
    if dst ~= nil then
      Logger.warn("merge: table replaces non-table value")
    end
    return Merge.deepCopy(src)
  end
  -- a whole-list payload takes the same rule the per-key branch below
  -- applies one level down
  if isArray(src) then
    if semantics == "deep" then return concat(dst, src) end
    return Merge.deepCopy(src)
  end
  for key, value in pairs(src) do
    if value == Merge.DELETE then
      dst[key] = nil
    elseif type(value) == "table" then
      if isWrapper(value) then
        dst[key] = extend(dst[key], value)
      elseif isArray(value) then
        if semantics == "deep" then
          dst[key] = concat(dst[key], value, key)
        else
          dst[key] = Merge.deepCopy(value)
        end
      elseif type(dst[key]) == "table" then
        Merge.deepMerge(dst[key], value, semantics)
      else
        if dst[key] ~= nil then
          Logger.warn("merge: %s: table replaces %s", tostring(key), type(dst[key]))
        end
        dst[key] = Merge.deepCopy(value)
      end
    else
      if type(dst[key]) == "table" then
        Logger.warn("merge: %s: %s replaces table", tostring(key), type(value))
      end
      dst[key] = value
    end
  end
  return dst
end

return Merge
