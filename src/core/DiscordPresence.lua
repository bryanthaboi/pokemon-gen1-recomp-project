-- Discord Rich Presence via the local Discord IPC pipe.  Shows the player's
-- current map (and battle status) on their Discord profile.  Desktop only;
-- no-ops on mobile, headless runs, or when Discord is not running.
--
-- Application ID is the only credential needed for presence.  The Discord
-- Interactions public key is unused here (that is for verifying bot HTTP
-- payloads, not Rich Presence).

local Json = require("src.link.Json")
local Logger = require("src.core.Logger")
local Runtime = require("src.mods.Runtime")

local DiscordPresence = {
  APP_ID = "1529183141267374262",
}

local OP_HANDSHAKE, OP_FRAME, OP_CLOSE = 0, 1, 2

local MIN_UPDATE_INTERVAL = 2.0
local RECONNECT_INTERVAL = 30.0

local state = {
  enabled = false,
  connected = false,
  socket = nil,       -- Windows: file handle; Unix: ffi sockfd
  isWindows = false,
  ffi = nil,
  ffiReady = false,
  startedAt = 0,
  dirty = false,
  lastSentKey = nil,
  lastSendAt = -1e9,
  nextReconnectAt = 0,
  location = nil,     -- display name
  mapId = nil,
  activity = "menu",  -- menu | exploring | battle
  battleLabel = nil,
  unsubs = {},
  pid = nil,
  loggedAbsent = false, -- one quiet note when Discord isn't running
}

local function disabledByEnv()
  return os.getenv("POKEPORT_NO_DISCORD") == "1"
      or os.getenv("POKEPORT_AUTOPILOT") ~= nil
      or os.getenv("POKEPORT_DRIVER") ~= nil
end

local function isDesktop()
  if not love or not love.system or not love.system.getOS then return false end
  local osName = love.system.getOS()
  return osName == "OS X" or osName == "Windows" or osName == "Linux"
end

local function packU32(n)
  n = math.floor(n) % 0x100000000
  local b1 = n % 256; n = math.floor(n / 256)
  local b2 = n % 256; n = math.floor(n / 256)
  local b3 = n % 256; n = math.floor(n / 256)
  local b4 = n % 256
  return string.char(b1, b2, b3, b4)
end

local function unpackU32(s)
  local b1, b2, b3, b4 = s:byte(1, 4)
  return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

local function nonce()
  return string.format("%08x-%04x-4%03x-%04x-%04x%08x",
    math.random(0, 0xffffffff),
    math.random(0, 0xffff),
    math.random(0, 0xfff),
    math.random(0, 0x3fff) + 0x8000,
    math.random(0, 0xffff),
    math.random(0, 0xffffffff))
end

local function resolvePid()
  if state.pid then return state.pid end
  local ffi = state.ffi
  if ffi then
    if state.isWindows then
      pcall(ffi.cdef, "unsigned long GetCurrentProcessId(void);")
      local ok, p = pcall(function() return ffi.C.GetCurrentProcessId() end)
      if ok and p and tonumber(p) and tonumber(p) > 0 then
        state.pid = tonumber(p)
        return state.pid
      end
    else
      pcall(ffi.cdef, "int getpid(void);")
      local ok, p = pcall(function() return ffi.C.getpid() end)
      if ok and p and tonumber(p) and tonumber(p) > 0 then
        state.pid = tonumber(p)
        return state.pid
      end
    end
  end
  state.pid = 1000 + math.random(1, 8999)
  return state.pid
end

