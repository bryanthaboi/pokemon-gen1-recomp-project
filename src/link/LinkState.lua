-- Link play UI: one player hosts (the screen shows their LAN address),
-- the other joins by typing that address in.  Direct peer-to-peer over
-- lua-enet (bundled with LÖVE),  no relay server.

local Font = require("src.render.Font")
local Net = require("src.link.Net")
local Protocol = require("src.link.Protocol")
local TextBox = require("src.render.TextBox")

local LinkState = {}
LinkState.__index = LinkState
LinkState.isOpaque = true

local CURSOR = 0xED

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

function LinkState:exitWith(message)
  if self.net then self.net:close() end
  self.game.stack:pop()
  if message then
    self.game.stack:push(TextBox.new(self.game, message))
  end
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
       and self.stage ~= "battleRunning" then
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
    end

  elseif self.stage == "modeSelect" then -- host picks
    if input:wasPressed("up") or input:wasPressed("down") then
      self.index = self.index == 1 and 2 or 1
    elseif input:wasPressed("a") then
      local mode = self.index == 1 and "trade" or "battle"
      self.net:send({ type = "hello", name = self.game.save.player.name, mode = mode })
      self:startMode(mode, true)
    elseif input:wasPressed("b") then
      self:exitWith(nil)
    end

  elseif self.stage == "waitMode" then -- guest waits for host's pick
    if input:wasPressed("b") then self:exitWith(nil) return end
    local msgs = self.net:poll()
    for i, msg in ipairs(msgs) do
      if msg.type == "hello" then
        self.peerName = msg.name
        self:startMode(msg.mode, false)
        -- the host's next messages (party, ...) can share this batch;
        -- put them back so the new stage's poll sees them
        for j = #msgs, i + 1, -1 do
          table.insert(self.net.inbox, 1, msgs[j])
        end
        break
      end
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
        }
        if self.isHost then
          self.game.stack:push(LinkBattle.newHost(self.game, self.net, opts))
        else
          self.game.stack:push(LinkBattle.newGuest(self.game, self.net, opts))
        end
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
    self.trade = Protocol.TradeSession.new(self.game.data, self.game.save.party)
    self.net:send({ type = "party", mons = Protocol.packParty(self.game.save.party) })
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
    self.trade:handle(msg)
  end
  local t = self.trade

  if t.stage == "cancelled" then
    self:exitWith("The trade was\ncancelled.")
    return
  end
  if t.stage == "done" then
    local sent = t.party[t.myPick]
    local received, evoTo = t:apply(self.game)
    local name = received.nickname or self.game.data.pokemon[received.species].name
    self.net:close()
    self.game.stack:pop()
    local game = self.game
    require("src.core.Sound").play(game.data, "Trade_Machine")
    local TradeAnim = require("src.ui.TradeAnim")
    game.stack:push(TradeAnim.new(game, {
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
    }))
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
    self.net:send(t:pick(self.index))
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

  elseif self.stage == "waitMode" then
    drawTitle("CONNECTED!")
    Font.draw("Waiting for the", 16, 56)
    Font.draw("host to choose...", 16, 72)

  elseif self.stage == "trade" then
    drawTitle("TRADE")
    local t = self.trade
    Font.draw("YOURS", 8, 20)
    for i, mon in ipairs(self.game.save.party) do
      local def = self.game.data.pokemon[mon.species]
      Font.draw((mon.nickname or def.name):sub(1, 8), 16, 20 + i * 12)
      if i == self.index then Font.drawCode(CURSOR, 8, 20 + i * 12) end
    end
    Font.draw("THEIRS", 84, 20)
    for i, mon in ipairs(t.theirParty or {}) do
      local def = self.game.data.pokemon[mon.species]
      Font.draw((mon.nickname or def.name):sub(1, 8), 92, 20 + i * 12)
      if t.theirPick == i then Font.drawCode(CURSOR, 84, 20 + i * 12) end
    end
    local hint
    if t.stage == "waitParty" then hint = "Exchanging data..."
    elseif t.stage == "picking" then hint = "Pick one to trade"
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
