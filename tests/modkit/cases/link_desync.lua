-- T4: the link desync suite extended for modded battles
-- (21-testing-and-ci "link desync suite").
--
-- Three classes, all ROM-free against the fixture dataset:
--
--   symmetric-mod   the same mod on both sides changes battle math and
--                   desyncs nothing -- the two simulations stay mirrored.
--   one-sided mod   the handshake sees the fingerprint move and refuses
--                   the battle, instead of letting it desync into a draw
--                   that explains nothing.
--   extra bag       a mod field and ppUps survive the wire, and a mon a
--                   total conversion cannot rebuild is rejected by name
--                   rather than silently substituted.
--
-- The primary desync assertion is the mirrored final state (my mon's HP on
-- A equals A's mon as seen by B), not the per-turn hash table: LinkBattle
-- only records a hash on turns that reach its end-of-turn act, so the hash
-- table is sparse enough that "no mismatch" alone would pass vacuously.
-- Hashes are still compared where both sides recorded one.

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local Protocol = require("src.link.Protocol")
local Pokemon = require("src.pokemon.Pokemon")

math.randomseed(4242)

-- a mod that moves battle math: moves are link surface, so installing it
-- must move the fingerprint.  accuracy is 0..100 and the effect has to
-- resolve against the move_effects registry -- a mod registration is
-- schema-checked even though the base dataset's own records are not.
local BATTLE_MOD = {
  ["mods/fix_battle_mod/manifest.json"] = [[{
    "id": "fix_battle_mod",
    "name": "Fixture Battle Mod",
    "version": "1.0.0",
    "entry": "main.lua",
    "api": 2,
    "affects_link": true
  }]],
  ["mods/fix_battle_mod/main.lua"] = [[
    local mod = ...
    mod.content.moves:register("FIX_MODMOVE", {
      id = "FIX_MODMOVE", index = 90, name = "FIX MODMOVE",
      effect = "BURN_SIDE_EFFECT1",
      power = 60, type = "FIRE", accuracy = 100, pp = 20,
      anim = { sound = 1, pitch = 0, tempo = 0 },
    })
  ]],
}

local function loadBattleMod(data)
  return T.sdk.loadMods({ "mods/fix_battle_mod" },
    { data = data, fs = T.sdk.memfs(BATTLE_MOD) })
end

-- ------- symmetric mod: identical installs stay in lockstep

do
  local dataA = T.fixtures.fresh()
  local dataB = T.fixtures.fresh()
  local runA = loadBattleMod(dataA)
  T.eq(#runA.errors, 0, "the battle mod loads clean on side A")
  T.check(dataA.moves.FIX_MODMOVE ~= nil, "the mod's move merged into side A")
  runA.release()

  local runB = loadBattleMod(dataB)
  T.eq(#runB.errors, 0, "the battle mod loads clean on side B")
  T.check(dataB.moves.FIX_MODMOVE ~= nil, "the mod's move merged into side B")
  runB.release()

  local Fingerprint = require("src.link.Fingerprint")
  local mods = { { id = "fix_battle_mod", version = "1.0.0", affectsLink = true } }
  T.eq(Fingerprint.compute(dataA, mods), Fingerprint.compute(dataB, mods),
    "two identical modded installs agree on the fingerprint")

  -- and the battle really runs to a mirrored finish.  dataA already
  -- carries the engine's built-in records from the merge above: a second
  -- load into the same table would re-register them and raise, so both
  -- sides share this one dataset (as two installs of the same mod do).
  T.link.prepare(dataA)
  local gameA = T.link.fakeGame(dataA, { "FIXMON_A", "FIXMON_C" }, { name = "RED", level = 20 })
  local gameB = T.link.fakeGame(dataA, { "FIXMON_B", "FIXMON_A" }, { name = "BLUE", level = 20 })
  local result = T.link.lockstep(gameA, gameB, { maxFrames = 60000 })

  T.check(result.completed, "the symmetric-mod lockstep battle completes on both sides")
  T.check((result.resultA == "win" and result.resultB == "lose")
       or (result.resultA == "lose" and result.resultB == "win")
       or (result.resultA == "draw" and result.resultB == "draw"),
    ("both simulations agree on the outcome (%s / %s)")
      :format(tostring(result.resultA), tostring(result.resultB)))

  -- the dense check: each side's view of the same mon must match
  T.eq(result.battleA.player.mon.hp, result.battleB.enemy.mon.hp,
    "host mon HP identical on both sides")
  T.eq(result.battleA.enemy.mon.hp, result.battleB.player.mon.hp,
    "guest mon HP identical on both sides")
  T.eq(result.battleA.player.mon.species, result.battleB.enemy.mon.species,
    "host active species identical on both sides")
  T.check(result.agreed, "no per-turn hash mismatch across the battle")

  -- the real party is untouched: link battles fight clamped copies
  T.eq(gameA.save.party[1].hp, gameA.save.party[1].stats.hp,
    "the real party is untouched by the link battle")
end

-- ------- one-sided mod: the handshake must fail closed

do
  local plain = T.fixtures.fresh()
  local plainRun = T.sdk.loadNone({ data = plain })

  local modded = T.fixtures.fresh()
  local moddedRun = loadBattleMod(modded)
  T.eq(#moddedRun.errors, 0, "the one-sided install loads clean")
  moddedRun.release()

  T.link.prepare(plain)
  local gameA = T.link.fakeGame(plain, "FIXMON_A", { name = "RED" })
  local gameB = T.link.fakeGame(modded, "FIXMON_B", { name = "BLUE" })

  -- Handshake.mods reads game.mods, so stand in the loaded set explicitly:
  -- side B is the one carrying the mod
  gameB.mods = { status = function()
    return { loaded = { { id = "fix_battle_mod", version = "1.0.0", affects_link = true } } }
  end }

  local shake = T.link.handshake(gameA, gameB, "battle", nil)
  T.check(not shake.match, "a one-sided mod moves the fingerprint")
  T.eq(shake.verdict, "subset", "the handshake grades a fingerprint mismatch as subset")
  T.eq(shake.reason, "fingerprint_mismatch", "the mismatch is named, not generic")
  T.eq(shake.battleAllowed, false,
    "a subset verdict refuses the lockstep battle rather than desyncing into it")
  T.eq(shake.tradeAllowed, true, "a subset verdict still permits a negotiated trade")

  -- the positive control: two identical sides must be allowed to battle,
  -- or the assertion above would pass simply because nothing ever links
  local twin = T.fixtures.fresh()
  local twinRun = T.sdk.loadNone({ data = twin })
  local gameC = T.link.fakeGame(twin, "FIXMON_A", { name = "GREEN" })
  local clean = T.link.handshake(gameA, gameC, "battle", nil)
  T.check(clean.match, "two unmodded sides agree on the fingerprint")
  T.eq(clean.verdict, "full", "two unmodded sides grade as full compatibility")
  T.eq(clean.battleAllowed, true, "two unmodded sides may battle")
  twinRun.release()
  plainRun.release()
end

-- ------- extra bag, ppUps, and strict rejection

do
  local data = T.fixtures.fresh()
  local run = T.sdk.loadNone({ data = data })

  local mon = Pokemon.new(data, "FIXMON_A", 20)
  mon.extra = { fix_mod_charge = 7, fix_mod_flag = true, fix_mod_name = "SODA" }
  mon.moves[1].ppUps = 3

  local packed = Protocol.packMon(mon)
  T.check(packed.extra ~= nil, "the extra bag rides the wire")
  T.eq(packed.extra.fix_mod_charge, 7, "a numeric mod field is packed")
  T.eq(packed.extra.fix_mod_flag, true, "a boolean mod field is packed")
  T.eq(packed.extra.fix_mod_name, "SODA", "a string mod field is packed")
  T.eq(packed.moves[1].ppUps, 3, "ppUps are packed")

  local received = Protocol.unpackMon(data, packed)
  T.check(received ~= nil, "the mon rebuilds on the far side")
  T.eq(received.extra.fix_mod_charge, 7, "the mod field survives the round trip")
  T.eq(received.extra.fix_mod_flag, true, "the boolean survives the round trip")
  T.eq(received.extra.fix_mod_name, "SODA", "the string survives the round trip")
  T.eq(received.moves[1].ppUps, 3, "ppUps survive the round trip")
  T.eq(received.species, "FIXMON_A", "the species survives")
  T.eq(received.level, 20, "the level survives")

  -- the extra bag is a copy, not a shared reference: a mod mutating its
  -- own field must not reach back through the wire
  received.extra.fix_mod_charge = 99
  T.eq(mon.extra.fix_mod_charge, 7, "the extra bag is copied, not aliased")

  -- strict rejection: a total conversion that never heard of this species
  -- must say so rather than substitute a hard-coded fallback
  local foreign = Protocol.packMon(mon)
  foreign.species = "NOT_IN_THIS_DATASET"
  local rebuilt, reason = Protocol.unpackMon(data, foreign, { strict = true })
  T.eq(rebuilt, nil, "an unknown species is rejected under strict")
  T.check(reason ~= nil and tostring(reason):find("POK") ~= nil,
    "the rejection names the species problem (got " .. tostring(reason) .. ")")

  -- and a mon whose moves the dataset does not have
  local noMoves = Protocol.packMon(mon)
  noMoves.moves = { { id = "NOT_A_MOVE_HERE", pp = 10 } }
  local rebuilt2, reason2 = Protocol.unpackMon(data, noMoves, { strict = true })
  T.eq(rebuilt2, nil, "a mon with no shared moves is rejected under strict")
  T.eq(reason2, "no shared moves", "the rejection names the move problem")

  -- without strict, the v1 path still substitutes rather than crashing
  local lenient = Protocol.unpackMon(data, noMoves)
  T.check(lenient ~= nil, "the non-strict path still rebuilds a mon")
  T.check(#lenient.moves > 0, "the non-strict path gives the mon a usable move")

  run.release()
end

T.finish("link_desync")
