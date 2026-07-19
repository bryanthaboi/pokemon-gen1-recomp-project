-- Dev console overlay (POKEPORT_DEV=1, backtick): a Lua REPL with the live
-- game, data and mod list in scope, built-in verbs (warp / give / flag /
-- party / mods / reload) and an event/hook tracer driven off the Runtime
-- buses.  It rides the state stack, so while it is open it owns the
-- keyboard (Game:keypressed routes to onKeyPressed) and the world below
-- does not update.  Never required on a player boot.

local Font = require("src.render.Font")

local Console = {}
Console.__index = Console

local ROWS = 15          -- scrollback rows drawn above the input line
local COLS = 19          -- 160px canvas minus the border
local HISTORY_MAX = 64
local SCROLLBACK_MAX = 200

-- keypressed names -> characters; the console types from key events because
-- love.textinput never reaches Game.  Shift reads the live keyboard.
local KEY_CHARS = {
  space = "  ", ["1"] = "1!", ["2"] = "2@", ["3"] = "3#", ["4"] = "4$",
  ["5"] = "5%", ["6"] = "6^", ["7"] = "7&", ["8"] = "8*", ["9"] = "9(",
  ["0"] = "0)", ["-"] = "-_", ["="] = "=+", ["["] = "[{", ["]"] = "]}",
  ["\\"] = "\\|", [";"] = ";:", ["'"] = "'\"", [","] = ",<", ["."] = ".>",
  ["/"] = "/?",
}

local function shiftDown()
  return love and love.keyboard and love.keyboard.isDown
    and (love.keyboard.isDown("lshift") or love.keyboard.isDown("rshift"))
end

