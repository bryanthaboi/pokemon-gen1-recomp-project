local LuaWriter = {}

local KEYWORDS = {
  ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true,
  ["elseif"] = true, ["end"] = true, ["false"] = true, ["for"] = true,
  ["function"] = true, ["goto"] = true, ["if"] = true, ["in"] = true,
  ["local"] = true, ["nil"] = true, ["not"] = true, ["or"] = true,
  ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true,
  ["until"] = true, ["while"] = true,
}

local function quote(value)
  local escaped = value:gsub('[%z\1-\31\\"]', function(character)
    if character == "\\" then return "\\\\" end
    if character == '"' then return '\\"' end
    if character == "\n" then return "\\n" end
    if character == "\r" then return "\\r" end
    if character == "\t" then return "\\t" end
    return ("\\%03d"):format(character:byte())
  end)
  return '"' .. escaped .. '"'
end

local function keyText(key)
  if type(key) == "string"
      and key:match("^[A-Za-z_][A-Za-z0-9_]*$")
      and not KEYWORDS[key] then
    return key
  end
  return "[" .. (type(key) == "string" and quote(key) or tostring(key)) .. "]"
end

local function isArray(value)
  local count, maximum = 0, 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return false, 0
    end
    count = count + 1
    maximum = math.max(maximum, key)
  end
  return count == maximum, maximum
end

local function sortedKeys(value)
  local keys = {}
  for key in pairs(value) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b)
    if type(a) == type(b) then return a < b end
    return type(a) == "number"
  end)
  return keys
end

local function encode(value, indent, seen)
  local kind = type(value)
  if value == nil then return "nil" end
  if kind == "boolean" or kind == "number" then return tostring(value) end
  if kind == "string" then return quote(value) end
  if kind ~= "table" then
    error("cannot serialize " .. kind)
  end
  if seen[value] then error("cannot serialize a cyclic table") end
  seen[value] = true

  local pad = string.rep("  ", indent)
  local childPad = string.rep("  ", indent + 1)
  local out = {}
  local array, length = isArray(value)
  if array then
    for index = 1, length do
      out[#out + 1] = childPad .. encode(value[index], indent + 1, seen) .. ","
    end
  else
    for _, key in ipairs(sortedKeys(value)) do
      out[#out + 1] = childPad .. keyText(key) .. " = "
        .. encode(value[key], indent + 1, seen) .. ","
    end
  end
  seen[value] = nil
  if #out == 0 then return "{}" end
  return "{\n" .. table.concat(out, "\n") .. "\n" .. pad .. "}"
end

function LuaWriter.encode(value)
  return "return " .. encode(value, 0, {}) .. "\n"
end

function LuaWriter.write(path, value)
  -- CacheFs routes this to the OS save directory (normal builds) or straight
  -- into the game folder (portable installs); it also creates the parent
  -- directories.  See src/import/CacheFs.lua.
  local CacheFs = require("src.import.CacheFs")
  local ok, err = CacheFs.write(path, LuaWriter.encode(value))
  if not ok then error("could not write " .. path .. ": " .. tostring(err)) end
end

return LuaWriter
