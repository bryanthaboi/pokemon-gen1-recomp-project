-- Semantic versions and the range grammar manifests use for game_version
-- and for dependency/conflict pins.  No requires, so the headless loader,
-- the doc generator and tools all match on the same implementation.
--
-- Ranges: comparators = > >= < <= ^ (bare version means =), space-separated
-- comparators AND together, || separates alternatives.

local Semver = {}

-- "1", "1.2", "1.2.3", "1.2.3-beta.1"; absent components are 0 and build
-- metadata is parsed then discarded.  nil for anything unparsable -- mod
-- versions stay free-form strings, only range checks need a parse.
function Semver.parse(text)
  if type(text) ~= "string" then return nil end
  local body = text:match("^%s*(.-)%s*$"):gsub("^[vV]", "")
  local plus = body:find("+", 1, true)
  if plus then body = body:sub(1, plus - 1) end
  local core, pre = body:match("^([^%-]+)%-?(.*)$")
  if not core then return nil end
  if core:match("[^%d%.]") or core:match("^%.") or core:match("%.$")
      or core:find("..", 1, true) then
    return nil
  end
  local nums = {}
  for part in core:gmatch("[^%.]+") do nums[#nums + 1] = tonumber(part) end
  if #nums == 0 or #nums > 3 then return nil end
  if pre == "" then
    pre = nil
  elseif not pre:match("^[%w%.%-]+$") then
    return nil
  end
  return { major = nums[1], minor = nums[2] or 0, patch = nums[3] or 0, pre = pre }
end

-- SemVer 2.0 pre-release precedence: a release outranks its pre-releases,
-- numeric identifiers compare numerically and rank below alphanumeric ones,
-- and a longer identifier list wins when every shared field is equal
local function comparePre(a, b)
  if a == b then return 0 end
  if a == nil then return 1 end
  if b == nil then return -1 end
  local left, right = {}, {}
  for part in a:gmatch("[^%.]+") do left[#left + 1] = part end
  for part in b:gmatch("[^%.]+") do right[#right + 1] = part end
  local count = #left > #right and #left or #right
  for i = 1, count do
    local x, y = left[i], right[i]
    if x == nil then return -1 end
    if y == nil then return 1 end
    local nx, ny = tonumber(x), tonumber(y)
    if nx and ny then
      if nx ~= ny then return nx < ny and -1 or 1 end
    elseif nx then
      return -1
    elseif ny then
      return 1
    elseif x ~= y then
      return x < y and -1 or 1
    end
  end
  return 0
end

-- accepts strings or already-parsed tables; nil when either side is unparsable
function Semver.compare(a, b)
  local va = type(a) == "table" and a or Semver.parse(a)
  local vb = type(b) == "table" and b or Semver.parse(b)
  if not va or not vb then return nil end
  for _, field in ipairs({ "major", "minor", "patch" }) do
    local x, y = va[field] or 0, vb[field] or 0
    if x ~= y then return x < y and -1 or 1 end
  end
  return comparePre(va.pre, vb.pre)
end

-- ------- ranges

local OPS = {
  ["="] = true, ["=="] = true, [">"] = true, [">="] = true,
  ["<"] = true, ["<="] = true, ["^"] = true,
}

-- ^ pins the leftmost non-zero component: ^1.2 is >=1.2 <2.0, ^0.2 is
-- >=0.2 <0.3, ^0.0.3 is >=0.0.3 <0.0.4
local function caretUpper(v)
  if v.major > 0 then return { major = v.major + 1, minor = 0, patch = 0 } end
  if v.minor > 0 then return { major = 0, minor = v.minor + 1, patch = 0 } end
  return { major = 0, minor = 0, patch = v.patch + 1 }
end

local function matchToken(version, token)
  local op, rest = token:match("^([=<>%^]*)(.*)$")
  if op == "" then op = "=" end
  if not OPS[op] then
    return nil, ("unknown comparator %q in range"):format(op)
  end
  local target = Semver.parse(rest)
  if not target then
    return nil, ("unparsable version %q in range"):format(rest)
  end
  local order = Semver.compare(version, target)
  if op == "=" or op == "==" then return order == 0 end
  if op == ">" then return order > 0 end
  if op == ">=" then return order >= 0 end
  if op == "<" then return order < 0 end
  if op == "<=" then return order <= 0 end
  return order >= 0 and Semver.compare(version, caretUpper(target)) < 0
end

-- true only when every space-separated comparator in one alternative holds
local function matchAlternative(version, alternative)
  local tokens = 0
  local ok = true
  for token in alternative:gmatch("%S+") do
    tokens = tokens + 1
    local hit, err = matchToken(version, token)
    if err then return nil, err end
    if not hit then ok = false end
  end
  if tokens == 0 then return nil, "empty range alternative" end
  return ok
end

-- returns false with no reason for a clean miss and false plus a reason for
-- an unparsable version or a malformed range; callers turn the reason into a
-- load error (api 2) or a warning (api 1)
function Semver.satisfies(version, range)
  local parsed = Semver.parse(version)
  if not parsed then
    return false, ("unparsable version %q"):format(tostring(version))
  end
  if range == nil or range == "" then return true end
  if type(range) ~= "string" then return false, "range must be a string" end
  local matched = false
  local rest = range
  while true do
    local head, tail = rest:match("^(.-)||(.*)$")
    local alternative = head or rest
    local ok, err = matchAlternative(parsed, alternative)
    if err then return false, err end
    matched = matched or ok
    if not tail then break end
    rest = tail
  end
  return matched
end

-- grammar-only check for manifest validation, where no version is in hand yet
function Semver.validRange(range)
  if range == nil or range == "" then return true end
  local _, err = Semver.satisfies("0.0.0", range)
  if err then return false, err end
  return true
end

return Semver
