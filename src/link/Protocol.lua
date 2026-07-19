-- Link protocol helpers: Pokémon serialization and the trade session
-- state machine (pure logic, headless-testable).
--
-- Message types exchanged after pairing:
--   {type="hello", ...}                 handshake v2 (src/link/Handshake.lua)
--   {type="records", pokemon=, moves=}  subset trade: per-record hashes
--   {type="party", mons=[...]}          party (both directions)
--   {type="pick", index}                trade: chosen slot in the sent list
--   {type="confirm", ok=bool}           trade: final yes/no
--   {type="action", ...}                battle: guest -> host choice
--   {type="event", ...}                 battle: host -> guest display event
--   {type="bye"}

local Fingerprint = require("src.link.Fingerprint")
local Handshake = require("src.link.Handshake")
local Runtime = require("src.mods.Runtime")

local Protocol = {}

Protocol.hello = Handshake.hello
Protocol.checkCompat = Handshake.checkCompat

-- the extra bag is JSON-safe by contract, the same restriction the save
-- serializer enforces; anything else is dropped rather than trusted
local function plainCopy(value, depth)
  if type(value) ~= "table" then return nil end
  if (depth or 0) > 8 then return nil end
  local out = {}
  for k, v in pairs(value) do
    local kt, vt = type(k), type(v)
    if kt == "string" or kt == "number" then
      if vt == "string" or vt == "number" or vt == "boolean" then
        out[k] = v
      elseif vt == "table" then
        out[k] = plainCopy(v, (depth or 0) + 1)
      end
    end
  end
  return out
end

Protocol.plainCopy = plainCopy

-- serialize a mon instance for the wire (plain data only).  ppUps rides
-- along because the real cable transmitted it and its absence silently
-- capped a PP-Upped move at base PP on the receiving side.
function Protocol.packMon(mon)
  local moves = {}
  for _, mv in ipairs(mon.moves) do
    table.insert(moves, { id = mv.id, pp = mv.pp, ppUps = mv.ppUps })
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
    extra = plainCopy(mon.extra),
  }
end

-- rebuild a mon locally (recomputes stats from real species data so a
-- tampered packet can't invent stats).  opts.strict is set once two v2
-- peers have agreed on a verdict: a mon that cannot be rebuilt identically
-- is rejected by name instead of quietly mutated into something else.
function Protocol.unpackMon(data, packed, opts)
  local Stats = require("src.pokemon.Stats")
  local Growth = require("src.pokemon.Growth")
  local strict = opts and opts.strict
  local def = data.pokemon[packed.species]
  if not def then
    if strict then return nil, "unknown POKéMON" end
    return nil
  end
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
    local mdef = data.moves[mv.id]
    if mdef and #moves < 4 then
      local ppUps = math.max(0, math.min(3, math.floor(mv.ppUps or 0)))
      local maxPP = mdef.pp + ppUps * math.floor(mdef.pp / 5)
      local entry = { id = mv.id,
                      pp = math.max(0, math.min(maxPP, math.floor(mv.pp or 0))) }
      if mv.ppUps ~= nil then entry.ppUps = ppUps end
      table.insert(moves, entry)
    end
  end
  if #moves == 0 then
    -- the v1 path keeps the substitute verbatim for peers built against it;
    -- a negotiated v2 link says so out loud instead
    if strict then return nil, "no shared moves" end
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
    -- a namespace whose mod this install lacks survives untouched, so the
    -- mon keeps it for the trip home
    extra = plainCopy(packed.extra),
  }
end

function Protocol.packParty(party, indices)
  local mons = {}
  if indices then
    for _, i in ipairs(indices) do
      table.insert(mons, Protocol.packMon(party[i]))
    end
    return mons
  end
  for _, mon in ipairs(party) do
    table.insert(mons, Protocol.packMon(mon))
  end
  return mons
end

-- ------- subset negotiation

-- the species and moves this party actually references, so the exchange
-- stays small (six mons) instead of shipping the whole catalog
function Protocol.recordsMessage(data, party)
  local species = Fingerprint.records(data, "pokemon")
  local moves = Fingerprint.records(data, "moves")
  local outSpecies, outMoves = {}, {}
  for _, mon in ipairs(party or {}) do
    if species[mon.species] then outSpecies[mon.species] = species[mon.species] end
    for _, mv in ipairs(mon.moves or {}) do
      if moves[mv.id] then outMoves[mv.id] = moves[mv.id] end
    end
  end
  return { type = "records", pokemon = outSpecies, moves = outMoves }
end