-- one-line pretty printer with a depth fuse, for expression results
local function pp(value, depth)
  depth = depth or 0
  local kind = type(value)
  if kind == "string" then return string.format("%q", value) end
  if kind ~= "table" then return tostring(value) end
  if depth >= 2 then return "{...}" end
  local parts, n = {}, 0
  for k, v in pairs(value) do
    n = n + 1
    if n > 8 then parts[#parts + 1] = "..." break end
    parts[#parts + 1] = tostring(k) .. "=" .. pp(v, depth + 1)
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end

function Console.new(game)
  local self = setmetatable({
    game = game,
    buffer = "",
    lines = {},
    history = {},
    historyIndex = 0,
    scroll = 0,
  }, Console)
  self.env = setmetatable({
    game = game,
    data = game.data,
    mods = game.mods,
    pp = pp,
  }, { __index = _G })
  self:print("dev console -- `help` for verbs, ` to close")
  return self
end

function Console:print(text)
  for line in (tostring(text) .. "\n"):gmatch("([^\n]*)\n") do
    -- wrap to the canvas width so long payload dumps stay readable
    repeat
      self.lines[#self.lines + 1] = line:sub(1, COLS)
      line = line:sub(COLS + 1)
    until line == ""
  end
  while #self.lines > SCROLLBACK_MAX do table.remove(self.lines, 1) end
  self.scroll = 0
end

-- ------- tracer

-- glob -> anchored lua pattern ("battle.*" matches battle.turn etc.)
local function globPattern(glob)
  local escaped = glob:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0")
  return "^" .. escaped:gsub("%*", ".*") .. "$"
end

-- The buses have no name catalog to subscribe against, so the tracer shims
-- the live instances: an instance field shadows the class method and
-- removing it restores the original.  Runtime.wants is widened too, or
-- guarded call sites would skip payload construction for unwatched names.
function Console:startTrace(glob)
  self:stopTrace()
  local Runtime = require("src.mods.Runtime")
  local loader = self.game.mods
  local events = loader and loader.events
  local hooks = loader and loader.hooks
  if not (events and hooks) then
    self:print("trace: no loader buses")
    return
  end
  local pattern = globPattern(glob)
  local function matches(name)
    return type(name) == "string" and name:match(pattern) ~= nil
  end
  local console = self
  local trace = {
    glob = glob, events = events, hooks = hooks,
    emit = events.emit, call = hooks.call,
    wants = Runtime.wants, wantsHook = Runtime.wantsHook,
  }
  events.emit = function(bus, name, payload)
    if matches(name) then
      console:print("[event] " .. name .. " " .. pp(payload))
    end
    return trace.emit(bus, name, payload)
  end
  hooks.call = function(bus, name, vanilla, ...)
    if not matches(name) then return trace.call(bus, name, vanilla, ...) end
    console:print("[hook] " .. name .. " in " .. pp({ ... }))
    local result = { trace.call(bus, name, vanilla, ...) }
    console:print("[hook] " .. name .. " out " .. pp(result))
    local unpack_ = table.unpack or unpack
    return unpack_(result)
  end
  Runtime.wants = function(name)
    return matches(name) or trace.wants(name)
  end
  Runtime.wantsHook = function(name)
    return matches(name) or trace.wantsHook(name)
  end
  self.trace = trace
  self:print(("tracing %s"):format(glob))
end

function Console:stopTrace()
  local trace = self.trace
  if not trace then return end
  local Runtime = require("src.mods.Runtime")
  -- clearing the instance fields re-exposes the class methods
  trace.events.emit = nil
  trace.hooks.call = nil
  Runtime.wants = trace.wants
  Runtime.wantsHook = trace.wantsHook
  self.trace = nil
end

-- ------- verbs

local VERBS = {}

function VERBS.help(self)
  self:print("warp MAP [x y]")
  self:print("give ID [n|level]")
  self:print("flag NAME [on|off]")
  self:print("party  mods  reload")
  self:print("trace PAT | trace off")
  self:print("anything else = lua")
end

function VERBS.mods(self)
  local status = self.game.modStatus
    or (self.game.mods and self.game.mods:status())
  if not status then
    self:print("no loader")
    return
  end
  for _, mod in ipairs(status.available) do
    self:print(("%s %s %s"):format(mod.id, mod.version or "?", mod.state))
  end
  self:print(("%d errors"):format(#status.errors))
end

function VERBS.reload(self)
  self:stopTrace()
  local _, summary = require("src.dev.HotReload").run(self.game)
  -- the reload swapped the buses and the env's loader reference with them
  self.env.mods = self.game.mods
  self.env.data = self.game.data
  self:print(summary)
end

function VERBS.warp(self, rest)
  local mapId, x, y = rest:match("^(%S+)%s*(%d*)%s*(%d*)")
  local game = self.game
  if not mapId or not (game.data.maps and game.data.maps[mapId]) then
    self:print("unknown map: " .. tostring(mapId))
    return
  end
  x, y = tonumber(x) or 5, tonumber(y) or 5
  -- the driver kit's teleport rebuild: everything (this console included)
  -- pops and a fresh overworld enters at the target
  while game.stack:top() do game.stack:pop() end
  game.stack:push(require("src.world.OverworldController"), mapId, x, y, "down")
end

function VERBS.give(self, rest)
  local id, count = rest:match("^(%S+)%s*(%d*)")
  local game = self.game
  local save = game.save
  if not id or id == "" then
    self:print("give what?")
    return
  end
  if game.data.pokemon and game.data.pokemon[id] then
    local level = tonumber(count) or 5
    local mon = require("src.pokemon.Pokemon").new(game.data, id, level)
    if require("src.pokemon.Party").add(save.party, mon) then
      self:print(("%s L%d joined the party"):format(id, level))
    elseif require("src.pokemon.Boxes").deposit(save, mon) then
      self:print(("%s L%d sent to the PC"):format(id, level))
    else
      self:print("party and boxes full")
    end
  elseif game.data.items and game.data.items[id] then
    local n = tonumber(count) or 1
    if require("src.inventory.Bag").add(save, id, n) then
      self:print(("%s x%d added"):format(id, n))
    else
      self:print("bag full")
    end
  else
    self:print("unknown id: " .. id)
  end
end

function VERBS.flag(self, rest)
  local name, value = rest:match("^(%S+)%s*(%S*)")
  local flags = self.game.save and self.game.save.flags
  if not name or not flags then
    self:print("flag what?")
    return
  end
  if value == "on" then
    flags[name] = true
  elseif value == "off" then
    flags[name] = nil
  end
  self:print(("%s = %s"):format(name, tostring(flags[name] or false)))
end

function VERBS.party(self)
  local party = self.game.save and self.game.save.party or {}
  if #party == 0 then
    self:print("(empty)")
    return
  end
  for i, mon in ipairs(party) do
    self:print(("%d %s L%d %d/%d"):format(i, tostring(mon.species),
      mon.level or 0, mon.hp or 0, (mon.stats and mon.stats.hp) or 0))
  end
end

function VERBS.trace(self, rest)
  local glob = rest:match("^(%S+)")
  if not glob or glob == "off" then
    self:stopTrace()
    if glob then self:print("trace off") end
    return
  end
  self:startTrace(glob)
end

-- ------- repl

function Console:exec(line)
  self:print("> " .. line)
  if line:match("^%s*$") then return end
  self.history[#self.history + 1] = line
  while #self.history > HISTORY_MAX do table.remove(self.history, 1) end
  self.historyIndex = #self.history + 1
  local verb, rest = line:match("^(%S+)%s*(.*)$")
  local handler = VERBS[verb]
  if handler then
    local ok, err = pcall(handler, self, rest or "")
    if not ok then self:print("error: " .. tostring(err)) end
    return
  end
  -- expression first so `1+1` prints 2; statements fall through
  local chunk, err = loadstring("return " .. line, "=console")
  if not chunk then
    chunk, err = loadstring(line, "=console")
  end
  if not chunk then
    self:print("error: " .. tostring(err))
    return
  end
  setfenv(chunk, self.env)
  local results = { pcall(chunk) }
  if not results[1] then
    self:print("error: " .. tostring(results[2]))
    return
  end
  if #results == 1 then return end
  for i = 2, #results do
    self:print(pp(results[i]))
  end
end

-- tab completion against the env (and one dotted level into it)
function Console:complete()
  local prefix, partial = self.buffer:match("^(.-)([%w_%.]*)$")
  local holder, field = partial:match("^([%w_]+)%.([%w_]*)$")
  local scope, stem
  if holder then
    local ok, value = pcall(function() return self.env[holder] end)
    if not ok or type(value) ~= "table" then return end
    scope, stem = value, field
    prefix = prefix .. holder .. "."
  else
    scope, stem = self.env, partial
  end
  local matches = {}
  local seen = scope
  while type(seen) == "table" do
    for key in pairs(seen) do
      if type(key) == "string" and key:sub(1, #stem) == stem then
        matches[#matches + 1] = key
      end
    end
    local meta = getmetatable(seen)
    seen = meta and meta.__index
    if type(seen) ~= "table" then break end
  end
  table.sort(matches)
  if #matches == 1 then
    self.buffer = prefix .. matches[1]
  elseif #matches > 1 then
    self:print(table.concat(matches, " ", 1, math.min(#matches, 12)))
  end
end

-- ------- input & drawing

function Console:onKeyPressed(key)
  if key == "`" then
    self:stopTrace()
    self.game.stack:pop()
  elseif key == "return" or key == "kpenter" then
    local line = self.buffer
    self.buffer = ""
    self:exec(line)
  elseif key == "backspace" then
    self.buffer = self.buffer:sub(1, -2)
  elseif key == "tab" then
    self:complete()
  elseif key == "up" then
    if self.historyIndex > 1 then
      self.historyIndex = self.historyIndex - 1
      self.buffer = self.history[self.historyIndex] or ""
    end
  elseif key == "down" then
    if self.historyIndex <= #self.history then
      self.historyIndex = self.historyIndex + 1
      self.buffer = self.history[self.historyIndex] or ""
    end
  elseif key == "pageup" then
    self.scroll = math.min(self.scroll + ROWS,
      math.max(0, #self.lines - ROWS))
  elseif key == "pagedown" then
    self.scroll = math.max(0, self.scroll - ROWS)
  else
    local chars = KEY_CHARS[key]
    if chars then
      local index = shiftDown() and 2 or 1
      self.buffer = self.buffer .. chars:sub(index, index)
    elseif key:match("^%a$") then
      self.buffer = self.buffer .. (shiftDown() and key:upper() or key)
    elseif key:match("^kp%d$") then
      self.buffer = self.buffer .. key:sub(3)
    end
  end
end

function Console:update() end

function Console:exit()
  self:stopTrace()
end

function Console:draw()
  love.graphics.setColor(1, 1, 1, 0.92)
  love.graphics.rectangle("fill", 0, 0, 160, 144)
  love.graphics.setColor(0, 0, 0, 1)
  local first = math.max(1, #self.lines - ROWS + 1 - self.scroll)
  local row = 0
  for i = first, math.min(#self.lines, first + ROWS - 1) do
    Font.draw(self.lines[i], 4, 2 + row * 9)
    row = row + 1
  end
  local input = "> " .. self.buffer
  -- keep the tail visible while typing past the canvas edge
  if #input > COLS then input = input:sub(#input - COLS + 1) end
  Font.draw(input, 4, 134)
  love.graphics.setColor(1, 1, 1, 1)
end

return Console
