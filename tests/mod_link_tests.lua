-- M12 link compatibility: fingerprint determinism, the v2 handshake and its
-- verdicts, the negotiated trade subset, the extra bag, ppUps on the wire,
-- and desync attribution over a loopback lockstep battle.  Self-contained
-- like the other mod suites: own bootstrap, assert-based checks, error() on
-- failure.  Chained from tests/run_link_tests.lua.
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local Data = require("src.core.Data")
if not Data.maps then Data:load() end
require("src.render.Font").load(Data)

local Events = require("src.mods.Events")
local Fingerprint = require("src.link.Fingerprint")
local Handshake = require("src.link.Handshake")
local Hooks = require("src.mods.Hooks")
local Input = require("src.core.Input")
local Json = require("src.link.Json")
local LinkBattle = require("src.link.LinkBattle")
local Net = require("src.link.Net")
local Pokemon = require("src.pokemon.Pokemon")
local Protocol = require("src.link.Protocol")
local Runtime = require("src.mods.Runtime")

local S = require("tests.harness").suite("mod link")
local check, eq = S.check, S.eq

-- a message as the peer sees it: through the same encoder the wire uses
local function wire(msg)
  return Json.decode(Json.encode(msg))
end

local function copy(record)
  local out = {}
  for k, v in pairs(record) do out[k] = v end
  return out
end

-- a merged-data view with its own id maps, so a fixture can retune a record
-- without touching the shared catalog
local function cloneData(base)
  local out = { pokemon = {}, moves = {}, type_chart = base.type_chart,
                constants = base.constants }
  for id, record in pairs(base.pokemon) do out.pokemon[id] = record end
  for id, record in pairs(base.moves) do out.moves[id] = record end
  return out
end

local function fakeGame(data, name)
  return { data = data, save = { player = { name = name } } }
end

-- ------- fingerprint determinism