local function ensureFfi()
  if state.ffiReady then return state.ffi end
  if state.ffi == false then return nil end
  local ok, ffi = pcall(require, "ffi")
  if not ok or not ffi then
    state.ffi = false
    return nil
  end
  state.ffi = ffi
  if state.isWindows then
    state.ffiReady = true
    return ffi
  end
  -- Darwin sockaddr_un has sun_len + uint8_t family; Linux uses u16 family.
  local osName = love.system.getOS()
  local cdef
  if osName == "OS X" then
    cdef = [[
      typedef unsigned int socklen_t;
      typedef int ssize_t;
      struct sockaddr_un {
        uint8_t sun_len;
        uint8_t sun_family;
        char sun_path[104];
      };
      struct timeval { long tv_sec; int tv_usec; };
      int socket(int domain, int type, int protocol);
      int connect(int sockfd, const void *addr, socklen_t addrlen);
      int setsockopt(int sockfd, int level, int optname, const void *optval, socklen_t optlen);
      ssize_t send(int sockfd, const void *buf, size_t len, int flags);
      ssize_t recv(int sockfd, void *buf, size_t len, int flags);
      int close(int fd);
    ]]
  else
    cdef = [[
      typedef unsigned int socklen_t;
      typedef int ssize_t;
      struct sockaddr_un {
        unsigned short sun_family;
        char sun_path[108];
      };
      struct timeval { long tv_sec; long tv_usec; };
      int socket(int domain, int type, int protocol);
      int connect(int sockfd, const void *addr, socklen_t addrlen);
      int setsockopt(int sockfd, int level, int optname, const void *optval, socklen_t optlen);
      ssize_t send(int sockfd, const void *buf, size_t len, int flags);
      ssize_t recv(int sockfd, void *buf, size_t len, int flags);
      int close(int fd);
    ]]
  end
  -- cdef may already be registered from a prior boot; either way we need
  -- sockaddr_un usable before claiming readiness
  pcall(ffi.cdef, cdef)
  local ready = pcall(function() return ffi.new("struct sockaddr_un") end)
  if not ready then
    state.ffi = false
    state.ffiReady = false
    return nil
  end
  state.ffiReady = true
  return ffi
end

local function closeSocket()
  local sock = state.socket
  state.socket = nil
  state.connected = false
  if not sock then return end
  if state.isWindows then
    pcall(function() sock:close() end)
  elseif state.ffi then
    pcall(state.ffi.C.close, sock)
  end
end

