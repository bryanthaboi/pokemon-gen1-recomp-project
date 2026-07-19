-- Save-file serialization: the deterministic Lua-source writer (moved
-- verbatim from SaveData so output stays byte-identical) and a
-- restricted-grammar reader that replaces load() on save bytes.  The
-- writer is the grammar's specification -- literals, %q strings and keyed
-- tables only -- so a hand-tampered or malicious save fails to parse
-- instead of executing.

local SaveSerializer = {}

-- ------- writer

local function serialize(v, indent)
  indent = indent or 0
  local pad = string.rep("  ", indent)
  local t = type(v)
  if t == "number" or t == "boolean" then
    return tostring(v)
  elseif t == "string" then
    return string.format("%q", v)
  elseif t == "table" then
    local keys = {}
    for k in pairs(v) do table.insert(keys, k) end
    table.sort(keys, function(a, b)
      local ta, tb = type(a), type(b)
      if ta ~= tb then return ta < tb end
      return a < b
    end)
    if next(v) == nil then return "{}" end
    local parts = {}
    for _, k in ipairs(keys) do
      local key
      if type(k) == "string" and k:match("^[%a_][%w_]*$") then
        key = k
      else
        key = "[" .. serialize(k) .. "]"
      end
      table.insert(parts, pad .. "  " .. key .. " = " .. serialize(v[k], indent + 1))
    end
    return "{\n" .. table.concat(parts, ",\n") .. ",\n" .. pad .. "}"
  end
  error("cannot serialize " .. t)
end

function SaveSerializer.encode(data)
  return "return " .. serialize(data) .. "\n"
end

-- ------- reader

-- letter escapes %q has emitted across the Lua 5.x family; LuaJIT writes
-- control characters as \ddd decimal escapes, handled separately below
local ESCAPES = {
  ['"'] = '"', ["\\"] = "\\", ["n"] = "\n", ["r"] = "\r", ["t"] = "\t",
  ["a"] = "\a", ["b"] = "\b", ["f"] = "\f", ["v"] = "\v",
  ["\n"] = "\n", ["\r"] = "\n",
}

-- recursion cap: a crafted file nesting thousands of braces must fail
-- closed, not blow the interpreter stack
local MAX_DEPTH = 128

local function fail(state, why)
  error(("parse error at byte %d: %s"):format(state.pos, why), 0)
end

local function skip(state)
  local _, last = state.src:find("^[ \t\r\n]*", state.pos)
  state.pos = last + 1
end

local function peek(state)
  return state.src:sub(state.pos, state.pos)
end

local function readString(state)
  local src = state.src
  local out = {}
  local i = state.pos + 1
  while true do
    local c = src:sub(i, i)
    if c == "" then
      state.pos = i
      fail(state, "unterminated string")
    elseif c == '"' then
      state.pos = i + 1
      return table.concat(out)
    elseif c == "\\" then
      local nxt = src:sub(i + 1, i + 1)
      if nxt:match("%d") then
        local digits = src:match("^%d%d?%d?", i + 1)
        local code = tonumber(digits)
        if code > 255 then
          state.pos = i
          fail(state, "escape out of range")
        end
        out[#out + 1] = string.char(code)
        i = i + 1 + #digits
      elseif ESCAPES[nxt] then
        out[#out + 1] = ESCAPES[nxt]
        i = i + 2
      else
        state.pos = i
        fail(state, "bad string escape")
      end
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
end

-- a number runs to the next delimiter; tonumber is the judge of what the
-- writer's tostring could have produced ("0.1", "-2", "1e+300")
local function readNumber(state)
  local token = state.src:match("^[^,%]}%s]+", state.pos)
  local value = token and tonumber(token)
  if value == nil then fail(state, "malformed number") end
  state.pos = state.pos + #token
  return value
end

local function readIdent(state)
  local ident = state.src:match("^[%a_][%w_]*", state.pos)
  if not ident then fail(state, "expected name") end
  state.pos = state.pos + #ident
  return ident
end

local readValue

local function readTable(state)
  state.depth = state.depth + 1
  if state.depth > MAX_DEPTH then fail(state, "table nesting too deep") end
  state.pos = state.pos + 1
  local out = {}
  skip(state)
  if peek(state) == "}" then
    state.pos = state.pos + 1
    state.depth = state.depth - 1
    return out
  end
  while true do
    skip(state)
    local key
    local c = peek(state)
    if c == "[" then
      state.pos = state.pos + 1
      key = readValue(state)
      skip(state)
      if peek(state) ~= "]" then fail(state, "expected ]") end
      state.pos = state.pos + 1
    elseif c:match("[%a_]") then
      key = readIdent(state)
    else
      fail(state, "expected key")
    end
    skip(state)
    if peek(state) ~= "=" then fail(state, "expected =") end
    state.pos = state.pos + 1
    out[key] = readValue(state)
    skip(state)
    local sep = peek(state)
    if sep == "," then
      state.pos = state.pos + 1
      skip(state)
      if peek(state) == "}" then
        state.pos = state.pos + 1
        break
      end
    elseif sep == "}" then
      state.pos = state.pos + 1
      break
    else
      fail(state, "expected , or }")
    end
  end
  state.depth = state.depth - 1
  return out
end

readValue = function(state)
  skip(state)
  local c = peek(state)
  if c == '"' then
    return readString(state)
  elseif c == "{" then
    return readTable(state)
  elseif c:match("[%a_]") then
    -- the only bare words in the grammar are the boolean literals
    local word = readIdent(state)
    if word == "true" then return true end
    if word == "false" then return false end
    state.pos = state.pos - #word
    fail(state, "unexpected name '" .. word .. "'")
  elseif c:match("[%-%d%.]") then
    return readNumber(state)
  end
  fail(state, c == "" and "unexpected end of input" or "unexpected character")
end

function SaveSerializer.decode(str)
  if type(str) ~= "string" then return nil, "save must be a string" end
  local state = { src = str, pos = 1, depth = 0 }
  local ok, result = pcall(function()
    skip(state)
    local word = state.src:match("^[%a_][%w_]*", state.pos)
    if word ~= "return" then fail(state, "expected return") end
    state.pos = state.pos + #word
    local value = readValue(state)
    skip(state)
    if state.pos <= #state.src then fail(state, "trailing content") end
    return value
  end)
  if not ok then return nil, result end
  if type(result) ~= "table" then return nil, "save root must be a table" end
  return result
end

return SaveSerializer
