-- Link play UI: one player hosts (the screen shows their LAN address),
-- the other joins by typing that address in.  Direct peer-to-peer over
-- lua-enet (bundled with LÖVE),  no relay server.

local Font = require("src.render.Font")
local Handshake = require("src.link.Handshake")
local Net = require("src.link.Net")
local Protocol = require("src.link.Protocol")
local Runtime = require("src.mods.Runtime")
local Screens = require("src.ui.Screens")
local TextBox = require("src.render.TextBox")

local LinkState = {}
LinkState.__index = LinkState
LinkState.isOpaque = true

local CURSOR = 0xED

-- how long the host waits for a v2 hello before deciding the peer predates
-- the handshake (a pre-mod guest sends nothing until it hears the mode)
local HELLO_GRACE = 2

-- the joiner edits an IPv4 address as 12 digits (three per octet),
-- prefilled with our own LAN IP so usually only the tail needs changing
local function ipDigits(ip)
  local digits = {}
  local a, b, c, d = (ip or ""):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  local octets = { tonumber(a) or 192, tonumber(b) or 168,
                   tonumber(c) or 0, tonumber(d) or 1 }
  for _, o in ipairs(octets) do
    o = math.min(255, o)
    table.insert(digits, math.floor(o / 100))
    table.insert(digits, math.floor(o / 10) % 10)
    table.insert(digits, o % 10)
  end
  return digits
end

function LinkState.new(game)
  local self = setmetatable({}, LinkState)
  self.game = game
  self.stage = "menu"
  self.index = 1
  self.addr = ipDigits(Net.lanIP())
  self.addrPos = 12 -- the last octet is what usually differs
  self.status = ""
  return self
end

function LinkState:exitWith(message, reason)
  Runtime.emit("link.ended", { reason = reason or (message and "error" or "bye") })
  if self.net then self.net:close() end
  self.game.stack:pop()
  if message then
    self.game.stack:push(TextBox.new(self.game, message))
  end
end

-- -------------------------------------------------------------------
-- handshake v2 (D8): both peers announce engine version, api version and
-- a fingerprint of their link surface, and the verdict comes from the two
-- hellos rather than from whoever picked the mode.  The guest announces
-- itself the moment it pairs; the host's hello still carries the mode, so
-- a pre-mod build reads it exactly as it always did.
-- -------------------------------------------------------------------

