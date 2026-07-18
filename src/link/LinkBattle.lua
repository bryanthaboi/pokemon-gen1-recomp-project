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

local Logger = require("src.core.Logger")
local Protocol = require("src.link.Protocol")
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

-- canonical (host-side-first) state signature for desync detection
local function stateHash(self, role)
  local function sig(b)
    return ("%s:%d:%s"):format(b.mon.species, b.mon.hp, tostring(b.mon.status))
  end
  local hostSide = role == "host" and self.player or self.enemy
  local guestSide = role == "host" and self.enemy or self.player
  return sig(hostSide) .. "|" .. sig(guestSide)
end

-- opts: { myParty = packed, theirParty = packed, theirName, role =
-- "host"/"guest", seed }
function LinkBattle.new(game, net, opts)
  local BattleState = require("src.battle.BattleState")
  local role = opts.role
  local theirName = opts.theirName or "FOE"

  -- both parties pass through the same pack->unpack clamp on both
  -- machines, so the copies are identical everywhere
  local myParty, theirParty = {}, {}
  for _, p in ipairs(opts.myParty or {}) do
    local mon = Protocol.unpackMon(game.data, p)
    if mon then table.insert(myParty, mon) end
  end
  for _, p in ipairs(opts.theirParty or {}) do
    local mon = Protocol.unpackMon(game.data, p)
    if mon then table.insert(theirParty, mon) end
  end
  if #myParty == 0 or #theirParty == 0 then
    Logger.warn("link: empty party on one side")
  end

  -- build on a wild battle and reshape it into the lockstep link battle
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

  local function checkHashes(s)
    for turn, localH in pairs(s.localHashes) do
      local remoteH = s.remoteHashes[turn]
      if remoteH and remoteH ~= localH then
        Logger.warn("link: desync on turn %d (%s vs %s)", turn, localH, remoteH)
        endAsDraw(s, "Link error!\nThe battle ends\nin a draw.")
        return
      end
      if remoteH then
        s.localHashes[turn] = nil
        s.remoteHashes[turn] = nil
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
      if myAction and theirAction then
        -- the tie-break roll is shared: the guest inverts it so both
        -- machines agree on who goes first
        local first = TurnOrder.firstMover(s.player, orderMove(myAction),
                                           s.enemy, orderMove(theirAction),
                                           s.rng, role == "guest")
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
        local h = stateHash(s, role)
        s.localHashes[s.turnCount] = h
        send({ type = "hash", turn = s.turnCount, value = h })
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
    local PartyMenu = require("src.ui.PartyMenu")
    s.phase = "messages"
    s.afterQueue = "menu"
    s:ui(function()
      return PartyMenu.new(game, {
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
