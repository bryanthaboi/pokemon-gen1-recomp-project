-- Minimal JSON encoder/decoder for the link protocol (objects, arrays,
-- strings, numbers, booleans, null).  No unicode escapes beyond \uXXXX
-- pass-through; good enough for our own messages.

local Json = {}

local function encodeValue(v, out)
  local t = type(v)
  if v == nil then
    out[#out + 1] = "null"
  elseif t == "boolean" then
    out[#out + 1] = v and "true" or "false"
  elseif t == "number" then
    out[#out + 1] = string.format("%.17g", v)
  elseif t == "string" then
    out[#out + 1] = '"' .. v:gsub('[%c"\\]', function(c)
      if c == '"' then return '\\"' end
      if c == "\\" then return "\\\\" end
      if c == "\n" then return "\\n" end
      if c == "\r" then return "\\r" end
      if c == "\t" then return "\\t" end
      return string.format("\\u%04x", c:byte())
    end) .. '"'
  elseif t == "table" then
    -- array if [1..n] contiguous
    local n = #v
    local isArray = n > 0
    if not isArray then
      isArray = next(v) == nil -- empty table -> []
    end
    if isArray then
      out[#out + 1] = "["
      for i = 1, n do
        if i > 1 then out[#out + 1] = "," end
        encodeValue(v[i], out)
      end
      out[#out + 1] = "]"
    else
      out[#out + 1] = "{"
      local first = true
      for k, val in pairs(v) do
        if not first then out[#out + 1] = "," end
        first = false
        encodeValue(tostring(k), out)
        out[#out + 1] = ":"
        encodeValue(val, out)
      end
      out[#out + 1] = "}"
    end
  else
    error("cannot encode " .. t)
  end
end

function Json.encode(v)
  local out = {}
  encodeValue(v, out)
  return table.concat(out)
end

-- decoder -------------------------------------------------------------

local function skipWs(s, i)
  return (s:find("[^ \t\r\n]", i)) or (#s + 1)
end

local decodeValue

local function decodeString(s, i)
  -- i points at opening quote
  local out = {}
  i = i + 1
  while i <= #s do
    local c = s:sub(i, i)
    if c == '"' then
      return table.concat(out), i + 1
    elseif c == "\\" then
      local esc = s:sub(i + 1, i + 1)
      if esc == "n" then out[#out + 1] = "\n"
      elseif esc == "r" then out[#out + 1] = "\r"
      elseif esc == "t" then out[#out + 1] = "\t"
      elseif esc == "b" then out[#out + 1] = string.char(8)
      elseif esc == "f" then out[#out + 1] = string.char(12)
      elseif esc == "u" then
        local hex = s:sub(i + 2, i + 5)
        local code = tonumber(hex, 16) or 32
        if code < 128 then
          out[#out + 1] = string.char(code)
        else -- utf8 encode (2-3 bytes covers our charmap)
          if code < 0x800 then
            out[#out + 1] = string.char(0xC0 + math.floor(code / 0x40),
                                        0x80 + code % 0x40)
          else
            out[#out + 1] = string.char(0xE0 + math.floor(code / 0x1000),
                                        0x80 + math.floor(code / 0x40) % 0x40,
                                        0x80 + code % 0x40)
          end
        end
        i = i + 4
      else
        out[#out + 1] = esc
      end
      i = i + 2
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  error("unterminated string")
end

decodeValue = function(s, i)
  i = skipWs(s, i)
  local c = s:sub(i, i)
  if c == '"' then
    return decodeString(s, i)
  elseif c == "{" then
    local obj = {}
    i = skipWs(s, i + 1)
    if s:sub(i, i) == "}" then return obj, i + 1 end
    while true do
      local key
      key, i = decodeString(s, skipWs(s, i))
      i = skipWs(s, i)
      assert(s:sub(i, i) == ":", "expected :")
      local val
      val, i = decodeValue(s, i + 1)
      obj[key] = val
      i = skipWs(s, i)
      local d = s:sub(i, i)
      if d == "}" then return obj, i + 1 end
      assert(d == ",", "expected , or }")
      i = i + 1
    end
  elseif c == "[" then
    local arr = {}
    i = skipWs(s, i + 1)
    if s:sub(i, i) == "]" then return arr, i + 1 end
    while true do
      local val
      val, i = decodeValue(s, i)
      arr[#arr + 1] = val
      i = skipWs(s, i)
      local d = s:sub(i, i)
      if d == "]" then return arr, i + 1 end
      assert(d == ",", "expected , or ]")
      i = i + 1
    end
  elseif c == "t" then
    assert(s:sub(i, i + 3) == "true")
    return true, i + 4
  elseif c == "f" then
    assert(s:sub(i, i + 4) == "false")
    return false, i + 5
  elseif c == "n" then
    assert(s:sub(i, i + 3) == "null")
    return nil, i + 4
  else
    local numStr = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
    assert(numStr and #numStr > 0, "unexpected character '" .. c .. "'")
    return tonumber(numStr), i + #numStr
  end
end

function Json.decode(s)
  local ok, v = pcall(function()
    local val = select(1, decodeValue(s, 1))
    return val
  end)
  if ok then return v end
  return nil, v
end

return Json