-- take the peer's hello out of the inbox without eating anything that
-- shares the batch with it
function LinkState:pollHello()
  local msgs = self.net:poll()
  local keep, got = {}, false
  for _, msg in ipairs(msgs) do
    if msg.type == "hello" and not self.peerHello then
      self.peerHello = msg
      self.peerName = msg.name
      got = true
    else
      keep[#keep + 1] = msg
    end
  end
  for i = #keep, 1, -1 do
    table.insert(self.net.inbox, 1, keep[i])
  end
  return got, #keep > 0
end

function LinkState:sendHello(mode)
  self.myHello = Handshake.hello(self.game, mode)
  self.net:send(self.myHello)
end

function LinkState:decideCompat(mode, isHost)
  self.isHost = isHost
  self.pendingMode = mode
  self.myHello = self.myHello or Handshake.hello(self.game, isHost and mode or nil)
  local peer = self.peerHello
  self.verdict = Handshake.checkCompat(self.myHello, peer)
  Runtime.emit("link.connected", {
    role = isHost and "host" or "guest",
    remote = { name = peer and peer.name or self.peerName, mode = mode,
               mods = peer and peer.mods, fingerprint = peer and peer.fingerprint },
  })
  if self.verdict == "full" or self.verdict == "vanilla_peer" then
    self:startMode(mode, isHost)
    return
  end
  -- naming the difference up front is the whole point: the old behaviour
  -- was a silent draw three turns into a battle that could never work
  self.noticeLines = Handshake.describe(self.myHello, peer, self.verdict, mode)
  self.noticeExits = self.verdict == "refused" or mode ~= "trade"
  self.stage = "notice"
end

-- -------------------------------------------------------------------
-- update
-- -------------------------------------------------------------------

function LinkState:update(dt)
  local input = self.game.input
  if self.net then
    self.net:update()
    if self.net.error and self.stage ~= "menu" then
      self:exitWith("Link error:\n" .. self.net.error:sub(1, 60))
      return
    end
    -- the peer vanished without a bye (only once the inbox is drained,
    -- so a final message travelling with the disconnect still counts)
    if self.net.closed and #self.net.inbox == 0
       and self.stage ~= "menu" and self.stage ~= "addrEntry"
       and self.stage ~= "notice" and self.stage ~= "battleRunning" then
      self:exitWith("The link was\nbroken.")
      return
    end
  end

  if self.stage == "menu" then
    if input:wasPressed("up") or input:wasPressed("down") then
      self.index = self.index == 1 and 2 or 1
    elseif input:wasPressed("b") then
      self:exitWith(nil)
    elseif input:wasPressed("a") then
      self.net = Net.new()
      if self.index == 1 then
        if self.net:host() then
          self.stage = "hosting"
        else
          self:exitWith("Link error:\n" .. (self.net.error or "?"))
        end
      else
        self.stage = "addrEntry"
      end
    end

  elseif self.stage == "hosting" then
    if input:wasPressed("b") then self:exitWith(nil) return end
    if self.net.paired then
      self.stage = "modeSelect"
      self.index = 1
    end

  elseif self.stage == "addrEntry" then
    if input:wasPressed("b") then self:exitWith(nil) return end
    if input:wasPressed("up") then
      self.addr[self.addrPos] = (self.addr[self.addrPos] + 1) % 10
    elseif input:wasPressed("down") then
      self.addr[self.addrPos] = (self.addr[self.addrPos] - 1) % 10
    elseif input:wasPressed("left") then
      self.addrPos = math.max(1, self.addrPos - 1)
    elseif input:wasPressed("right") then
      self.addrPos = math.min(12, self.addrPos + 1)
    elseif input:wasPressed("a") then
      local octets = {}
      for i = 1, 4 do
        local base = (i - 1) * 3
        octets[i] = math.min(255, self.addr[base + 1] * 100
                                  + self.addr[base + 2] * 10
                                  + self.addr[base + 3])
      end
      if self.net:join(table.concat(octets, ".")) then
        self.stage = "joining"
      else
        self:exitWith("Link error:\n" .. (self.net.error or "?"))
      end
    end

  elseif self.stage == "joining" then
    if input:wasPressed("b") then self:exitWith(nil) return end
    if self.net.paired then
      self.stage = "waitMode"
      self:sendHello(nil) -- the host owns the mode; this is just who we are
    end

  elseif self.stage == "modeSelect" then -- host picks
    self:pollHello()
    if input:wasPressed("up") or input:wasPressed("down") then
      self.index = self.index == 1 and 2 or 1
    elseif input:wasPressed("a") then
      local mode = self.index == 1 and "trade" or "battle"
      self:sendHello(mode)
      if self.peerHello then
        self:decideCompat(mode, true)
      else
        self.pendingMode = mode
        self.helloWait = 0
        self.stage = "waitHello"
      end
    elseif input:wasPressed("b") then
      self:exitWith(nil)
    end

  elseif self.stage == "waitHello" then -- host waits for the peer's hello
    if input:wasPressed("b") then self:exitWith(nil) return end
    local got, other = self:pollHello()
    self.helloWait = self.helloWait + (dt or 0)
    -- a pre-mod peer never sends one: it just gets on with the mode, so
    -- its first message -- or the grace period -- is the answer
    if got or other or self.helloWait > HELLO_GRACE then
      self:decideCompat(self.pendingMode, true)
    end

  elseif self.stage == "waitMode" then -- guest waits for host's pick
    if input:wasPressed("b") then self:exitWith(nil) return end
    local msgs = self.net:poll()
    for i, msg in ipairs(msgs) do
      if msg.type == "hello" then
        self.peerHello = msg
        self.peerName = msg.name
        -- the host's next messages (party, ...) can share this batch;
        -- put them back so the new stage's poll sees them
        for j = #msgs, i + 1, -1 do
          table.insert(self.net.inbox, 1, msgs[j])
        end
        self:decideCompat(msg.mode, false)
        break
      end
    end

  elseif self.stage == "notice" then
    if input:wasPressed("b") or (self.noticeExits and input:wasPressed("a")) then
      self.net:send({ type = "bye" })
      self:exitWith(nil, "error")
    elseif input:wasPressed("a") then
      self:startMode(self.pendingMode, self.isHost)
    end

  elseif self.stage == "trade" then
    self:updateTrade(input)

  elseif self.stage == "battleWait" then
    if input:wasPressed("b") then self:exitWith(nil) return end
    local msgs = self.net:poll()
    for i, msg in ipairs(msgs) do
      if msg.type == "party" then
        local LinkBattle = require("src.link.LinkBattle")
        local opts = {
          myParty = Protocol.packParty(self.game.save.party),
          theirParty = msg.mons,
          theirName = self.peerName or "FOE",
          seed = self.isHost and self.linkSeed or msg.seed,
          verdict = self.verdict,
          strict = Handshake.strict(self.verdict),
        }
        local battle, why
        if self.isHost then
          battle, why = LinkBattle.newHost(self.game, self.net, opts)
        else
          battle, why = LinkBattle.newGuest(self.game, self.net, opts)
        end
        if not battle then
          self.net:send({ type = "bye" })
          self:exitWith(why or "Link battle\ncan't start.", "error")
          return
        end
        self.game.stack:push(battle)
        self.stage = "battleRunning"
        for j = #msgs, i + 1, -1 do
          table.insert(self.net.inbox, 1, msgs[j])
        end
        break
      end
    end

  elseif self.stage == "battleRunning" then
    if self.game.stack:top() == self then
      self:exitWith(nil) -- battle finished
    end
  end
end

function LinkState:startMode(mode, isHost)
  self.isHost = isHost
  if mode == "trade" then
    self.stage = "trade"
    -- a subset session settles which mons both games rebuild identically
    -- before either party goes out, so a pick can't land on a mon the
    -- other side would reconstruct differently
    self.trade = Protocol.TradeSession.new(self.game.data, self.game.save.party, {
      subset = self.verdict == "subset",
      strict = Handshake.strict(self.verdict),
      peerName = self.peerName,
    })
    self.net:send(self.trade:opening())
    self.index = 1
  else
    self.stage = "battleWait"
    -- the host deals the shared RNG seed for the lockstep simulation
    if isHost then
      self.linkSeed = love.math.random(1, 2 ^ 30)
    end
    self.net:send({ type = "party",
                    mons = Protocol.packParty(self.game.save.party),
                    seed = self.linkSeed })
  end
end

-- -------------------------------------------------------------------
-- trade flow
-- -------------------------------------------------------------------

function LinkState:updateTrade(input)
  for _, msg in ipairs(self.net:poll()) do
    local reply = self.trade:handle(msg)
    if reply then self.net:send(reply) end
  end
  local t = self.trade

  if t.stage == "cancelled" then
    self:exitWith(t.error and ("The trade stopped:\n%s."):format(t.error)
                  or "The trade was\ncancelled.")
    return
  end
  if t.stage == "done" then
    local sent = t.party[t.myPick]
    local received, evoTo = t:apply(self.game)
    local name = received.nickname or self.game.data.pokemon[received.species].name
    Runtime.emit("link.ended", { reason = "done" })
    self.net:close()
    self.game.stack:pop()
    local game = self.game
    require("src.core.Sound").play(game.data, "Trade_Machine")
    Screens.push(game, "TradeAnim", {
      sent = sent, received = received,
      onDone = function()
        game.stack:push(TextBox.new(game,
          ("Trade completed!\f%s received\n%s!"):format(game.save.player.name, name),
          function()
            if evoTo then
              require("src.pokemon.Evolution").evolve(game, received, evoTo)
            end
          end))
      end,
    })
    return
  end

  if t.stage == "picking" and input:wasPressed("up") then
    self.index = math.max(1, self.index - 1)
  elseif t.stage == "picking" and input:wasPressed("down") then
    self.index = math.min(#self.game.save.party, self.index + 1)
  elseif self.confirmed == nil and input:wasPressed("b") then
    -- once confirm=true has been sent to the peer, backing out here
    -- would desync the two sides (the peer may already be committing
    -- the trade) -- B is dead after that, matching the A branch's own
    -- self.confirmed == nil guard
    self.net:send({ type = "bye" })
    self:exitWith("The trade was\ncancelled.")
  elseif t.stage == "picking" and input:wasPressed("a") then
    if t:canPick(self.index) then
      self.net:send(t:pick(self.index))
    end
  elseif t.stage == "confirming" and self.confirmed == nil then
    if input:wasPressed("a") then
      self.confirmed = true
      self.net:send(t:confirm(true))
    end
  end
end

-- -------------------------------------------------------------------
-- draw
-- -------------------------------------------------------------------

local function drawTitle(text)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 144)
  love.graphics.setColor(0, 0, 0, 1)
  Font.draw(text, 8, 6)
end

function LinkState:draw()
  if self.stage == "menu" then
    drawTitle("LINK CABLE CLUB")
    Font.draw("HOST A GAME", 32, 48)
    Font.draw("JOIN A GAME", 32, 68)
    Font.drawCode(CURSOR, 24, self.index == 1 and 48 or 68)
    Font.draw("UDP port " .. Net.defaultPort(), 8, 128)

  elseif self.stage == "hosting" then
    drawTitle("HOSTING")
    Font.draw("Friend joins at:", 16, 48)
    Font.draw(self.net.address or "?", 16, 64)
    Font.draw("Waiting for join...", 8, 96)

  elseif self.stage == "addrEntry" then
    drawTitle("ENTER HOST ADDRESS")
    for i = 1, 12 do
      local octet = math.floor((i - 1) / 3) -- 0..3
      local x = 16 + (i - 1) * 8 + octet * 8 -- gap for the dots
      Font.draw(tostring(self.addr[i]), x, 64)
      if i == self.addrPos then
        Font.drawCode(0xEE, x, 76) -- ▼ under the active digit
      end
    end
    for octet = 1, 3 do
      Font.draw(".", 16 + octet * 32 - 8, 64)
    end
    Font.draw("Port: " .. Net.defaultPort(), 16, 96)
    Font.draw("A: connect  B: back", 8, 128)

  elseif self.stage == "joining" then
    drawTitle("JOINING...")
    Font.draw("Calling...", 8, 56)
    Font.draw(self.net.target or "", 8, 72)

  elseif self.stage == "modeSelect" then
    drawTitle("CONNECTED!")
    Font.draw("TRADE", 32, 48)
    Font.draw("BATTLE", 32, 68)
    Font.drawCode(CURSOR, 24, self.index == 1 and 48 or 68)

  elseif self.stage == "waitMode" or self.stage == "waitHello" then
    drawTitle("CONNECTED!")
    if self.stage == "waitHello" then
      Font.draw("Checking the", 16, 56)
      Font.draw("other game...", 16, 72)
    else
      Font.draw("Waiting for the", 16, 56)
      Font.draw("host to choose...", 16, 72)
    end

  elseif self.stage == "notice" then
    drawTitle("CHECK YOUR MODS")
    for i, line in ipairs(self.noticeLines or {}) do
      if i > 8 then break end -- what fits above the prompt row
      Font.draw(line, 8, 24 + (i - 1) * 12)
    end
    Font.draw(self.noticeExits and "A: back" or "A: trade anyway", 8, 128)

  elseif self.stage == "trade" then
    drawTitle("TRADE")
    local t = self.trade
    Font.draw("YOURS", 8, 20)
    for i, mon in ipairs(self.game.save.party) do
      local def = self.game.data.pokemon[mon.species]
      local label = (mon.nickname or def.name):sub(1, 8)
      if not t:canPick(i) then label = label .. "X" end
      Font.draw(label, 16, 20 + i * 12)
      if i == self.index then Font.drawCode(CURSOR, 8, 20 + i * 12) end
    end
    Font.draw("THEIRS", 84, 20)
    for i, mon in ipairs(t.theirParty or {}) do
      local def = self.game.data.pokemon[mon.species]
      Font.draw((mon.nickname or def.name):sub(1, 8), 92, 20 + i * 12)
      if t.theirPick == i then Font.drawCode(CURSOR, 84, 20 + i * 12) end
    end
    local hint
    if t.stage == "waitRecords" then hint = "Comparing games..."
    elseif t.stage == "waitParty" then hint = "Exchanging data..."
    elseif t.stage == "picking" then
      hint = t:canPick(self.index) and "Pick one to trade"
             or "X: not on theirs"
    elseif t.stage == "waitPick" then hint = "Waiting for them..."
    elseif t.stage == "confirming" then
      hint = self.confirmed and "Waiting..." or "A: trade  B: cancel"
    end
    Font.draw(hint or "", 8, 132)

  elseif self.stage == "battleWait" or self.stage == "battleRunning" then
    drawTitle("LINK BATTLE")
    Font.draw("Exchanging data...", 16, 64)
  end
  love.graphics.setColor(1, 1, 1, 1)
end

return LinkState
