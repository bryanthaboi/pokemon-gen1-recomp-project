-- Link battles over the peer-to-peer link (src/link/Net.lua),
-- lockstep-simulated like the real link cable: BOTH sides run the
-- full battle engine (BattleState) locally
-- from mirrored perspectives, on a shared RNG seed the host deals out.
-- Each turn the two chosen actions are exchanged and both machines
-- resolve the turn independently -- identical clamped party copies +
-- identical RNG stream = identical outcomes.  A per-turn state hash is
-- exchanged; a mismatch (desync) ends the match as a draw, like a
-- cable pull.
--
-- Cable rules: no experience, no money, no items; either side may RUN
-- (a draw); a fainted mon is auto-replaced by the next healthy party
-- member (the original prompts; documented divergence).  Badge stat
-- boosts don't apply on either side (divergence: Gen 1 famously kept
-- them in link battles).

local Fingerprint = require("src.link.Fingerprint")
local Handshake = require("src.link.Handshake")
local Logger = require("src.core.Logger")
local Protocol = require("src.link.Protocol")
local Runtime = require("src.mods.Runtime")
local TurnOrder = require("src.battle.TurnOrder")

local LinkBattle = {}

-- Deterministic Park-Miller PRNG: both sides must roll identical
-- streams, so love.math.random can't be used.
local function makeRng(seed)
  local s = seed % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function(a, b)
    s = (s * 16807) % 2147483647
    if a == nil then return s / 2147483647 end
    if b == nil then a, b = 1, a end
    return a + (s % (b - a + 1))
  end
end

-- battler builder shared by both sides -- NO badge boosts, so both
-- machines compute identical stats
local function mkBattler(data, mon, isPlayer)
  local def = data.pokemon[mon.species]
  local ok, img = pcall(love.graphics.newImage,
                        isPlayer and def.spriteBack or def.spriteFront)
  return {
    mon = mon, def = def, isPlayer = isPlayer, stages = {},
    name = mon.nickname or def.name,
    curStats = mon.stats, curTypes = def.types, curMoves = mon.moves,
    sprite = ok and img or nil,
  }
end

-- canonical (host-side-first) state hash, unchanged since v1: it stays on
-- the wire as `value` so a pre-mod peer still compares something it agrees
-- with, while the components below carry the real coverage
local function stateHash(self, role)
  local function sig(b)
    return ("%s:%d:%s"):format(b.mon.species, b.mon.hp, tostring(b.mon.status))
  end
  local hostSide = role == "host" and self.player or self.enemy
  local guestSide = role == "host" and self.enemy or self.player
  return sig(hostSide) .. "|" .. sig(guestSide)
end

-- The signature is split into components so a mismatch can name what
-- diverged: species:hp:status alone missed stat stages, PP, toxic counters
-- and bench damage until they happened to move an active's HP, and the
-- match then ended in a draw that explained nothing.
local STAGES = { "attack", "defense", "special", "speed", "accuracy", "evasion" }
local VOLATILE = {
  "bideDamage", "bideTurns", "boundTurns", "chargeReady", "charging",
  "confusedTurns", "disabledSlot", "disabledTurns", "flinched", "focusEnergy",
  "invulnerable", "leechSeeded", "lightScreen", "mist", "mustRecharge",
  "rageMove", "reflect", "skipMove", "sleepTurns", "substituteHP",
  "thrashMove", "thrashTurns", "toxicCounter", "trapDamage", "trapMove",
  "trappingTurns",
}

-- move instances ride some volatile slots; only their id is comparable
local function scalar(v)
  if type(v) == "table" then return tostring(v.id or "?") end
  if type(v) == "boolean" then return v and "T" or "F" end
  return tostring(v)
end

local function stageStr(b)
  local out = {}
  for i, stat in ipairs(STAGES) do
    out[i] = tostring((b.stages or {})[stat] or 0)
  end
  return table.concat(out, ",")
end

