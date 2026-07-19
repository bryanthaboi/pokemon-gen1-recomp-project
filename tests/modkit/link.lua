-- Loopback + lockstep helpers (21-testing-and-ci "link desync suite"),
-- generalized out of the hand-rolled harness in tests/run_link_tests.lua
-- so a modded battle can be driven the same way an unmodded one is.
--
-- Both sides run the whole engine locally off a shared seed; the only
-- thing crossing the wire is the turn's choice and a per-turn state hash.
-- If a mod changes battle math on one side only, the hashes diverge -- so
-- "the hashes agreed every turn" is the desync assertion, and the
-- handshake fingerprint is what is supposed to stop that battle starting.

local Net = require("src.link.Net")
local Protocol = require("src.link.Protocol")
local Pokemon = require("src.pokemon.Pokemon")
local SaveData = require("src.core.SaveData")

local Link = {}

-- the 15-line stack pattern from tests/run_link_tests.lua:171-186
function Link.fakeGame(data, leadSpecies, opts)
  opts = opts or {}
  local save = SaveData.newGame()
  local level = opts.level or 50
  for _, species in ipairs(type(leadSpecies) == "table" and leadSpecies or { leadSpecies }) do
    table.insert(save.party, Pokemon.new(data, species, level))
  end
  if opts.name then save.player.name = opts.name end

  local stack = { list = {} }
  function stack:push(state, ...)
    table.insert(self.list, state)
    if state.enter then state:enter(...) end
  end
  function stack:pop() table.remove(self.list) end
  function stack:top() return self.list[#self.list] end
  function stack:update(dt)
    local top = self:top()
    if top and top.update then top:update(dt) end
  end

  local Input = require("src.core.Input")
  return { data = data, input = Input, stack = stack, save = save }
end

-- the engine bits a battle needs before any of this runs
function Link.prepare(data)
  local Input = require("src.core.Input")
  Input:init()
  require("src.render.Font").load(data)
  return Input
end

-- run a full lockstep battle over a loopback pair, mashing A on both
-- sides, and report whether any turn's hashes disagreed
function Link.lockstep(gameA, gameB, opts)
  opts = opts or {}
  local LinkBattle = require("src.link.LinkBattle")
  local Input = require("src.core.Input")

  local netA, netB = Net.loopbackPair()
  local packedA = Protocol.packParty(gameA.save.party)
  local packedB = Protocol.packParty(gameB.save.party)
  local seed = opts.seed or 987654321

  local battleA = LinkBattle.newHost(gameA, netA, {
    myParty = packedA, theirParty = packedB,
    theirName = gameB.save.player.name, seed = seed,
  })
  local battleB = LinkBattle.newGuest(gameB, netB, {
    myParty = packedB, theirParty = packedA,
    theirName = gameA.save.player.name, seed = seed,
  })

  local resA, resB
  battleA.onFinish = function(r) resA = r end
  battleB.onFinish = function(r) resB = r end
  gameA.stack:push(battleA)
  gameB.stack:push(battleB)

  local guard, limit = 0, opts.maxFrames or 60000
  while (resA == nil or resB == nil) and guard < limit do
    guard = guard + 1
    Input.pressed = { a = true }
    gameA.stack:update(1 / 60)
    gameB.stack:update(1 / 60)
  end

  -- a turn present on both sides with different hashes is the desync the
  -- suite exists to catch
  local mismatch
  for turn, hash in pairs(battleA.localHashes) do
    local other = battleB.localHashes[turn]
    if other and other ~= hash then mismatch = mismatch or turn end
  end

  return {
    battleA = battleA, battleB = battleB,
    resultA = resA, resultB = resB,
    frames = guard, completed = resA ~= nil and resB ~= nil,
    desyncTurn = mismatch,
    agreed = mismatch == nil,
  }
end

-- convenience: build both sides and run, for the common symmetric case
function Link.pair(data, leadA, leadB, opts)
  opts = opts or {}
  Link.prepare(data)
  local gameA = Link.fakeGame(data, leadA, { name = opts.nameA or "RED", level = opts.level })
  local gameB = Link.fakeGame(data, leadB, { name = opts.nameB or "BLUE", level = opts.level })
  return gameA, gameB
end

-- the two hellos the handshake compares.  A one-sided mod moves the
-- fingerprint, which must land as "subset" -- and subset is not
-- battleAllowed, so the lockstep battle never starts instead of desyncing
-- into an unexplained draw.
function Link.handshake(gameA, gameB, modeA, modeB)
  local Handshake = require("src.link.Handshake")
  local helloA = Handshake.hello(gameA, modeA or "battle")
  local helloB = Handshake.hello(gameB, modeB)
  local verdict, reason = Handshake.checkCompat(helloA, helloB)
  return {
    helloA = helloA, helloB = helloB,
    verdict = verdict, reason = reason,
    match = helloA.fingerprint == helloB.fingerprint,
    battleAllowed = Handshake.battleAllowed(verdict),
    tradeAllowed = Handshake.tradeAllowed(verdict),
  }
end

return Link