local vanilla = cloneData(Data)
local first = Fingerprint.compute(vanilla, {})
eq(Fingerprint.compute(vanilla, {}), first, "fingerprint is stable across calls")
eq(#first, 16, "fingerprint is a 64-bit hex digest")

-- the same records reached through a differently built map: the digest walks
-- a sorted id list, so table layout can never leak into it
local reordered = { pokemon = {}, moves = {}, type_chart = Data.type_chart,
                    constants = Data.constants }
local ids = {}
for id in pairs(Data.pokemon) do ids[#ids + 1] = id end
table.sort(ids)
for i = #ids, 1, -1 do reordered.pokemon[ids[i]] = Data.pokemon[ids[i]] end
local moveIds = {}
for id in pairs(Data.moves) do moveIds[#moveIds + 1] = id end
table.sort(moveIds)
for i = #moveIds, 1, -1 do reordered.moves[moveIds[i]] = Data.moves[moveIds[i]] end
eq(Fingerprint.surface(reordered, {}), Fingerprint.surface(vanilla, {}),
   "insertion order does not reach the canonical stream")
eq(Fingerprint.compute(reordered, {}), first, "reordered data fingerprints the same")

-- a record rebuilt with its subtable keys in another order still hashes the
-- same, and a stat edit does not
local restated = cloneData(Data)
local pidgey = copy(Data.pokemon.PIDGEY)
pidgey.baseStats = { special = Data.pokemon.PIDGEY.baseStats.special,
                     speed = Data.pokemon.PIDGEY.baseStats.speed,
                     defense = Data.pokemon.PIDGEY.baseStats.defense,
                     attack = Data.pokemon.PIDGEY.baseStats.attack,
                     hp = Data.pokemon.PIDGEY.baseStats.hp }
restated.pokemon.PIDGEY = pidgey
eq(Fingerprint.compute(restated, {}), first, "subtable key order is irrelevant")

local buffed = cloneData(Data)
local strongPidgey = copy(Data.pokemon.PIDGEY)
strongPidgey.baseStats = copy(Data.pokemon.PIDGEY.baseStats)
strongPidgey.baseStats.attack = strongPidgey.baseStats.attack + 1
buffed.pokemon.PIDGEY = strongPidgey
check(Fingerprint.compute(buffed, {}) ~= first, "a baseStats edit moves the digest")

-- ------- path independence (excluded fields)

local repathed = cloneData(Data)
local movedSprites = copy(Data.pokemon.PIDGEY)
movedSprites.spriteFront = "assets/generated/other/machine/pidgey.png"
movedSprites.spriteBack = "assets/generated/other/machine/pidgeyb.png"
movedSprites.source = "ROM:BaseStats[999]"
movedSprites.dexEntry = { kind = "TINY BIRD", heightFt = 1, heightIn = 0,
                          weight = 4.0, text = "different flavour" }
movedSprites.learnset = {}
repathed.pokemon.PIDGEY = movedSprites
eq(Fingerprint.compute(repathed, {}), first,
   "sprite paths, source, dex entry and learnset stay out of the digest")

local retuned = cloneData(Data)
local strongTackle = copy(Data.moves.TACKLE)
strongTackle.power = 60
retuned.moves.TACKLE = strongTackle
check(Fingerprint.compute(retuned, {}) ~= first, "a move power edit moves the digest")

-- the affects-link mod set is folded in, so a logic-only change that ships
-- as a new version moves the digest even with identical records
local withMod = { { id = "rijon", version = "1.2.0", affectsLink = true } }
check(Fingerprint.compute(vanilla, withMod) ~= first, "affects-link mods fold in")
Fingerprint.forget(vanilla)
eq(Fingerprint.compute(vanilla, { { id = "rijon", version = "1.2.0",
                                    affectsLink = false } }), first,
   "a mod that declares it stays link-compatible does not")

-- the hook lets a total conversion widen or narrow the surface
local hooks = Hooks.new()
local events = Events.new()
local savedEvents, savedHooks = Runtime.events, Runtime.hooks
Runtime.install(events, hooks, {})
hooks:wrap("link.fingerprint", function(nxt, data, mods)
  return "ff" .. nxt(data, mods):sub(3)
end, 0, "test")
Fingerprint.forget(vanilla)
eq(Fingerprint.compute(vanilla, {}):sub(1, 2), "ff", "link.fingerprint hook applies")
hooks:removeOwner("test")
Fingerprint.forget(vanilla)
eq(Fingerprint.compute(vanilla, {}), first, "unwrapping restores the vanilla digest")

-- ------- linkModified: the cheap answer to "can I link with an old peer?"

-- the loader surface the discovery walk needs, backed by a path->text table
local function memfs(files)
  return {
    read = function(path) return files[path] end,
    getInfo = function(path)
      if files[path] then return { type = "file" } end
      local prefix = path .. "/"
      for key in pairs(files) do
        if key:sub(1, #prefix) == prefix then return { type = "directory" } end
      end
      return nil
    end,
    load = function(path)
      if not files[path] then return nil, "no file: " .. path end
      return load(files[path], path)
    end,
    getDirectoryItems = function(path)
      local seen, items = {}, {}
      local prefix = path .. "/"
      for key in pairs(files) do
        if key:sub(1, #prefix) == prefix then
          local child = key:sub(#prefix + 1):match("^[^/]+")
          if child and not seen[child] then
            seen[child] = true
            items[#items + 1] = child
          end
        end
      end
      table.sort(items)
      return items
    end,
  }
end

local pika = { name = "PIKA", baseStats = { hp = 1, attack = 1, defense = 1,
               speed = 1, special = 1 }, types = { "NORMAL" }, catchRate = 1,
               baseExp = 1, growthRate = "MEDIUM_FAST" }

local function loadMods(files)
  local data = { pokemon = { PIKA = pika }, moves = {}, audio = {} }
  local loader = require("src.mods.Loader").new({ fs = memfs(files) })
  loader:load(data)
  -- the loader claims the process-wide buses on load; this suite wants its own
  Runtime.install(events, hooks, {})
  return { mods = loader, data = data, save = { player = { name = "RED" } } }
end

local bareGame = loadMods({})
eq(Handshake.linkModified(bareGame), false, "no mods means an unmodified link")
eq(#Handshake.mods(bareGame), 0, "and an empty mod array on the wire")

local tweakGame = loadMods({
  ["mods/tweak/manifest.json"] =
    '{"id":"tweak","name":"tweak","version":"1.0.0","entry":"main.lua"}',
  ["mods/tweak/main.lua"] = [[
return function(mod)
  mod.content.pokemon:patch("PIKA", { catchRate = 40 })
end
]],
})
eq(Handshake.linkModified(tweakGame), true,
   "a content mod writing a link-surface record modifies the link")
eq(Handshake.mods(tweakGame)[1].affectsLink, false,
   "but a content pack does not claim the fingerprint by itself")

local overhaulGame = loadMods({
  ["mods/rijon/manifest.json"] =
    '{"id":"rijon","name":"rijon","version":"1.2.0","entry":"main.lua","profile":"overhaul"}',
  ["mods/rijon/main.lua"] = "return function(mod) end",
})
eq(Handshake.linkModified(overhaulGame), true, "an overhaul modifies the link")
eq(Handshake.mods(overhaulGame)[1].affectsLink, true, "and rides the hello")
eq(Handshake.hello(tweakGame, "trade").linkModified, true,
   "the hello carries the flag a v1 peer is judged against")

-- ------- builtin records are private per dataset

-- two independent loads must not share record tables: an edit through one
-- dataset (hot reload, a suite loading twice) must never reach the other,
-- nor the module statics the engine falls back on when it has no loader
local isoA, isoB = loadMods({}), loadMods({})
check(not rawequal(isoA.data.type_chart.types.NORMAL,
                   isoB.data.type_chart.types.NORMAL),
      "builtin type records are private per dataset")
check(not rawequal(isoA.data.type_chart.types.NORMAL,
                   require("src.battle.TypeChart").TYPES.NORMAL),
      "and are not the module's own table")
eq(isoA.data.type_chart.types.NORMAL.category, "physical",
   "the copy still carries the vanilla value")
isoA.data.type_chart.types.NORMAL.category = "special"
eq(isoB.data.type_chart.types.NORMAL.category, "physical",
   "an edit through one dataset stays in it")
check(not rawequal(isoA.data.statuses.BRN, isoB.data.statuses.BRN),
      "status records are private per dataset")
check(rawequal(isoA.data.statuses.BRN.residual, isoB.data.statuses.BRN.residual),
      "handler functions ride the copy by reference")

-- ------- link_fields: a declared extra field that forces agreement

local plainGame = loadMods({})
eq(plainGame.data.link_fields, nil,
   "an unregistered link_fields namespace never reaches Data")
local plainPrint = Fingerprint.compute(plainGame.data, {})

-- the held-item mod from the design, registered verbatim
local heldGame = loadMods({
  ["mods/held_items/manifest.json"] =
    '{"id":"held_items","name":"held items","version":"1.0.0","entry":"main.lua",'
    .. '"api":2,"affects_link":true}',
  ["mods/held_items/main.lua"] = [[
return function(mod)
  mod.content.link_fields:register("held_item", {
    rev = 1,
    pack = function(mon) return mon.heldItem end,
    unpack = function(mon, v) mon.heldItem = v end,
  })
end
]],
})
eq(#heldGame.mods.errors, 0, "a link_fields registration loads clean")
check(heldGame.mods.content.link_fields ~= nil,
      "the loader builds content.link_fields from the catalog")
eq(heldGame.data.link_fields.held_item.rev, 1, "and the merge lands the record")
eq(type(heldGame.data.link_fields.held_item.pack), "function",
   "the codec rides along for the wire")
eq(Handshake.linkModified(heldGame), true, "a declared field modifies the link")
local heldPrint = Fingerprint.compute(heldGame.data, {})
check(heldPrint ~= plainPrint, "and moves the fingerprint off vanilla")

-- rev is what an author bumps when the codec's meaning changes, so a peer
-- on the old revision lands in subset instead of desyncing mid-battle
heldGame.data.link_fields.held_item.rev = 2
Fingerprint.forget(heldGame.data)
check(Fingerprint.compute(heldGame.data, {}) ~= heldPrint, "bumping rev moves it again")

-- two mods can ship different bodies under one rev, so the digest must not
-- pretend it can see them
heldGame.data.link_fields.held_item.rev = 1
heldGame.data.link_fields.held_item.pack = function() return nil end
Fingerprint.forget(heldGame.data)
eq(Fingerprint.compute(heldGame.data, {}), heldPrint,
   "swapping the codec body alone does not")

local revlessGame = loadMods({
  ["mods/revless/manifest.json"] =
    '{"id":"revless","name":"revless","version":"1.0.0","entry":"main.lua","api":2}',
  ["mods/revless/main.lua"] = [[
return function(mod)
  mod.content.link_fields:register("held_item", { pack = function() end })
end
]],
})
check(table.concat(revlessGame.mods.errors, "\n")
        :find("link_fields.held_item", 1, true) ~= nil,
      "a field with no rev is rejected by name")
eq(revlessGame.data.link_fields, nil, "and leaves no residue")

-- ------- handshake verdicts

local helloA = Handshake.hello(fakeGame(vanilla, "RED"), "trade")
local helloB = Handshake.hello(fakeGame(cloneData(Data), "BLUE"), nil)
eq(helloA.protocol, 2, "hello announces the protocol revision")
eq(helloA.apiVersion, require("src.core.Version").modApi, "hello carries the api version")
eq(helloA.linkModified, false, "no mods means an unmodified link surface")
eq(helloA.fingerprint, helloB.fingerprint, "identical data fingerprints alike")
eq(Handshake.checkCompat(helloA, wire(helloB)), "full", "matching peers get full")
check(Handshake.battleAllowed("full"), "full allows lockstep")
check(Handshake.strict("full"), "full negotiates strictly")

-- side B adds a species and retunes a move: same engine, different surface
local modded = cloneData(Data)
local zorua = copy(Data.pokemon.RATTATA)
zorua.id, zorua.name, zorua.dex = "ZORUA", "ZORUA", 152
modded.pokemon.ZORUA = zorua
local moddedTackle = copy(Data.moves.TACKLE)
moddedTackle.power = 60
modded.moves.TACKLE = moddedTackle
local helloMod = Handshake.hello(fakeGame(modded, "BLUE"), nil)
helloMod.mods = { { id = "rijon", version = "1.2.0", affectsLink = true } }
eq(Handshake.checkCompat(helloA, wire(helloMod)), "subset",
   "differing fingerprints negotiate a subset")
check(not Handshake.battleAllowed("subset"), "subset refuses lockstep")
check(Handshake.tradeAllowed("subset"), "subset still trades")

-- v1 interop: no protocol field at all
eq(Handshake.checkCompat(helloA, { type = "hello", name = "OLD", mode = "trade" }),
   "vanilla_peer", "a v1 peer is compatible with an unmodified game")
local modifiedLocal = { linkModified = true, engineVersion = helloA.engineVersion,
                        fingerprint = "deadbeefdeadbeef", mods = {} }
eq(Handshake.checkCompat(modifiedLocal, { type = "hello", name = "OLD" }),
   "refused", "a v1 peer is refused by a link-modified game")
check(not Handshake.strict(nil), "no verdict keeps the v1 unpack path")

-- a different engine major is refused outright
local nextEngine = Handshake.hello(fakeGame(vanilla, "BLUE"), nil)
nextEngine.engineVersion = "2.0.0"
eq(Handshake.checkCompat(helloA, nextEngine), "refused", "engine major mismatch refuses")

local lines = Handshake.describe(helloA, wire(helloMod), "subset", "battle")
check(#lines > 0, "the incompatibility screen has something to say")
local joined = table.concat(lines, " ")
check(joined:find("RIJON", 1, true) ~= nil, "the report names the missing mod")
check(joined:find("battle", 1, true) ~= nil, "the report says battle is unavailable")
for _, line in ipairs(lines) do
  check(#line <= 20, "report line fits the screen: " .. line)
end
local refusedLines = Handshake.describe(modifiedLocal,
  { type = "hello", name = "OLD" }, "refused", "trade")
check(#refusedLines > 0, "a refusal explains itself too")
for _, line in ipairs(refusedLines) do
  check(#line <= 20, "refusal line fits the screen: " .. line)
end

-- ------- ppUps and the extra bag on the wire

local ppMon = Pokemon.new(Data, "PIDGEY", 20)
local base = Data.moves[ppMon.moves[1].id].pp
ppMon.moves[1].ppUps = 3
ppMon.moves[1].pp = base + 3 * math.floor(base / 5)
ppMon.extra = { held_items = { held_item = "LEFTOVERS", count = 2, on = true },
                bogus = print }
local packedPP = wire(Protocol.packMon(ppMon))
eq(packedPP.moves[1].ppUps, 3, "ppUps reaches the wire")
local restored = Protocol.unpackMon(Data, packedPP, { strict = true })
eq(restored.moves[1].ppUps, 3, "ppUps survives the round trip")
eq(restored.moves[1].pp, base + 3 * math.floor(base / 5),
   "PP clamps to the PP-Up-adjusted maximum, not base PP")
eq(restored.extra.held_items.held_item, "LEFTOVERS", "the extra bag round-trips")
eq(restored.extra.held_items.count, 2, "extra numbers round-trip")
eq(restored.extra.held_items.on, true, "extra booleans round-trip")
eq(restored.extra.bogus, nil, "a function in the extra bag is stripped")

local plainMon = Pokemon.new(Data, "PIDGEY", 20)
local packedPlain = Protocol.packMon(plainMon)
eq(packedPlain.moves[1].ppUps, nil, "a mon without PP Ups sends no ppUps key")
eq(packedPlain.extra, nil, "a mon without extra data sends no bag")
eq(Protocol.unpackMon(Data, wire(packedPlain)).moves[1].ppUps, nil,
   "an absent ppUps stays absent")

-- ------- negotiated rejection replaces the silent fallbacks

local orphan = { species = "PIDGEY", level = 20,
                 moves = { { id = "NOT_A_MOVE", pp = 10 } } }
local rebuilt = Protocol.unpackMon(Data, orphan)
eq(rebuilt.moves[1].id, "TACKLE", "the v1 path keeps the TACKLE substitute")
local rejected, why = Protocol.unpackMon(Data, orphan, { strict = true })
eq(rejected, nil, "strict mode rejects a mon with no shared moves")
eq(why, "no shared moves", "and says why")
local unknown, unknownWhy = Protocol.unpackMon(Data,
  { species = "ZORUA", level = 20, moves = {} }, { strict = true })
eq(unknown, nil, "strict mode rejects an unknown species")
check(unknownWhy ~= nil, "an unknown species is reported")

-- ------- subset trade: only mons both games rebuild identically

local partyVanilla = { Pokemon.new(Data, "PIDGEY", 12),
                       Pokemon.new(Data, "RATTATA", 12) }
partyVanilla[1].moves = { { id = "GUST", pp = Data.moves.GUST.pp } }
partyVanilla[2].moves = { { id = "TACKLE", pp = Data.moves.TACKLE.pp } }
local partyModded = { Pokemon.new(modded, "ZORUA", 12),
                      Pokemon.new(modded, "RATTATA", 12),
                      Pokemon.new(modded, "PIDGEY", 12) }
partyModded[1].moves = { { id = "GUST", pp = modded.moves.GUST.pp } }
partyModded[2].moves = { { id = "TACKLE", pp = modded.moves.TACKLE.pp } }
partyModded[3].moves = { { id = "GUST", pp = modded.moves.GUST.pp } }

local sessionA = Protocol.TradeSession.new(Data, partyVanilla,
  { subset = true, strict = true, peerName = "BLUE" })
local sessionB = Protocol.TradeSession.new(modded, partyModded,
  { subset = true, strict = true, peerName = "RED" })
local recordsA, recordsB = wire(sessionA:opening()), wire(sessionB:opening())
eq(recordsA.type, "records", "a subset trade opens with the record hashes")
local partyMsgA = wire(sessionA:handle(recordsB))
local partyMsgB = wire(sessionB:handle(recordsA))
eq(#partyMsgA.mons, 1, "only the agreed mons leave the vanilla game")
eq(#partyMsgB.mons, 1, "only the agreed mons leave the modded game")
eq(partyMsgA.mons[1].species, "PIDGEY", "the clean PIDGEY is eligible")
eq(partyMsgB.mons[1].species, "PIDGEY", "the modded game sends its clean PIDGEY")
check(sessionA:canPick(1), "a mon with shared data can be picked")
check(not sessionA:canPick(2), "a mon knowing a retuned move cannot")
check(sessionA.reasons[2] ~= nil, "the ineligible mon carries a reason")
check(not sessionB:canPick(1), "a species the other game lacks cannot be picked")
eq(sessionB.reasons[1], "not on the other game", "and says so")

sessionA:handle(partyMsgB)
sessionB:handle(partyMsgA)
eq(sessionA.stage, "picking", "both parties arrived")
local pickA = wire(sessionA:pick(1))    -- real slot 1
local pickB = wire(sessionB:pick(3))    -- real slot 3, wire slot 1
eq(pickB.index, 1, "the wire index is a position in the filtered list")
sessionA:handle(pickB)
sessionB:handle(pickA)
eq(sessionA.stage, "confirming", "both picks landed")
sessionA:handle(wire(sessionB:confirm(true)))
sessionB:handle(wire(sessionA:confirm(true)))
eq(sessionA.stage, "done", "the subset trade completes")
local received = sessionA:apply(nil)
eq(received.species, "PIDGEY", "the vanilla game received the agreed mon")
eq(partyVanilla[1], received, "and it landed in the slot that was given")

-- a full-verdict session sends the whole party and indexes it directly
local fullSession = Protocol.TradeSession.new(Data, partyVanilla, { strict = true })
eq(fullSession.stage, "waitParty", "a full session skips the record exchange")
eq(#fullSession:opening().mons, 2, "a full session sends the whole party")
eq(fullSession:wireIndex(2), 2, "and its wire indices are party slots")

-- ------- the state machine: hello promoted to pairing, verdict branch

local LinkState = require("src.link.LinkState")

local function mkInput()
  local stub = { pressed = {} }
  function stub:wasPressed(key) return self.pressed[key] == true end
  return stub
end

local function linkGame(name, species, data)
  local save = require("src.core.SaveData").newGame()
  save.player.name = name
  table.insert(save.party, Pokemon.new(Data, species, 20))
  local stack = { list = {} }
  function stack:push(state, ...)
    table.insert(self.list, state)
    if state.enter then state:enter(...) end
  end
  function stack:pop() return table.remove(self.list) end
  function stack:top() return self.list[#self.list] end
  return { data = data or Data, save = save, stack = stack, input = mkInput() }
end

-- two paired states, host already listening and guest already dialling
local function pairStates(gameA, gameB)
  local netA, netB = Net.loopbackPair()
  local host, guest = LinkState.new(gameA), LinkState.new(gameB)
  host.net, guest.net = netA, netB
  host.stage, guest.stage = "hosting", "joining"
  gameA.stack:push(host)
  gameB.stack:push(guest)
  return host, guest
end

local function pump(a, b, gameA, gameB, times)
  for _ = 1, (times or 1) do
    a:update(1 / 60)
    b:update(1 / 60)
    gameA.input.pressed = {}
    gameB.input.pressed = {}
  end
end

local gameHost, gameGuest = linkGame("RED", "PIDGEY"), linkGame("BLUE", "RATTATA")
local host, guest = pairStates(gameHost, gameGuest)
pump(host, guest, gameHost, gameGuest, 2)
eq(host.stage, "modeSelect", "the host reaches mode select")
eq(guest.stage, "waitMode", "the guest waits for the mode")
check(guest.myHello ~= nil and guest.myHello.protocol == 2,
      "the guest announces itself the moment it pairs")
check(host.peerHello ~= nil, "the host has the peer hello before it picks")

gameHost.input.pressed = { a = true }
host:update(1 / 60)
gameHost.input.pressed = {}
eq(host.verdict, "full", "two identical games agree")
eq(host.stage, "trade", "and go straight into the mode")
pump(host, guest, gameHost, gameGuest, 3)
eq(guest.verdict, "full", "the guest reaches the same verdict")
eq(host.trade.stage, "picking", "the host's trade session is ready")
eq(guest.trade.stage, "picking", "the guest's trade session is ready")
check(host.trade.strict, "a v2 verdict unpacks strictly")

-- a v1 peer sends the raw {name, mode} hello and nothing else
local gameOld = linkGame("RED", "PIDGEY")
local oldNet, peerNet = Net.loopbackPair()
local v1guest = LinkState.new(gameOld)
v1guest.net = oldNet
v1guest.stage = "joining"
gameOld.stack:push(v1guest)
v1guest:update(1 / 60)
peerNet:send({ type = "hello", name = "OLD", mode = "trade" })
peerNet:send({ type = "party",
               mons = Protocol.packParty({ Pokemon.new(Data, "MACHOKE", 20) }) })
v1guest:update(1 / 60)
eq(v1guest.verdict, "vanilla_peer", "an old peer is accepted by an unmodified game")
v1guest:update(1 / 60)
eq(v1guest.trade.stage, "picking", "and the v1 trade runs as it always did")
check(not v1guest.trade.strict, "the v1 path keeps the old unpack rules")

-- the host talking to a peer that never says hello falls back after the
-- grace period, and its own hello still carries the v1 fields
local gameLone = linkGame("RED", "PIDGEY")
local loneNet, silentNet = Net.loopbackPair()
local v1host = LinkState.new(gameLone)
v1host.net = loneNet
v1host.stage = "hosting"
gameLone.stack:push(v1host)
v1host:update(1 / 60)
gameLone.input.pressed = { a = true }
v1host:update(1 / 60)
gameLone.input.pressed = {}
eq(v1host.stage, "waitHello", "the host waits for the peer's hello")
for _ = 1, 200 do v1host:update(1 / 60) end
eq(v1host.verdict, "vanilla_peer", "silence means a pre-mod peer")
eq(v1host.stage, "trade", "and the v1 path runs")
local sawHello = false
for _, msg in ipairs(silentNet:poll()) do
  if msg.type == "hello" then
    sawHello = true
    eq(msg.mode, "trade", "the hello still carries the mode a v1 guest reads")
    eq(msg.name, "RED", "and the name")
  end
end
check(sawHello, "the host's hello went out")

-- mismatched surfaces: the screen explains, trade continues in subset mode
local gameVan, gameMod = linkGame("RED", "PIDGEY"), linkGame("BLUE", "RATTATA", modded)
local vanHost, modGuest = pairStates(gameVan, gameMod)
pump(vanHost, modGuest, gameVan, gameMod, 2)
gameVan.input.pressed = { a = true }
vanHost:update(1 / 60)
gameVan.input.pressed = {}
eq(vanHost.verdict, "subset", "differing data lands in subset")
eq(vanHost.stage, "notice", "and shows the incompatibility screen")
check(#vanHost.noticeLines > 0, "the screen has lines to draw")
vanHost:draw() -- smoke: the report renders under the headless stub
check(not vanHost.noticeExits, "a subset trade may continue")
pump(vanHost, modGuest, gameVan, gameMod, 2)
eq(modGuest.stage, "notice", "the guest sees the same screen")
gameVan.input.pressed = { a = true }
gameMod.input.pressed = { a = true }
vanHost:update(1 / 60)
modGuest:update(1 / 60)
gameVan.input.pressed = {}
gameMod.input.pressed = {}
eq(vanHost.trade.stage, "waitRecords", "continuing opens a subset session")
pump(vanHost, modGuest, gameVan, gameMod, 3)
eq(vanHost.trade.stage, "picking", "the record exchange completes")
check(vanHost.trade.subset, "the session negotiated a subset")
vanHost:draw() -- smoke: the ineligible rows render too

-- the same mismatch on the battle side refuses instead
local gameVan2, gameMod2 = linkGame("RED", "PIDGEY"), linkGame("BLUE", "RATTATA", modded)
local vanHost2, modGuest2 = pairStates(gameVan2, gameMod2)
pump(vanHost2, modGuest2, gameVan2, gameMod2, 2)
vanHost2.index = 2 -- BATTLE
gameVan2.input.pressed = { a = true }
vanHost2:update(1 / 60)
gameVan2.input.pressed = {}
eq(vanHost2.stage, "notice", "a mismatched link battle stops at the screen")
check(vanHost2.noticeExits, "and the screen is the end of it")
vanHost2:draw() -- smoke: the battle-refusal wording renders too
gameVan2.input.pressed = { a = true }
vanHost2:update(1 / 60)
gameVan2.input.pressed = {}
check(gameVan2.stack:top() ~= vanHost2, "acknowledging leaves link play")

-- ------- lockstep battle: refusal, the turn-order hook, desync attribution

-- pinned DVs keep the lockstep run reproducible: the shared seed only fixes
-- the RNG stream, and rolled DVs would move the whole battle underneath it
local function fixedMon(species, level)
  local mon = Pokemon.new(Data, species, level)
  mon.dvs = { hp = 8, attack = 8, defense = 8, speed = 8, special = 8 }
  mon.statExp = { hp = 0, attack = 0, defense = 0, speed = 0, special = 0 }
  mon.stats = require("src.pokemon.Stats").calc(Data.pokemon[species], level,
                                                mon.dvs, mon.statExp)
  mon.hp = mon.stats.hp
  return mon
end

local function makeFakeGame(leadSpecies)
  local save = require("src.core.SaveData").newGame()
  table.insert(save.party, fixedMon(leadSpecies, 50))
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
  return { data = Data, input = Input, stack = stack, save = save }
end

Input:init()

local refused, refusedWhy = LinkBattle.newHost(makeFakeGame("CHARIZARD"),
  select(1, Net.loopbackPair()),
  { myParty = Protocol.packParty(partyVanilla),
    theirParty = Protocol.packParty(partyVanilla), verdict = "subset" })
eq(refused, nil, "a subset verdict refuses to build a link battle")
check(refusedWhy ~= nil, "and reports why")
local strictRefused = LinkBattle.newHost(makeFakeGame("CHARIZARD"),
  select(1, Net.loopbackPair()),
  { myParty = { { species = "ZORUA", level = 20, moves = {} } },
    theirParty = Protocol.packParty(partyVanilla),
    verdict = "full", strict = true })
eq(strictRefused, nil, "a strict battle refuses a mon the peer cannot rebuild")

-- ------- pokemon.received on the link-battle unpack

-- the held-item validator from the design's mod-author example: it must get
-- the same shot at a link battle's mons that it gets at a traded one
local function heldMon(species, level, item)
  local mon = fixedMon(species, level)
  mon.extra = { held_items = { held_item = item } }
  return mon
end

local mine = { heldMon("CHARIZARD", 50, "LEFTOVERS"), fixedMon("PIDGEY", 20) }
local theirs = { heldMon("BLASTOISE", 50, "BAD_ITEM") }
local packedMine, packedTheirs = Protocol.packParty(mine), Protocol.packParty(theirs)

local seen
events:on("pokemon.received", function(payload)
  seen[#seen + 1] = payload
  payload.mon.nickname = "CHECKED"
  local bag = payload.mon.extra and payload.mon.extra.held_items
  if bag and bag.held_item == "BAD_ITEM" then bag.held_item = nil end
end, 0, "test")

seen = {}
local hostSide = LinkBattle.newHost(makeFakeGame("CHARIZARD"),
  select(1, Net.loopbackPair()),
  { myParty = packedMine, theirParty = packedTheirs, theirName = "BLUE",
    seed = 11, verdict = "full", strict = true })
check(hostSide ~= nil, "the host side builds")
eq(#seen, 3, "pokemon.received fires once per mon on both parties")
eq(seen[1].from, "link", "the payload names the link as the source")
eq(seen[1].peerName, "BLUE", "and carries the peer name")
eq(seen[1].mon.species .. "," .. seen[2].mon.species .. "," .. seen[3].mon.species,
   "CHARIZARD,PIDGEY,BLASTOISE", "the host announces its own party first")
eq(hostSide.player.name, "CHECKED",
   "a listener's edit reaches the battler it is built from")
eq(hostSide.enemy.mon.extra.held_items.held_item, nil,
   "an unrecognised held item is stripped before the simulation sees it")

-- the guest holds the same two parties the other way round and has to walk
-- them in the same order, or a mutating validator desyncs the lockstep
seen = {}
local guestSide = LinkBattle.newGuest(makeFakeGame("BLASTOISE"),
  select(1, Net.loopbackPair()),
  { myParty = packedTheirs, theirParty = packedMine, theirName = "RED",
    seed = 11, verdict = "full", strict = true })
check(guestSide ~= nil, "the guest side builds")
eq(#seen, 3, "and sees the same three mons")
eq(seen[1].mon.species .. "," .. seen[2].mon.species .. "," .. seen[3].mon.species,
   "CHARIZARD,PIDGEY,BLASTOISE", "in the same host-first order as the host")

events:removeOwner("test")
seen = {}
local unhooked = LinkBattle.newHost(makeFakeGame("CHARIZARD"),
  select(1, Net.loopbackPair()),
  { myParty = packedMine, theirParty = packedTheirs, theirName = "BLUE",
    seed = 11, verdict = "full", strict = true })
eq(#seen, 0, "nothing is emitted once the listener is gone")
eq(unhooked.enemy.mon.extra.held_items.held_item, "BAD_ITEM",
   "and the unpacked mon is untouched with nobody subscribed")

-- both sides run the same modded ordering rule and the same asymmetric
-- stage bump; the first proves the link path honours the battle hooks M6
-- landed, the second proves a divergence is caught and named
local orderCalls = 0
hooks:wrap("battle.turn_order", function(nxt, a, aMove, b, bMove, ctx)
  orderCalls = orderCalls + 1
  return nxt(a, aMove, b, bMove, ctx)
end, 0, "test")

local turnStarts = 0
local desync = nil
events:on("battle.turn_started", function(payload)
  turnStarts = turnStarts + 1
  check(payload.turn ~= nil, "battle.turn_started carries the turn number")
end, 0, "test")
events:on("link.desync", function(payload) desync = desync or payload end, 0, "test")

local gameA, gameB = makeFakeGame("CHARIZARD"), makeFakeGame("BLASTOISE")
gameB.save.player.name = "BLUE"
local netA, netB = Net.loopbackPair()
local packedA = Protocol.packParty(gameA.save.party)
local packedB = Protocol.packParty(gameB.save.party)
local battleA = LinkBattle.newHost(gameA, netA, {
  myParty = packedA, theirParty = packedB, theirName = "BLUE", seed = 424242,
  verdict = "full", strict = true })
local battleB = LinkBattle.newGuest(gameB, netB, {
  myParty = packedB, theirParty = packedA, theirName = "RED", seed = 424242,
  verdict = "full", strict = true })
check(battleA ~= nil and battleB ~= nil, "a full verdict builds both sides")

-- only the host's simulation gets the extra boost, so the two states must
-- disagree on the actives component
events:on("battle.turn_started", function(payload)
  if payload.battle == battleA and payload.turn == 2 then
    local stages = payload.battle.player.stages
    stages.attack = (stages.attack or 0) + 2
  end
end, 0, "test")

local resA, resB
battleA.onFinish = function(result) resA = result end
battleB.onFinish = function(result) resB = result end
gameA.stack:push(battleA)
gameB.stack:push(battleB)
local guard = 0
while (resA == nil or resB == nil) and guard < 60000 do
  guard = guard + 1
  Input.pressed = { a = true }
  gameA.stack:update(1 / 60)
  gameB.stack:update(1 / 60)
end
check(orderCalls > 0, "the link path routes turn order through battle.turn_order")
check(turnStarts > 0, "the link path emits battle.turn_started")
eq(resA, "draw", "the host ends the desynced match as a draw")
eq(resB, "draw", "the guest ends the desynced match as a draw")
check(desync ~= nil, "link.desync fired")
eq(desync.component, "actives", "the report names the diverging component")
eq(desync.turn, 2, "and the turn it happened on")
check(desync.localHash ~= desync.remoteHash, "the two component hashes differ")
check(battleA.localHashes[2]:find("^%u+:%d+:") ~= nil,
      "the hash message keeps the v1 value shape a pre-mod peer compares")

-- a verified turn stays recorded, so a finished battle's whole hash trail
-- can be swept; consuming compared turns left 0-1 entries behind
for turn = 1, battleA.turnCount do
  check(battleA.localHashes[turn] ~= nil and battleA.localParts[turn] ~= nil,
        "the host retains the turn " .. turn .. " hash record")
end
eq(battleA.localHashes[1], battleB.localHashes[1],
   "the retained pre-desync hashes agree across peers")

-- a pre-mod peer sends no parts at all, so the combined value has to stay
-- the comparison of record
desync = nil
local gameOldPeer = makeFakeGame("CHARIZARD")
local oldNetA = select(1, Net.loopbackPair())
local battleOld = LinkBattle.newHost(gameOldPeer, oldNetA, {
  myParty = Protocol.packParty(gameOldPeer.save.party),
  theirParty = Protocol.packParty(makeFakeGame("BLASTOISE").save.party),
  theirName = "OLD", seed = 7 })
gameOldPeer.stack:push(battleOld)
battleOld.localHashes[1] = "CHARIZARD:100:nil|BLASTOISE:100:nil"
table.insert(oldNetA.inbox, { type = "hash", turn = 1,
                              value = "CHARIZARD:100:nil|BLASTOISE:100:nil" })
gameOldPeer.stack:update(1 / 60)
eq(battleOld.result, nil, "a matching v1 hash is not a desync")
eq(desync, nil, "and nothing is reported")
check(battleOld.localHashes[1] ~= nil, "a matching v1 hash stays recorded")
table.insert(oldNetA.inbox, { type = "hash", turn = 2, value = "elsewhere" })
battleOld.localHashes[2] = "CHARIZARD:90:nil|BLASTOISE:80:nil"
gameOldPeer.stack:update(1 / 60)
eq(battleOld.result, "draw", "a differing v1 hash still ends the match")
check(desync ~= nil and desync.component == "state",
      "and is attributed to the whole state, the only thing a v1 peer sends")

events:removeOwner("test")
hooks:removeOwner("test")
Runtime.install(savedEvents, savedHooks, nil)

S.finish()