local function ppStr(mon)
  local out = {}
  for i, mv in ipairs(mon.moves or {}) do
    out[i] = ("%s=%s"):format(tostring(mv.id), tostring(mv.pp or 0))
  end
  return table.concat(out, ",")
end

local function volStr(b)
  local out = {}
  for _, key in ipairs(VOLATILE) do
    if b[key] ~= nil then
      out[#out + 1] = key .. "=" .. scalar(b[key])
    end
  end
  return table.concat(out, ",")
end

local function activeStr(b)
  return ("%s:%d:%s:%s:%s"):format(b.mon.species, b.mon.hp,
                                   tostring(b.mon.status), stageStr(b),
                                   ppStr(b.mon))
end

local function benchStr(party)
  local out = {}
  for i, mon in ipairs(party or {}) do
    out[i] = ("%s:%d:%s"):format(tostring(mon.species), mon.hp or 0,
                                 tostring(mon.status))
  end
  return table.concat(out, "|")
end

-- canonical (host-side-first) per-component signature for desync detection
local function stateSig(self, role, myParty, theirParty)
  local host = role == "host" and self.player or self.enemy
  local guest = role == "host" and self.enemy or self.player
  local hostParty = role == "host" and myParty or theirParty
  local guestParty = role == "host" and theirParty or myParty
  return {
    actives = Fingerprint.digest(activeStr(host) .. "|" .. activeStr(guest)),
    volatile = Fingerprint.digest(volStr(host) .. "|" .. volStr(guest)),
    bench = Fingerprint.digest(benchStr(hostParty) .. "|" .. benchStr(guestParty)),
  }
end

local PARTS = { "actives", "volatile", "bench" }

-- opts: { myParty = packed, theirParty = packed, theirName, role =
-- "host"/"guest", seed, verdict, strict }.  Returns nil plus a reason when
-- the handshake says the two link surfaces don't match: a lockstep
-- simulation of two different rulebooks can only end in a bogus draw.
function LinkBattle.new(game, net, opts)
  local BattleState = require("src.battle.BattleState")
  local role = opts.role
  local theirName = opts.theirName or "FOE"

  if not Handshake.battleAllowed(opts.verdict) then
    return nil, "Link battle needs\nthe same mods on\nboth games."
  end

  -- both parties pass through the same pack->unpack clamp on both
  -- machines, so the copies are identical everywhere
  local unpackOpts = { strict = opts.strict or false }
  local myParty, theirParty = {}, {}
  for _, p in ipairs(opts.myParty or {}) do
    local mon = Protocol.unpackMon(game.data, p, unpackOpts)
    if mon then
      table.insert(myParty, mon)
    elseif unpackOpts.strict then
      return nil, ("Your %s can't\nbattle on the\nother game."):format(
        tostring(p.species))
    end
  end
  for _, p in ipairs(opts.theirParty or {}) do
    local mon, why = Protocol.unpackMon(game.data, p, unpackOpts)
    if mon then
      table.insert(theirParty, mon)
    elseif unpackOpts.strict then
      return nil, ("Their %s isn't\nin this game.\n(%s)"):format(
        tostring(p.species), tostring(why))
    end
  end
  if #myParty == 0 or #theirParty == 0 then
    Logger.warn("link: empty party on one side")
  end

  -- a mod validates its own extra namespace here, the same site the trade
  -- path gets in TradeSession:apply, before anything simulates with it.
  -- Both parties go through it on both machines and in the canonical
  -- host-first order: a validator that strips a field from one side only,
  -- or in a different order, leaves the two simulations holding different
  -- mons and desyncs on the first turn the difference matters.
  local function announceReceived(party)
    for _, mon in ipairs(party) do
      Runtime.emit("pokemon.received",
                   { mon = mon, from = "link", peerName = theirName })
    end
  end
  announceReceived(role == "host" and myParty or theirParty)
  announceReceived(role == "host" and theirParty or myParty)

  -- build on a wild battle and reshape it into the lockstep link battle.
  -- The RATTATA scaffold is unreachable on the negotiated path: an empty or
  -- unrebuildable party is refused above, so it only ever covers a caller
  -- that skipped the handshake.
  local self = BattleState.newWild(game, theirParty[1] and theirParty[1].species
                                         or "RATTATA", 5)
  self.kind = "link"
  self.linkRole = role
  self.net = net
  -- BattleState:update only runs while it's the top of the state
  -- stack, but the player can push PartyMenu/ChoiceBox/NamingScreen on
  -- top of it (forced switch on faint, evolution naming...); the ENet
  -- transport must stay serviced regardless, or the peer's actions
  -- back up and the link can stall or time out. Game:step services
  -- game.linkNet unconditionally every frame.
  game.linkNet = net
  self.rng = makeRng(opts.seed or 1)
  self.player = mkBattler(game.data, myParty[1], true)
  self.enemy = mkBattler(game.data, theirParty[1], false)
  self.enemyParty = theirParty
  self.introText = ("%s wants\nto battle!"):format(theirName)
  self.remoteHashes = {}
  self.localHashes = {}
  self.remoteParts = {}
  self.localParts = {}
  self.checkedTurns = {}

  local send = function(msg) net:send(msg) end

  local function endAsDraw(s, text)
    if s.linkEnded then return end
    s.result = "draw"
    s.afterQueue = "finish"
    s.phase = "messages"
    if text then s:say(text) end
  end

  local function orderMove(action)
    if action and action.id then return game.data.moves[action.id] end
    return nil
  end

  -- decode a remote action message against the enemy battler
  local function decodeTheirAction(s, msg)
    if msg.kind == "move" then
      local slot = math.max(1, math.min(#s.enemy.curMoves, math.floor(msg.slot or 1)))
      return s.enemy.curMoves[slot]
    elseif msg.kind == "struggle" then
      return { id = "STRUGGLE", pp = 1, struggle = true }
    elseif msg.kind == "locked" then
      return s:lockedAction(s.enemy)
    end
    return nil
  end

  -- with the handshake guaranteeing both games share a link surface, a
  -- mismatch here is RNG non-determinism -- almost always a mod rolling
  -- love.math.random inside battle logic instead of the injected s.rng
  local function reportDesync(s, turn, component, localH, remoteH)
    Logger.warn("link: desync turn %s component=%s (%s vs %s)",
                tostring(turn), component, tostring(localH), tostring(remoteH))
    Runtime.emit("link.desync", { turn = turn, component = component,
                                  localHash = localH, remoteHash = remoteH })
    endAsDraw(s, ("Link desync!\n%s differs.\fAre both games\nrunning the same\nmods?")
                 :format(component))
  end

  -- a verified turn stays recorded: consuming it here left a finished
  -- battle holding 0-1 entries, so the whole-battle sweep the link suite
  -- runs over localHashes had nothing left to compare
  local function checkHashes(s)
    for turn, localH in pairs(s.localHashes) do
      local remoteH = s.remoteHashes[turn]
      if remoteH and not s.checkedTurns[turn] then
        s.checkedTurns[turn] = true
        local mine, theirs = s.localParts[turn], s.remoteParts[turn]
        if mine and theirs then
          for _, component in ipairs(PARTS) do
            if mine[component] ~= theirs[component] then
              reportDesync(s, turn, component, mine[component], theirs[component])
              return
            end
          end
        end
        -- a v1 peer sends the combined value only
        if remoteH ~= localH then
          reportDesync(s, turn, "state", localH, remoteH)
          return
        end
      end
    end
  end

  -- both actions in hand: resolve the turn identically on both machines
  local function resolveLockstep(s, myMsg, theirMsg)
    if myMsg.kind == "run" or theirMsg.kind == "run" then
      local who = myMsg.kind == "run" and game.save.player.name or theirName
      endAsDraw(s, ("%s ran from\nthe battle!"):format(who))
      return
    end
    s.phase = "messages"
    s.afterQueue = "linkNext"
    s.turnCount = (s.turnCount or 0) + 1

    local myAction = myMsg.action
    local theirSwitch = theirMsg.kind == "switch"
                        and math.max(1, math.min(#theirParty,
                                                 math.floor(theirMsg.index or 1)))
                        or nil

    -- switches happen before attacks (both may switch)
    if myMsg.kind == "switch" then
      local idx = myMsg.index
      s:act(function()
        s.player = mkBattler(game.data, myParty[idx], true)
        s:sayNext(("Go! %s!"):format(s.player.name))
      end)
      myAction = nil
    end
    if theirSwitch then
      s:act(function()
        s.enemy = mkBattler(game.data, theirParty[theirSwitch], false)
        s:sayNext(("%s sent\nout %s!"):format(theirName, s.enemy.name))
      end)
    end

    s:act(function()
      local theirAction = decodeTheirAction(s, theirMsg)
      Runtime.emit("battle.turn_started", {
        battle = s, turn = s.turnCount,
        playerAction = myAction, enemyAction = theirAction,
      })
      if myAction and theirAction then
        -- the tie-break roll is shared: the guest inverts it so both
        -- machines agree on who goes first.  A modded ordering rule has
        -- to run here too, or the two peers order the turn differently.
        local first
        local myMove, theirMove = orderMove(myAction), orderMove(theirAction)
        if Runtime.wantsHook("battle.turn_order") then
          first = Runtime.call("battle.turn_order", function(a, aMove, b, bMove, c)
            return TurnOrder.firstMover(a, aMove, b, bMove, c.rng, c.invertTie)
          end, s.player, myMove, s.enemy, theirMove,
             { rng = s.rng, invertTie = role == "guest" })
        else
          first = TurnOrder.firstMover(s.player, myMove, s.enemy, theirMove,
                                       s.rng, role == "guest")
        end
        local order
        if first then
          order = { { s.player, s.enemy, myAction },
                    { s.enemy, s.player, theirAction } }
        else
          order = { { s.enemy, s.player, theirAction },
                    { s.player, s.enemy, myAction } }
        end
        for _, entry in ipairs(order) do
          s:act(function() s:executeAction(entry[1], entry[2], entry[3]) end)
        end
      elseif myAction then
        s:act(function() s:executeAction(s.player, s.enemy, myAction) end)
      elseif theirAction then
        s:act(function() s:executeAction(s.enemy, s.player, theirAction) end)
      end
      s:act(function() s:endOfTurn() end)
      s:act(function()
        if s.linkEnded then return end
        local parts = stateSig(s, role, myParty, theirParty)
        local h = stateHash(s, role)
        s.localHashes[s.turnCount] = h
        s.localParts[s.turnCount] = parts
        send({ type = "hash", turn = s.turnCount, value = h, parts = parts })
        checkHashes(s)
      end)
    end)
  end

  self.pendingMyAction = nil
  self.remoteAction = nil
  local function tryResolve(s)
    if not s.pendingMyAction or not s.remoteAction then return end
    local mine, theirs = s.pendingMyAction, s.remoteAction
    s.pendingMyAction, s.remoteAction = nil, nil
    resolveLockstep(s, mine, theirs)
  end

  -- my chosen action: send it and wait for theirs
  local function submit(s, msg, localAction)
    msg.action = nil
    send(msg)
    msg.action = localAction
    s.pendingMyAction = msg
    s.phase = "waitRemote"
    tryResolve(s)
  end

  self.resolveTurn = function(s, action)
    local kind
    if action.struggle then
      kind = "struggle"
    elseif action.special then
      kind = "locked"
    else
      kind = "move"
    end
    local slot
    if kind == "move" then
      for i, mv in ipairs(s.player.curMoves) do
        if mv == action then slot = i end
      end
      if not slot then kind = "locked" end -- thrash/rage move instances
    end
    submit(s, { type = "action", kind = kind, slot = slot }, action)
  end

  self.resolveSwitch = function(s, newMon)
    for i, mon in ipairs(myParty) do
      if mon == newMon then
        submit(s, { type = "action", kind = "switch", index = i }, nil)
        return
      end
    end
  end

  -- the party menu must offer the clamped link copies
  self.openParty = function(s)
    s.phase = "messages"
    s.afterQueue = "menu"
    s:ui(function()
      return s:buildScreen("PartyMenu", {
        battle = s,
        party = myParty,
        onSwitch = function(mon)
          if mon == s.player.mon then
            s:say(("%s is\nalready out!"):format(s.player.name))
          elseif mon.hp <= 0 then
            s:say("There's no will\nto fight!")
          else
            s:resolveSwitch(mon)
          end
        end,
      })
    end)
  end

  self.openItems = function(s)
    s:say("Items can't be\nused in a link\nbattle!")
    s.phase = "messages"
    s.afterQueue = "menu"
  end

  self.tryRun = function(s)
    submit(s, { type = "action", kind = "run" }, nil)
  end

  -- fainted mons auto-replace with the next healthy teammate, in party
  -- order, identically on both machines
  self.playerMonFainted = function(s)
    for _, mon in ipairs(myParty) do
      if mon.hp > 0 then
        s:act(function()
          s.player = mkBattler(game.data, mon, true)
          s:sayNext(("Go! %s!"):format(s.player.name))
        end)
        return
      end
    end
    s:sayNext(("%s is out of\nPOKéMON!\f%s wins!"):format(game.save.player.name,
                                                          theirName))
    s.result = "lose"
    s.afterQueue = "finish"
  end

  self.enemyMonFainted = function(s)
    for _, mon in ipairs(theirParty) do
      if mon.hp > 0 then
        s:act(function()
          s.enemy = mkBattler(game.data, mon, false)
          s:sayNext(("%s sent\nout %s!"):format(theirName, s.enemy.name))
        end)
        return
      end
    end
    s:sayNext(("%s is out of\nPOKéMON!\f%s wins!"):format(theirName,
                                                          game.save.player.name))
    s.result = "win"
    s.afterQueue = "finish"
  end

  local baseUpdate = self.update
  self.update = function(s, dt)
    net:update()
    for _, msg in ipairs(net:poll()) do
      if msg.type == "action" then
        s.remoteAction = msg
        tryResolve(s)
      elseif msg.type == "hash" then
        s.remoteHashes[msg.turn or 0] = msg.value
        s.remoteParts[msg.turn or 0] = msg.parts
        checkHashes(s)
      elseif msg.type == "bye" then
        -- only a draw if our own simulation hasn't already decided
        -- (the winner's bye can arrive while we're still animating)
        if not s.result then
          endAsDraw(s, ("%s left the\nbattle."):format(theirName))
        end
      end
    end
    if net.closed and not s.linkEnded and not s.result then
      endAsDraw(s)
    end
    if s.phase == "waitRemote" then
      return -- the other side is still choosing
    end
    if s.phase == "messages" and s.afterQueue == "linkNext" then
      if not s:updateQueue() then
        s.afterQueue = "menu"
        s.phase = "menu"
      end
      return
    end
    baseUpdate(s, dt)
  end

  local baseFinish = self.finish
  self.finish = function(s)
    if not s.linkEnded then
      s.linkEnded = true
      send({ type = "bye" })
    end
    net:close()
    if game.linkNet == net then game.linkNet = nil end
    baseFinish(s)
  end

  return self
end

-- backwards-compatible entry points (LinkState passes role explicitly)
function LinkBattle.newHost(game, net, opts)
  opts.role = "host"
  return LinkBattle.new(game, net, opts)
end

function LinkBattle.newGuest(game, net, opts)
  opts.role = "guest"
  return LinkBattle.new(game, net, opts)
end

return LinkBattle
