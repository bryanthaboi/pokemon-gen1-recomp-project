-- Link play tests: the loopback transport, the trade session state
-- machine (with a trade evolution), and a lockstep link battle driven
-- over the loopback.  Runs headlessly under plain luajit:
--   luajit tests/run_link_tests.lua
-- Real networking uses lua-enet (bundled with LÖVE); when enet is
-- importable (inside LÖVE) an actual host/join pairing over UDP
-- localhost is exercised too, otherwise that section is skipped.

package.path = "./?.lua;./?/init.lua;" .. package.path
love = require("tests.love_stub")
math.randomseed(4242)

local failures = 0
local function check(cond, msg)
  if cond then
    print("ok   " .. msg)
  else
    failures = failures + 1
    print("FAIL " .. msg)
  end
end
local function eq(got, want, msg)
  check(got == want, ("%s (got %s, want %s)"):format(msg, tostring(got), tostring(want)))
end

local Data = require("src.core.Data")
Data:load()
local Pokemon = require("src.pokemon.Pokemon")
local Protocol = require("src.link.Protocol")

-- ---------------------------------------------------------------- json
local Json = require("src.link.Json")
local msg = { type = "party", n = 3, ok = true, list = { 1, 2, 3 },
              name = "RED\"s" }
local rt = Json.decode(Json.encode(msg))
eq(rt.type, "party", "json round trip type")
eq(rt.n, 3, "json round trip number")
eq(#rt.list, 3, "json round trip array")
eq(rt.name, 'RED"s', "json round trip escaping")

-- ---------------------------------------------------------------- pack/unpack
local kadabra = Pokemon.new(Data, "KADABRA", 30)
local packed = Protocol.packMon(kadabra)
local unpacked = Protocol.unpackMon(Data, packed)
eq(unpacked.species, "KADABRA", "mon survives the wire")
eq(unpacked.level, 30, "level survives")
eq(unpacked.stats.hp, kadabra.stats.hp, "stats recomputed identically")
-- tampering is clamped
packed.level = 3000
packed.dvs.attack = 99
local clamped = Protocol.unpackMon(Data, packed)
eq(clamped.level, 100, "tampered level clamped")
eq(clamped.dvs.attack, 15, "tampered DV clamped")

-- ---------------------------------------------------------------- transport
local Net = require("src.link.Net")

-- loopback pair: the offline transport the tests (and headless luajit,
-- which has no enet) run the protocol over
local lbA, lbB = Net.loopbackPair()
check(lbA.paired and lbB.paired, "loopback pair starts paired")
lbA:send({ type = "hello", name = "RED", mode = "trade" })
lbB:send({ type = "hello", name = "BLUE", mode = "trade" })
lbA:update()
lbB:update()
local gotA, gotB = lbA:poll()[1], lbB:poll()[1]
eq(gotA and gotA.name, "BLUE", "loopback A received B's hello")
eq(gotB and gotB.name, "RED", "loopback B received A's hello")
check(#lbA:poll() == 0, "poll drains the inbox")
lbB:close()
lbB:send({ type = "bye" })
lbA:update()
check(#lbA:poll() == 0, "a closed end sends nothing")

-- real enet pairing over UDP localhost (only when lua-enet is present,
-- i.e. inside LÖVE; plain luajit skips this section)
if Net.available() then
  local host = Net.new()
  check(host:host(7807), "host opens a UDP port")
  check(host.address ~= nil and host.address:match(":7807$") ~= nil,
        "host advertises an address: " .. tostring(host.address))
  local guest = Net.new()
  check(guest:join("127.0.0.1:7807"), "guest dials the address")
  local spins = 0
  while not (host.paired and guest.paired) and spins < 500000 do
    host:update()
    guest:update()
    spins = spins + 1
  end
  check(host.paired and guest.paired, "both sides paired over enet")

  host:send({ type = "hello", name = "RED", mode = "trade" })
  guest:send({ type = "hello", name = "BLUE", mode = "trade" })
  local got = { host = nil, guest = nil }
  spins = 0
  while (not got.host or not got.guest) and spins < 500000 do
    host:update()
    guest:update()
    for _, m in ipairs(host:poll()) do got.host = m end
    for _, m in ipairs(guest:poll()) do got.guest = m end
    spins = spins + 1
  end
  eq(got.host and got.host.name, "BLUE", "host received guest hello")
  eq(got.guest and got.guest.name, "RED", "guest received host hello")

  -- disconnect is noticed
  guest:close()
  spins = 0
  while not host.closed and spins < 500000 do
    host:update()
    spins = spins + 1
  end
  check(host.closed, "host notices the guest leaving")
  host:close()

  -- joining a dead address errors out (short timeout for the test)
  local reject = Net.new()
  reject.joinTimeout = 0.5
  reject:join("127.0.0.1:7809")
  local t0 = os.clock()
  while not reject.error and os.clock() - t0 < 30 do
    reject:update()
  end
  check(reject.error ~= nil, "unanswered join reports an error")
  reject:close()
else
  print("skip real enet pairing (lua-enet not available under this interpreter)")
end

-- ---------------------------------------------------------------- trade session
local partyA = { Pokemon.new(Data, "KADABRA", 30), Pokemon.new(Data, "PIDGEY", 10) }
local partyB = { Pokemon.new(Data, "MACHOKE", 32) }
local tA = Protocol.TradeSession.new(Data, partyA)
local tB = Protocol.TradeSession.new(Data, partyB)
tA:handle({ type = "party", mons = Protocol.packParty(partyB) })
tB:handle({ type = "party", mons = Protocol.packParty(partyA) })
eq(tA.stage, "picking", "trade session enters picking")
local pickA = tA:pick(1) -- gives KADABRA
local pickB = tB:pick(1) -- gives MACHOKE
tA:handle(pickB)
tB:handle(pickA)
eq(tA.stage, "confirming", "both picks -> confirming")
local cA = tA:confirm(true)
local cB = tB:confirm(true)
tA:handle(cB)
tB:handle(cA)
eq(tA.stage, "done", "trade completes")
local gotMon, evoTo = tA:apply(nil)
eq(gotMon.species, "MACHOKE", "A received Machoke")
eq(evoTo, "MACHAMP", "trade evolution triggers (Machoke -> Machamp)")
local gotMon2, evoTo2 = tB:apply(nil)
eq(gotMon2.species, "KADABRA", "B received Kadabra")
eq(evoTo2, "ALAKAZAM", "Kadabra -> Alakazam on trade")

-- declined trades cancel
local tC = Protocol.TradeSession.new(Data, partyA)
tC:handle({ type = "party", mons = Protocol.packParty(partyB) })
tC:pick(1)
tC:handle({ type = "pick", index = 1 })
tC:confirm(true)
tC:handle({ type = "confirm", ok = false })
eq(tC.stage, "cancelled", "declined trade cancels")

-- ---------------------------------------------------------------- link battle (lockstep)
-- Both sides run the full engine locally on a shared seed; this drives
-- two simulations over a loopback and checks they agree.
local Input = require("src.core.Input")
Input:init()
require("src.render.Font").load(Data)

local function makeFakeGame(leadSpecies)
  local save = require("src.core.SaveData").newGame()
  table.insert(save.party, Pokemon.new(Data, leadSpecies, 50))
  local stack = { list = {} }
  function stack:push(s, ...)
    table.insert(self.list, s)
    if s.enter then s:enter(...) end
  end
  function stack:pop() table.remove(self.list) end
  function stack:top() return self.list[#self.list] end
  function stack:update(dt)
    local t = self:top()
    if t and t.update then t:update(dt) end
  end
  return { data = Data, input = Input, stack = stack, save = save }
end

local LinkBattle = require("src.link.LinkBattle")
local gameA = makeFakeGame("CHARIZARD")
local gameB = makeFakeGame("BLASTOISE")
gameB.save.player.name = "BLUE"
-- each side's send lands in the other's inbox (json re-encoded like
-- the real wire) through Net's own loopback transport
local netA, netB = Net.loopbackPair()

local packedA = Protocol.packParty(gameA.save.party)
local packedB = Protocol.packParty(gameB.save.party)
local seed = 987654321

local battleA = LinkBattle.newHost(gameA, netA, {
  myParty = packedA, theirParty = packedB, theirName = "BLUE", seed = seed,
})
local battleB = LinkBattle.newGuest(gameB, netB, {
  myParty = packedB, theirParty = packedA, theirName = "RED", seed = seed,
})
local resA, resB = nil, nil
battleA.onFinish = function(r) resA = r end
battleB.onFinish = function(r) resB = r end
gameA.stack:push(battleA)
gameB.stack:push(battleB)
eq(battleA.kind, "link", "host battle is a link battle")
eq(battleA.enemy.mon.species, "BLASTOISE", "guest party became the host's enemy side")
eq(battleB.enemy.mon.species, "CHARIZARD", "host party became the guest's enemy side")

-- drive both sides with mashed A (FIGHT -> first move) until done
local guard = 0
while (resA == nil or resB == nil) and guard < 60000 do
  guard = guard + 1
  Input.pressed = { a = true }
  gameA.stack:update(1 / 60)
  gameB.stack:update(1 / 60)
end
check(resA ~= nil and resB ~= nil,
      ("lockstep battle completes on both sides (%s / %s)"):format(
        tostring(resA), tostring(resB)))
check((resA == "win" and resB == "lose") or (resA == "lose" and resB == "win")
      or (resA == "draw" and resB == "draw"),
      "the two simulations agree on the outcome")
-- mirrored final state: my mon's HP on A equals A's mon HP as seen by B
eq(battleA.player.mon.hp, battleB.enemy.mon.hp, "host mon HP identical on both sides")
eq(battleA.enemy.mon.hp, battleB.player.mon.hp, "guest mon HP identical on both sides")
local leftoverMismatch = false
for turn, h in pairs(battleA.localHashes) do
  if battleB.localHashes[turn] and battleB.localHashes[turn] ~= h then
    leftoverMismatch = true
  end
end
check(not leftoverMismatch, "no desync detected across the whole battle")
eq(gameA.save.money, 3000, "no prize money in link battles")
eq(gameA.save.party[1].hp, gameA.save.party[1].stats.hp,
   "the real party is untouched (battle used clamped copies)")

print(("\n%s"):format(failures == 0 and "ALL LINK TESTS PASSED" or failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