-- a mon may cross the wire only if both peers rebuild it identically: the
-- species and every move id has to exist on the other game with the same
-- record hash.  Filtering is symmetric, so the two sides always agree on
-- which slots are in play and a pick can never land on a different mon.
function Protocol.eligibleParty(party, myRecords, theirRecords)
  local eligible, reasons = {}, {}
  theirRecords = theirRecords or {}
  local theirSpecies = theirRecords.pokemon or {}
  local theirMoves = theirRecords.moves or {}
  local mySpecies = (myRecords or {}).pokemon or {}
  local myMoves = (myRecords or {}).moves or {}
  for i, mon in ipairs(party or {}) do
    local reason
    if not theirSpecies[mon.species] then
      reason = "not on the other game"
    elseif theirSpecies[mon.species] ~= mySpecies[mon.species] then
      reason = "different data"
    else
      for _, mv in ipairs(mon.moves or {}) do
        if not theirMoves[mv.id] then
          reason = "unknown move"
          break
        elseif theirMoves[mv.id] ~= myMoves[mv.id] then
          reason = "different move data"
          break
        end
      end
    end
    eligible[i] = reason == nil
    reasons[i] = reason
  end
  return eligible, reasons
end

-- -------------------------------------------------------------------
-- Trade session: symmetric state machine.  Feed it messages; read
-- .stage ("waitRecords" -> "waitParty" -> "picking" -> "waitPick" ->
-- "confirming" -> "done"/"cancelled").  When done, .result =
-- {give=idx, getMon=mon}.  A subset session negotiates the eligible
-- slots first, so both sides send and index the same filtered list.
-- -------------------------------------------------------------------

local TradeSession = {}
TradeSession.__index = TradeSession
Protocol.TradeSession = TradeSession

-- opts: { subset, strict, peerName } -- all absent on the v1 path
function TradeSession.new(data, party, opts)
  opts = opts or {}
  local self = setmetatable({
    data = data,
    party = party,
    subset = opts.subset or false,
    strict = opts.strict or false,
    peerName = opts.peerName,
    stage = opts.subset and "waitRecords" or "waitParty",
    sendIndices = nil,
    eligible = nil,
    reasons = {},
    theirParty = nil,
    myPick = nil,
    theirPick = nil,
    myConfirm = nil,
    theirConfirm = nil,
  }, TradeSession)
  if not self.subset then
    local all = {}
    for i = 1, #party do all[i] = i end
    self.sendIndices = all
  end
  return self
end

-- the first message on the wire: a subset trade has to agree on which mons
-- both games rebuild identically before either party can be sent
function TradeSession:opening()
  if self.subset then
    return Protocol.recordsMessage(self.data, self.party)
  end
  return self:partyMessage()
end

function TradeSession:partyMessage()
  return { type = "party",
           mons = Protocol.packParty(self.party, self.sendIndices) }
end

function TradeSession:_negotiate(theirRecords)
  local mine = { pokemon = Fingerprint.records(self.data, "pokemon"),
                 moves = Fingerprint.records(self.data, "moves") }
  self.eligible, self.reasons =
    Protocol.eligibleParty(self.party, mine, theirRecords)
  local indices = {}
  for i = 1, #self.party do
    if self.eligible[i] then indices[#indices + 1] = i end
  end
  self.sendIndices = indices
end

-- the UI greys what the other game would rebuild differently
function TradeSession:canPick(index)
  return self.eligible == nil or self.eligible[index] == true
end

-- returns a message to put on the wire, or nil
function TradeSession:handle(msg)
  if msg.type == "records" then
    -- only once: re-filtering after our party went out would slide the
    -- indices the peer is already holding
    if self.stage ~= "waitRecords" then return nil end
    self:_negotiate(msg)
    self.stage = "waitParty"
    return self:partyMessage()
  elseif msg.type == "party" then
    self.theirParty = {}
    for _, packed in ipairs(msg.mons or {}) do
      local mon, why = Protocol.unpackMon(self.data, packed,
                                          { strict = self.strict })
      if mon then
        table.insert(self.theirParty, mon)
      elseif self.strict then
        -- dropping a row would slide every later index by one and the
        -- two sides would commit different mons; refuse the whole trade
        self.stage = "cancelled"
        self.error = why or "the other game sent an unknown POKéMON"
        return nil
      end
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
  return nil
end

-- index is a real party slot; the wire carries its position in the list
-- this side actually sent, which is the only space both peers share
function TradeSession:wireIndex(index)
  for pos, i in ipairs(self.sendIndices or {}) do
    if i == index then return pos end
  end
  return index
end

function TradeSession:pick(index)
  self.myPick = index
  self:advance()
  return { type = "pick", index = self:wireIndex(index) }
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
  local sent = self.party[self.myPick]
  received.traded = true -- boosted exp (different OT)
  -- a mod validates its own extra namespace here, before the mon is filed
  Runtime.emit("pokemon.received",
               { mon = received, from = "link", peerName = self.peerName })
  self.party[self.myPick] = received
  if game and game.save.pokedex then
    game.save.pokedex.seen[received.species] = true
    game.save.pokedex.owned[received.species] = true
  end
  local def = self.data.pokemon[received.species]
  local evolveTo
  for _, evo in ipairs(def.evolutions or {}) do
    if evo.method == "TRADE" then
      evolveTo = evo.species
      break
    end
  end
  Runtime.emit("trade.completed",
               { sent = sent, received = received, evolveTo = evolveTo })
  return received, evolveTo
end

return Protocol
