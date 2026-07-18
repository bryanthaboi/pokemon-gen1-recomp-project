-- Link protocol helpers: Pokémon serialization and the trade session
-- state machine (pure logic, headless-testable).
--
-- Message types exchanged after pairing:
--   {type="hello", name, mode}          host announces trade|battle
--   {type="party", mons=[...]}          full party (both directions)
--   {type="pick", index}                trade: chosen party slot
--   {type="confirm", ok=bool}           trade: final yes/no
--   {type="action", ...}                battle: guest -> host choice
--   {type="event", ...}                 battle: host -> guest display event
--   {type="bye"}

local Protocol = {}

-- serialize a mon instance for the wire (plain data only)
function Protocol.packMon(mon)
  local moves = {}
  for _, mv in ipairs(mon.moves) do
    table.insert(moves, { id = mv.id, pp = mv.pp })
  end
  return {
    species = mon.species,
    level = mon.level,
    exp = mon.exp,
    hp = mon.hp,
    status = mon.status,
    nickname = mon.nickname,
    dvs = mon.dvs,
    statExp = mon.statExp,
    moves = moves,
  }
end

-- rebuild a mon locally (recomputes stats from real species data so a
-- tampered packet can't invent stats)
function Protocol.unpackMon(data, packed)
  local Stats = require("src.pokemon.Stats")
  local Growth = require("src.pokemon.Growth")
  local def = data.pokemon[packed.species]
  if not def then return nil end
  local level = math.max(2, math.min(100, math.floor(packed.level or 5)))
  local dvs = {}
  for _, k in ipairs({ "hp", "attack", "defense", "speed", "special" }) do
    dvs[k] = math.max(0, math.min(15, math.floor((packed.dvs or {})[k] or 0)))
  end
  local statExp = {}
  for _, k in ipairs({ "hp", "attack", "defense", "speed", "special" }) do
    statExp[k] = math.max(0, math.min(65535, math.floor((packed.statExp or {})[k] or 0)))
  end
  local stats = Stats.calc(def, level, dvs, statExp)
  local moves = {}
  for _, mv in ipairs(packed.moves or {}) do
    if data.moves[mv.id] and #moves < 4 then
      table.insert(moves, {
        id = mv.id,
        pp = math.max(0, math.min(data.moves[mv.id].pp, math.floor(mv.pp or 0))),
      })
    end
  end
  if #moves == 0 then
    moves = { { id = "TACKLE", pp = 35 } }
  end
  return {
    species = packed.species,
    level = level,
    exp = math.max(0, math.floor(packed.exp or Growth.expForLevel(def.growthRate, level))),
    dvs = dvs,
    statExp = statExp,
    stats = stats,
    hp = math.max(0, math.min(stats.hp, math.floor(packed.hp or stats.hp))),
    status = packed.status,
    nickname = packed.nickname,
    moves = moves,
  }
end

function Protocol.packParty(party)
  local mons = {}
  for _, mon in ipairs(party) do
    table.insert(mons, Protocol.packMon(mon))
  end
  return mons
end

-- -------------------------------------------------------------------
-- Trade session: symmetric state machine.  Feed it messages; read
-- .stage ("waitParty" -> "picking" -> "waitPick" -> "confirming" ->
-- "done"/"cancelled").  When done, .result = {give=idx, getMon=mon}.
-- -------------------------------------------------------------------

local TradeSession = {}
TradeSession.__index = TradeSession
Protocol.TradeSession = TradeSession

function TradeSession.new(data, party)
  return setmetatable({
    data = data,
    party = party,
    stage = "waitParty",
    theirParty = nil,
    myPick = nil,
    theirPick = nil,
    myConfirm = nil,
    theirConfirm = nil,
  }, TradeSession)
end

function TradeSession:handle(msg)
  if msg.type == "party" then
    self.theirParty = {}
    for _, packed in ipairs(msg.mons or {}) do
      local mon = Protocol.unpackMon(self.data, packed)
      if mon then table.insert(self.theirParty, mon) end
    end
    if self.stage == "waitParty" then self.stage = "picking" end
  elseif msg.type == "pick" then
    self.theirPick = msg.index
    self:advance()
  elseif msg.type == "confirm" then
    self.theirConfirm = msg.ok
    self:advance()
  elseif msg.type == "bye" then
    self.stage = "cancelled"
  end
end

function TradeSession:pick(index)
  self.myPick = index
  self:advance()
  return { type = "pick", index = index }
end

function TradeSession:confirm(ok)
  self.myConfirm = ok
  self:advance()
  return { type = "confirm", ok = ok }
end

function TradeSession:advance()
  if self.stage == "picking" and self.myPick then
    self.stage = self.theirPick and "confirming" or "waitPick"
  elseif self.stage == "waitPick" and self.theirPick then
    self.stage = "confirming"
  end
  if self.stage == "confirming" and self.myConfirm ~= nil and self.theirConfirm ~= nil then
    if self.myConfirm and self.theirConfirm then
      self.stage = "done"
    else
      self.stage = "cancelled"
    end
  end
end

-- apply the completed trade to the local party; returns the new mon
-- (trade evolutions like Kadabra -> Alakazam trigger on the receiving
-- side, as on a real link cable)
function TradeSession:apply(game)
  assert(self.stage == "done", "trade not complete")
  local received = self.theirParty[self.theirPick]
  received.traded = true -- boosted exp (different OT)
  self.party[self.myPick] = received
  if game and game.save.pokedex then
    game.save.pokedex.seen[received.species] = true
    game.save.pokedex.owned[received.species] = true
  end
  local def = self.data.pokemon[received.species]
  for _, evo in ipairs(def.evolutions or {}) do
    if evo.method == "TRADE" then
      return received, evo.species
    end
  end
  return received, nil
end

return Protocol
