-- Peer-to-peer link transport over lua-enet (bundled with LÖVE).
-- One player hosts (binds a UDP port); the other joins by address.
-- No external server: messages are JSON objects on ENet's
-- reliable-ordered channel 0.
--
-- Usage:
--   local net = Net.new()
--   net:host()                     -- or net:join("192.168.1.20:7777")
--   every frame: net:update(); msgs = net:poll()
--   net.address                    -- host: "ip:port" to tell the friend
--   net.paired                     -- true once both ends are connected
--   net:send({ type = "hello" })
--
-- Plain luajit (headless tests) has no enet; Net.available() reports
-- that, and Net.loopbackPair() returns two in-memory ends with the
-- same API so the protocol/battle logic stays testable offline.

local Json = require("src.link.Json")
local Logger = require("src.core.Logger")

local hasEnet, enet = pcall(require, "enet")
if not hasEnet then enet = nil end

local Net = {}
Net.__index = Net

Net.DEFAULT_PORT = 7777

function Net.available()
  return enet ~= nil
end

function Net.defaultPort()
  return tonumber(os.getenv("POKEPORT_LINK_PORT") or "") or Net.DEFAULT_PORT
end

-- monotonic-ish clock for the join timeout
local function now()
  if love and love.timer and love.timer.getTime then
    return love.timer.getTime()
  end
  local ok, socket = pcall(require, "socket")
  if ok and socket and socket.gettime then return socket.gettime() end
  return os.time()
end

-- best-effort LAN IP to show the host (no packet is sent: connecting a
-- UDP socket just picks the outbound interface)
function Net.lanIP()
  local ok, ip = pcall(function()
    local socket = require("socket")
    local udp = socket.udp()
    udp:setpeername("192.0.2.1", 9) -- TEST-NET-1, never routed
    local addr = udp:getsockname()
    udp:close()
    return addr
  end)
  if ok and ip and ip ~= "0.0.0.0" then return ip end
  return nil
end

function Net.new()
  return setmetatable({
    enetHost = nil, -- our enet host object (both ends have one)
    peer = nil,     -- the connected remote peer
    inbox = {},
    outbox = {},    -- messages queued before pairing completes
    paired = false,
    address = nil,  -- host: "ip:port" the other player types in
    error = nil,
    closed = false,
    mode = nil,
    joinTimeout = 10,
  }, Net)
end

-- two in-memory ends with the Net API, for tests / offline logic
function Net.loopbackPair()
  local function make()
    local n = Net.new()
    n.paired = true
    n.mode = "loopback"
    return n
  end
  local a, b = make(), make()
  a.peerEnd, b.peerEnd = b, a
  return a, b
end

function Net:host(port)
  if not enet then
    self.error = "link needs lua-enet (run the game with LOVE)"
    return false
  end
  port = tonumber(port) or Net.defaultPort()
  local ok, h, err = pcall(enet.host_create, ("*:%d"):format(port), 2, 1)
  if not ok or not h then
    self.error = ("can't open UDP port %d (%s)"):format(
      port, tostring(ok and err or h))
    return false
  end
  self.enetHost = h
  self.mode = "hosting"
  self.address = ("%s:%d"):format(Net.lanIP() or "?", port)
  return true
end

function Net:join(address)
  if not enet then
    self.error = "link needs lua-enet (run the game with LOVE)"
    return false
  end
  local host, port = address:match("^(.-):(%d+)$")
  host = host or address
  port = tonumber(port) or Net.defaultPort()
  local target = ("%s:%d"):format(host, port)
  local ok, h = pcall(enet.host_create) -- client: no bind address
  if not ok or not h then
    self.error = "can't create network socket"
    return false
  end
  local okc, peer = pcall(h.connect, h, target, 1)
  if not okc or not peer then
    pcall(function() h:destroy() end)
    self.error = ("bad address %s"):format(target)
    return false
  end
  self.enetHost = h
  self.peer = peer
  self.mode = "joining"
  self.target = target
  self.joinDeadline = now() + self.joinTimeout
  return true
end

function Net:send(msg)
  if self.closed then return end
  if self.peerEnd then -- loopback: re-encode through json like the wire
    local decoded = Json.decode(Json.encode(msg))
    if decoded and not self.peerEnd.closed then
      table.insert(self.peerEnd.inbox, decoded)
    end
    return
  end
  if not self.paired or not self.peer then
    table.insert(self.outbox, msg) -- flushed when the connection opens
    return
  end
  local ok, err = pcall(function()
    return self.peer:send(Json.encode(msg), 0, "reliable")
  end)
  if not ok then
    self.error = "send failed: " .. tostring(err)
    self.closed = true
  end
end

-- pump enet events; decoded JSON messages are queued for poll()
function Net:update()
  if self.peerEnd then return end -- loopback needs no pumping
  if not self.enetHost or self.closed then return end
  while true do
    local ok, event = pcall(self.enetHost.service, self.enetHost, 0)
    if not ok then
      -- an unreachable join target surfaces as a service error
      -- (ICMP unreachable on the connected UDP socket)
      if self.mode == "joining" and not self.paired then
        self.error = ("no answer from\n%s"):format(self.target or "the host")
      else
        self.error = tostring(event)
      end
      self.closed = true
      return
    end
    if not event then break end
    if event.type == "connect" then
      if self.mode == "hosting" and self.peer and self.peer ~= event.peer then
        pcall(function() event.peer:disconnect_now() end) -- room is taken
      else
        self.peer = event.peer
        self.paired = true
        local queued = self.outbox
        self.outbox = {}
        for _, msg in ipairs(queued) do self:send(msg) end
      end
    elseif event.type == "receive" then
      local msg = Json.decode(event.data)
      if msg then
        table.insert(self.inbox, msg)
      else
        Logger.warn("link: bad message %q", tostring(event.data):sub(1, 60))
      end
    elseif event.type == "disconnect" then
      if event.peer == self.peer then
        self.closed = true
        if not self.paired then
          self.error = self.error or
            ("no answer from\n%s"):format(self.target or "the host")
        end
      end
    end
  end
  if self.mode == "joining" and not self.paired
     and self.joinDeadline and now() > self.joinDeadline then
    self.error = ("no answer from\n%s"):format(self.target or "the host")
    self.closed = true
    pcall(function() self.peer:disconnect_now() end)
  end
end

function Net:poll()
  local msgs = self.inbox
  self.inbox = {}
  return msgs
end

function Net:close()
  if self.peerEnd then
    self.closed = true
    return
  end
  if self.enetHost then
    if self.peer and self.paired and not self.closed then
      -- graceful goodbye: disconnect_later delivers the queued
      -- reliables (e.g. the final confirm/bye) before disconnecting;
      -- disconnect_now would drop them on both ends.  Pump briefly
      -- until the handshake completes.
      pcall(function() self.peer:disconnect_later() end)
      local deadline = now() + 0.5
      while now() < deadline do
        local ok, event = pcall(self.enetHost.service, self.enetHost, 10)
        if not ok or (event and event.type == "disconnect") then break end
      end
    elseif self.peer then
      pcall(function() self.peer:disconnect_now() end)
    end
    pcall(function() self.enetHost:flush() end)
    pcall(function() self.enetHost:destroy() end)
    self.enetHost = nil
    self.peer = nil
  end
  self.closed = true
end

return Net