local function writeRaw(bytes)
  if not state.socket then return false end
  if state.isWindows then
    local ok = pcall(function()
      state.socket:seek("end")
      local _, writeErr = state.socket:write(bytes)
      state.socket:flush()
      if writeErr then error(writeErr) end
    end)
    return ok
  end
  local ffi = state.ffi
  if not ffi then return false end
  local ok, sent = pcall(ffi.C.send, state.socket, bytes, #bytes, 0)
  return ok and sent == #bytes
end

local function sendFrame(opcode, payload)
  local body = payload or ""
  local ok, frame = pcall(function()
    return packU32(opcode) .. packU32(#body) .. body
  end)
  if not ok or not frame then return false end
  return writeRaw(frame)
end

local function readExact(n)
  if not state.socket or n <= 0 then return nil end
  if state.isWindows then
    local ok, data = pcall(function() return state.socket:read(n) end)
    if not ok or not data or #data < n then return nil end
    return data
  end
  local ffi = state.ffi
  if not ffi then return nil end
  local ok, data = pcall(function()
    local buf = ffi.new("char[?]", n)
    local got = 0
    while got < n do
      local nread = ffi.C.recv(state.socket, buf + got, n - got, 0)
      if not nread or nread <= 0 then return nil end
      got = got + tonumber(nread)
    end
    return ffi.string(buf, n)
  end)
  if not ok then return nil end
  return data
end

local function receiveFrame()
  local header = readExact(8)
  if not header then return nil end
  local ok, opcode, length = pcall(function()
    return unpackU32(header:sub(1, 4)), unpackU32(header:sub(5, 8))
  end)
  if not ok or not opcode or not length or length < 0 or length > 65536 then
    return nil
  end
  local data = length > 0 and readExact(length) or ""
  if data == nil then return nil end
  return opcode, data
end

local function unixSocketPaths()
  local paths = {}
  local envs = { "XDG_RUNTIME_DIR", "TMPDIR", "TMP", "TEMP" }
  local bases = {}
  for _, key in ipairs(envs) do
    local v = os.getenv(key)
    if v and v ~= "" then
      if v:sub(-1) == "/" then v = v:sub(1, -2) end
      bases[#bases + 1] = v
    end
  end
  bases[#bases + 1] = "/tmp"
  local suffixes = {
    "",
    "/app/com.discordapp.Discord",
    "/app/com.discordapp.DiscordCanary",
    "/app/com.discordapp.DiscordPTB",
    "/snap.discord",
    "/snap.discord-canary",
  }
  local seen = {}
  for i = 0, 9 do
    local name = "discord-ipc-" .. i
    for _, base in ipairs(bases) do
      for _, suffix in ipairs(suffixes) do
        local path = base .. suffix .. "/" .. name
        if not seen[path] then
          seen[path] = true
          paths[#paths + 1] = path
        end
      end
    end
  end
  return paths
end

local function setSocketTimeout(fd, seconds)
  local ffi = state.ffi
  if not ffi or not fd then return end
  pcall(function()
    local tv = ffi.new("struct timeval")
    tv.tv_sec = seconds
    tv.tv_usec = 0
    -- SOL_SOCKET / SO_RCVTIMEO / SO_SNDTIMEO differ by OS
    local sol, rcv, snd
    if love.system.getOS() == "OS X" then
      sol, rcv, snd = 0xffff, 0x1006, 0x1005
    else
      sol, rcv, snd = 1, 20, 21
    end
    ffi.C.setsockopt(fd, sol, rcv, tv, ffi.sizeof(tv))
    ffi.C.setsockopt(fd, sol, snd, tv, ffi.sizeof(tv))
  end)
end

local function connectUnix()
  local ffi = ensureFfi()
  if not ffi then return false end
  local darwin = love.system.getOS() == "OS X"
  local maxPath = darwin and 103 or 107
  -- AF_UNIX=1, SOCK_STREAM=1 on Linux/macOS
  local pathsOk, paths = pcall(unixSocketPaths)
  if not pathsOk or not paths then return false end
  for _, path in ipairs(paths) do
    if #path <= maxPath then
      local ok, connected = pcall(function()
        local fd = ffi.C.socket(1, 1, 0)
        if not fd or fd < 0 then return false end
        local addr = ffi.new("struct sockaddr_un")
        addr.sun_family = 1
        if darwin then
          -- SUN_LEN: sizeof(sun_len+sun_family) + path + NUL
          addr.sun_len = 2 + #path + 1
        end
        ffi.copy(addr.sun_path, path)
        local rc = ffi.C.connect(fd, ffi.cast("void*", addr), ffi.sizeof(addr))
        if rc == 0 then
          setSocketTimeout(fd, 1) -- handshake must not freeze the game
          state.socket = fd
          return true
        end
        ffi.C.close(fd)
        return false
      end)
      if ok and connected then return true end
    end
  end
  return false
end

local function connectWindows()
  for i = 0, 9 do
    local path = "\\\\.\\pipe\\discord-ipc-" .. i
    local ok, file = pcall(io.open, path, "r+")
    if ok and file then
      state.socket = file
      return true
    end
  end
  return false
end

local function handshake()
  local ok, payload = pcall(Json.encode, { v = 1, client_id = DiscordPresence.APP_ID })
  if not ok or not payload then return false end
  if not sendFrame(OP_HANDSHAKE, payload) then return false end
  -- Discord echoes READY as a FRAME.  A timeout/missing client is a soft miss.
  local opcode = receiveFrame()
  if opcode == OP_FRAME then return true end
  -- Windows named pipes have no easy read timeout: if the write succeeded
  -- and Discord is present, proceed optimistically so boot never blocks.
  if state.isWindows then return true end
  return false
end

local function noteAbsent()
  if state.loggedAbsent then return end
  state.loggedAbsent = true
  -- info, not warn: missing Discord is normal for many players
  Logger.info("discord: rich presence unavailable (Discord not running)")
end

local function connect()
  local ok, result = pcall(function()
    closeSocket()
    local linked
    if state.isWindows then
      linked = connectWindows()
    else
      linked = connectUnix()
    end
    if not linked then return false end
    if not handshake() then
      closeSocket()
      return false
    end
    state.connected = true
    state.dirty = true
    state.lastSentKey = nil
    state.loggedAbsent = false
    Logger.info("discord: rich presence connected")
    return true
  end)
  if not ok then
    closeSocket()
    return false
  end
  return result and true or false
end

local function locationName(game, mapId)
  if not mapId then return nil end
  local field = game and game.data and game.data.field
  local townMap = field and field.townMap
  local locations = townMap and (townMap.locations or townMap)
  local entry = type(locations) == "table" and locations[mapId]
  if type(entry) == "table" then
    local name = entry.name or entry.label
    if type(name) == "string" and name ~= "" then return name end
  end
  local def = game and game.data and game.data.maps and game.data.maps[mapId]
  if def and type(def.label) == "string" and def.label ~= "" then
    -- PalletTown -> Pallet Town
    return def.label:gsub("(%l)(%u)", "%1 %2")
  end
  return tostring(mapId):gsub("_", " ")
end

local function speciesName(game, species)
  if not species or not game or not game.data or not game.data.pokemon then
    return nil
  end
  local def = game.data.pokemon[species]
  return def and def.name or tostring(species):gsub("_", " ")
end

local function buildActivity()
  local details, activityState
  if state.activity == "battle" then
    details = state.battleLabel or "In battle"
    activityState = state.location and (state.location) or "Kanto"
  elseif state.activity == "exploring" and state.location then
    details = state.location
    activityState = "Exploring the overworld"
  else
    details = state.location or "Kanto"
    activityState = "At the title screen"
  end

  return {
    details = details,
    state = activityState,
    timestamps = { start = state.startedAt },
    assets = {
      large_image = "logo",
      large_text = "Pokemon Gen1Recomp",
    },
  }
end

local function activityKey(activity)
  return (activity.details or "") .. "|" .. (activity.state or "")
end

local function flush(force)
  if not state.enabled or not state.connected then return end
  local ok = pcall(function()
    local now = love.timer.getTime()
    if not force and (now - state.lastSendAt) < MIN_UPDATE_INTERVAL then
      state.dirty = true
      return
    end
    local activity = buildActivity()
    local key = activityKey(activity)
    if not force and key == state.lastSentKey then
      state.dirty = false
      return
    end
    local payload = Json.encode({
      cmd = "SET_ACTIVITY",
      args = {
        pid = resolvePid(),
        activity = activity,
      },
      nonce = nonce(),
    })
    if not sendFrame(OP_FRAME, payload) then
      closeSocket()
      state.nextReconnectAt = now + RECONNECT_INTERVAL
      return
    end
    state.lastSentKey = key
    state.lastSendAt = now
    state.dirty = false
  end)
  if not ok then
    closeSocket()
    local now = love and love.timer and love.timer.getTime and love.timer.getTime() or 0
    state.nextReconnectAt = now + RECONNECT_INTERVAL
  end
end

local function setPresence(fields)
  -- event listeners must never throw into the overworld/battle path
  pcall(function()
    if fields.location ~= nil then state.location = fields.location end
    if fields.mapId ~= nil then state.mapId = fields.mapId end
    if fields.activity ~= nil then state.activity = fields.activity end
    if fields.clearBattle then
      state.battleLabel = nil
    elseif fields.battleLabel ~= nil then
      state.battleLabel = fields.battleLabel
    end
    state.dirty = true
    flush(false)
  end)
end

local function subscribe(game)
  local events = Runtime.events
  if not events or not events.on then return end

  local function track(name, fn)
    state.unsubs[#state.unsubs + 1] = events:on(name, fn, 0, "discord")
  end

  track("map.entered", function(ev)
    local mapId = ev and ev.mapId
    setPresence({
      mapId = mapId,
      location = locationName(game, mapId),
      activity = "exploring",
      clearBattle = true,
    })
  end)

  track("battle.started", function(ev)
    local battle = ev and ev.battle
    local label = "In battle"
    if ev and ev.kind == "wild" then
      local name = speciesName(game, ev.species)
      if name then
        label = "Battling wild " .. name
        if ev.level then label = label .. " Lv" .. tostring(ev.level) end
      else
        label = "Wild battle"
      end
    elseif ev and ev.kind == "trainer" then
      local tname = battle and battle.trainer and battle.trainer.name
      label = tname and ("Battling " .. tname) or "Trainer battle"
    elseif ev and ev.kind == "link" then
      label = "Link battle"
    end
    local mapId = state.mapId
      or (game.save and game.save.player and game.save.player.map)
    setPresence({
      activity = "battle",
      battleLabel = label,
      location = locationName(game, mapId) or state.location,
      mapId = mapId,
    })
  end)

  track("battle.ended", function()
    local mapId = state.mapId
      or (game.save and game.save.player and game.save.player.map)
    setPresence({
      activity = mapId and "exploring" or "menu",
      clearBattle = true,
      location = locationName(game, mapId) or state.location,
      mapId = mapId,
    })
  end)

  track("screen.pushed", function(ev)
    local s = ev and ev.state
    local id = s and s.screenId
    if not id and s and s.onNewGame then id = "TitleState" end
    if id == "TitleState" or id == "IntroMovie" then
      state.mapId = nil
      setPresence({
        activity = "menu",
        location = id == "IntroMovie" and "Watching the intro" or "Title screen",
        clearBattle = true,
      })
    end
  end)
end

function DiscordPresence.init(game)
  local ok, err = pcall(function()
    DiscordPresence.shutdown()
    if disabledByEnv() or not isDesktop() then return end

    state.enabled = true
    state.isWindows = love.system.getOS() == "Windows"
    state.startedAt = os.time()
    state.activity = "menu"
    state.location = "Title screen"
    state.mapId = nil
    state.battleLabel = nil
    state.dirty = true
    state.nextReconnectAt = 0
    state.loggedAbsent = false

    if not state.isWindows and not ensureFfi() then
      -- no FFI / broken cdef: stay disabled, never throw
      state.enabled = false
      return
    end

    subscribe(game)
    if connect() then
      flush(true)
    else
      noteAbsent()
      local now = (love.timer and love.timer.getTime and love.timer.getTime()) or 0
      state.nextReconnectAt = now + RECONNECT_INTERVAL
    end
  end)
  if not ok then
    closeSocket()
    state.enabled = false
    -- still soft: a broken presence stack must not abort boot
    Logger.info("discord: rich presence disabled (%s)", tostring(err))
  end
end

function DiscordPresence.update(_dt)
  if not state.enabled then return end
  pcall(function()
    local now = love.timer.getTime()
    if not state.connected then
      if now >= state.nextReconnectAt then
        state.nextReconnectAt = now + RECONNECT_INTERVAL
        if connect() then
          flush(true)
        else
          noteAbsent()
        end
      end
      return
    end
    if state.dirty then flush(false) end
  end)
end

function DiscordPresence.shutdown()
  pcall(function()
    for _, unsub in ipairs(state.unsubs) do
      pcall(unsub)
    end
    state.unsubs = {}
    if state.connected then
      pcall(function()
        -- omit activity to clear the presence
        sendFrame(OP_FRAME, Json.encode({
          cmd = "SET_ACTIVITY",
          args = { pid = resolvePid() },
          nonce = nonce(),
        }))
        sendFrame(OP_CLOSE, "{}")
      end)
    end
    closeSocket()
  end)
  state.enabled = false
  state.dirty = false
  state.lastSentKey = nil
  state.connected = false
  state.socket = nil
end

-- test / debug helpers
DiscordPresence._state = state
DiscordPresence.locationName = locationName

return DiscordPresence
