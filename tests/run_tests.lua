-- Headless smoke/behavior tests.  Run from the repo root after building
-- the generated data:
--   lua5.4 tests/run_tests.lua
--
-- These exercise real generated data end-to-end: map collision, warps,
-- text, stats, damage, growth, type chart, encounters, scripts and the
-- battle loop -- everything except actual rendering.

package.path = "./?.lua;./?/init.lua;" .. package.path
love = require("tests.love_stub")

-- assertions and the RNG seed come off the shared harness; this file keeps
-- its own tail because the verdict line ("N FAILURES") is what CI greps
local T = require("tests.harness")
-- this suite has always streamed a line per check, and it is the one a
-- developer watches for progress through ~1600 assertions
T.verbose = true
local check, eq = T.check, T.eq

-- ---------------------------------------------------------------- data
local Data = require("src.core.Data")
Data:load()
check(Data.maps.PALLET_TOWN ~= nil, "generated data loads")

-- ---------------------------------------------------------------- map & collision
local MapLoader = require("src.world.MapLoader")
local pallet = MapLoader.load(Data, "PALLET_TOWN")
eq(pallet.widthCells, 20, "Pallet Town width in cells")
eq(pallet.heightCells, 18, "Pallet Town height in cells")

-- known ground truth: the fence row below the houses is blocked, the
-- open plaza is walkable, house doors are warps on door tiles
check(pallet:isWalkableCell(5, 6), "spawn cell (5,6) walkable")
check(not pallet:isWalkableCell(4, 4), "house cell (4,4) blocked")
check(not pallet:isWalkableCell(0, 3), "west fence blocked")
check(pallet:isWalkableCell(5, 5), "Red's house door cell walkable")
check(pallet:isWarpTileCell(5, 5), "Red's house door is a door tile")
local w = pallet:warpAtCell(5, 5)
eq(w.def.destMap, "REDS_HOUSE_1F", "door warp goes to Red's house")

-- Pallet south shore spit: land that faces ROUTE_21 solids. Crossing
-- without reading the neighbor tile stranded players (see
-- tests/parity_connection_collision.lua).
local Map = require("src.world.Map")
local route21Def = Data.maps.ROUTE_21
local route21Tileset = Data.tilesets[route21Def.tileset]
check(pallet:isWalkableCell(2, 17), "Pallet south shore spit (2,17) walkable")
check(pallet:isWalkableCell(3, 17), "Pallet south shore spit (3,17) walkable")
check(not Map.defPassable(route21Def, route21Tileset, 2, 0, false),
      "ROUTE_21 (2,0) refuses a land edge cross")
check(not Map.defPassable(route21Def, route21Tileset, 3, 0, false),
      "ROUTE_21 (3,0) refuses a land edge cross")

-- signs
local sign = pallet:signAtCell(13, 13)
eq(sign.text, "TEXT_PALLETTOWN_OAKSLAB_SIGN", "Oak's lab sign at (13,13)")

-- ---------------------------------------------------------------- warp resolution
local Warp = require("src.world.Warp")
local destMap, dx, dy = Warp.destination(Data, { destMap = "OAKS_LAB", destWarp = 2 })
eq(destMap, "OAKS_LAB", "warp dest map")
eq(dx, 5, "Oak's Lab warp 2 x")
eq(dy, 11, "Oak's Lab warp 2 y")

local lab = MapLoader.load(Data, "OAKS_LAB")
local lm, lx, ly = Warp.destination(Data, lab.def.warps[1],
                                    { id = "PALLET_TOWN", x = 12, y = 11 })
eq(lm, "PALLET_TOWN", "LAST_MAP warp returns to Pallet Town")
eq(lx, 12, "LAST_MAP x remembered")

-- ---------------------------------------------------------------- text
check(Data.text._PalletTownSignText:find("PALLET TOWN", 1, true) ~= nil,
      "sign text extracted")
local girl = Data:resolveText("PalletTown", "TEXT_PALLETTOWN_GIRL")
check(girl and girl:find("raising", 1, true) ~= nil, "girl text via TEXT_ pointer")
check(girl:find("POKéMON", 1, true) ~= nil, "#MON expanded to POKéMON")

-- ---------------------------------------------------------------- font/textbox
local Font = require("src.render.Font")
Font.load(Data)
local codes = Font.encode("PALLET TOWN!")
eq(#codes, 12, "encode length")
eq(codes[1], 0x8F, "P glyph code")
eq(codes[7], 0x7F, "space glyph code")
eq(codes[12], 0xE7, "! glyph code")

local TextBox = require("src.render.TextBox")
local pages = TextBox.paginate("I'm raising\nPOKéMON too!\fWhen they get\nstrong, they can\vprotect me!")
eq(#pages, 2, "two pages")
eq(#pages[1], 2, "page 1 has two lines")
eq(#pages[2], 3, "page 2 keeps scrolled line")

-- ---------------------------------------------------------------- stats & growth
local Stats = require("src.pokemon.Stats")
local Growth = require("src.pokemon.Growth")
local bulba = Data.pokemon.BULBASAUR
local zeroDVs = { hp = 0, attack = 0, defense = 0, speed = 0, special = 0 }
local s = Stats.calc(bulba, 5, zeroDVs)
-- hand-checked Gen 1 formulas
eq(s.hp, 19, "L5 Bulbasaur HP (0 DVs)")
eq(s.attack, 9, "L5 Bulbasaur Attack (0 DVs)")
eq(s.special, 11, "L5 Bulbasaur Special (0 DVs)")

local maxDVs = { hp = 15, attack = 15, defense = 15, speed = 15, special = 15 }
local s100 = Stats.calc(Data.pokemon.MEWTWO, 100, maxDVs,
                        { hp = 65535, attack = 65535, defense = 65535,
                          speed = 65535, special = 65535 })
eq(s100.hp, 415, "L100 Mewtwo max HP (known value)")
eq(s100.special, 406, "L100 Mewtwo max Special (known value)")

-- stat exp bonus is a CEILING sqrt (CalcStat .statExpLoop finds the
-- smallest b with b*b >= statExp): statExp 130 -> b 12 -> bonus 3,
-- where a floor sqrt would give 11 -> 2.  At L100 the bonus lands
-- unscaled: 49*2 + 3 + 5 = 106.
do
  local sExpCeil = Stats.calc(bulba, 100, zeroDVs, { attack = 130 })
  eq(sExpCeil.attack, 106, "stat exp bonus uses ceil(sqrt) (statExp 130 -> +3)")
end

eq(Growth.expForLevel("MEDIUM_SLOW", 5), 135, "medium slow exp at L5")
eq(Growth.expForLevel("MEDIUM_FAST", 10), 1000, "medium fast exp at L10")
eq(Growth.levelForExp("MEDIUM_FAST", 999), 9, "level from exp")

-- ---------------------------------------------------------------- type chart
local TypeChart = require("src.battle.TypeChart")
TypeChart.load(Data)
eq(TypeChart.effectiveness("WATER", { "FIRE" }), 20, "water vs fire 2x")
eq(TypeChart.effectiveness("ELECTRIC", { "GROUND" }), 0, "electric vs ground immune")
eq(TypeChart.effectiveness("GRASS", { "WATER", "POISON" }), 10, "grass vs water/poison neutral")
eq(TypeChart.effectiveness("WATER", { "GRASS", "DRAGON" }), 2, "water vs grass/dragon 0.25x")

-- ---------------------------------------------------------------- damage
local Damage = require("src.battle.Damage")
local Pokemon = require("src.pokemon.Pokemon")
local ruleset = require("src.battle.rulesets.gen1_faithful")

local function fixedMon(species, level)
  local mon = Pokemon.new(Data, species, level)
  mon.dvs = zeroDVs
  mon.stats = Stats.calc(Data.pokemon[species], level, zeroDVs)
  mon.hp = mon.stats.hp
  return mon
end

local function battler(mon, def)
  return { mon = mon, def = def, stages = {}, name = def.id,
           curStats = mon.stats, curTypes = def.types, curMoves = mon.moves }
end

local atkMon, defMon = fixedMon("BULBASAUR", 5), fixedMon("RATTATA", 3)
local attacker = battler(atkMon, bulba)
local defender = battler(defMon, Data.pokemon.RATTATA)
local tackle = Data.moves.TACKLE
-- hand-computed: atk 9 (L5 Bulbasaur), def 7 (L3 Rattata, base 35):
-- floor(2*5/5)+2=4; floor(4*35*9/7 / 50)=floor(180/50)=3; +2=5;
-- no STAB (tackle is Normal, attacker Grass/Poison); max roll 255 -> 5
local dmg = Damage.compute(ruleset, attacker, defender, tackle,
                           { rng = function() return 255 end, forceCrit = false })
eq(dmg, 5, "deterministic Tackle damage (max roll)")
-- min roll 217: floor(5*217/255)=4
dmg = Damage.compute(ruleset, attacker, defender, tackle,
                     { rng = function() return 217 end, forceCrit = false })
eq(dmg, 4, "deterministic Tackle damage (min roll)")

-- STAB + effectiveness: vine whip (grass 35) vs squirtle L5
local sq = fixedMon("SQUIRTLE", 5)
local defSq = battler(sq, Data.pokemon.SQUIRTLE)
-- base: floor(2*5/5)+2=4; atk special 11 vs def special 10:
-- floor(floor(4*35*11/10)/50)=3; +2=5; STAB floor(5*3/2)=7; x2 type=14; max roll 14
dmg = Damage.compute(ruleset, attacker, defSq, Data.moves.VINE_WHIP,
                     { rng = function() return 255 end, forceCrit = false })
eq(dmg, 14, "Vine Whip STAB + super effective vs Squirtle")

-- immunity
local gastly = fixedMon("GASTLY", 5)
dmg = Damage.compute(ruleset, attacker, battler(gastly, Data.pokemon.GASTLY),
                     tackle, { rng = function() return 255 end, forceCrit = false })
eq(dmg, 0, "Normal vs Ghost immune")

-- ---------------------------------------------------------------- encounters
local Encounter = require("src.world.Encounter")
local route1 = Data.encounters.ROUTE_1
check(route1.grass.rate == 25 and #route1.grass.slots == 10, "Route 1 table shape")
local hit = Encounter.roll(route1, function(a, b) return 0 end)
eq(hit.species, "PIDGEY", "slot 1 is Pidgey L3")
eq(hit.level, 3, "slot 1 level")

-- ---------------------------------------------------------------- trainers
local rival = Data.trainers.OPP_RIVAL1
check(rival and #rival.parties >= 1, "Rival1 parties extracted")
eq(rival.parties[1][1].level, 5, "Rival1 first party is L5")

-- ---------------------------------------------------------------- moves at level
local mv = Pokemon.movesAtLevel(Data.pokemon.RATTATA, 3)
eq(mv[1], "TACKLE", "Rattata L3 move 1")
eq(mv[2], "TAIL_WHIP", "Rattata L3 move 2")
local mv7 = Pokemon.movesAtLevel(Data.pokemon.RATTATA, 7)
eq(mv7[3], "QUICK_ATTACK", "Rattata learns Quick Attack at 7")

-- ---------------------------------------------------------------- screens & focus energy
local reflDef = battler(fixedMon("RATTATA", 3), Data.pokemon.RATTATA)
reflDef.reflect = true
local dmgRefl = Damage.compute(ruleset, attacker, reflDef, tackle,
                               { rng = function() return 255 end, forceCrit = false })
check(dmgRefl < 5, "Reflect halves physical damage (" .. dmgRefl .. " < 5)")

-- gen1 focus energy bug: crit threshold quartered
local fe = battler(fixedMon("BULBASAUR", 5), bulba)
fe.focusEnergy = true
local critCount = 0
for i = 0, 255 do
  if Damage.critRoll(ruleset, fe, "TACKLE", function() return i end) then
    critCount = critCount + 1
  end
end
eq(critCount, math.floor(math.floor(45 / 2) / 4), "Focus Energy bug quarters crit rate")

-- ---------------------------------------------------------------- items
local ItemEffects = require("src.inventory.ItemEffects")
local save = require("src.core.SaveData").newGame()
local hurt = fixedMon("BULBASAUR", 5)
hurt.hp = 1
local result = ItemEffects.use(Data, save, "POTION", hurt)
eq(result, "consumed", "potion consumed")
eq(hurt.hp, 19, "potion heals 20 capped at max (1 -> 19/19)")
hurt.status = "PSN"
result = ItemEffects.use(Data, save, "ANTIDOTE", hurt)
eq(hurt.status, nil, "antidote cures poison")
result = ItemEffects.use(Data, save, "BURN_HEAL", hurt)
eq(result, "failed", "burn heal fails on healthy mon")
hurt.hp = 0
ItemEffects.use(Data, save, "REVIVE", hurt)
eq(hurt.hp, 9, "revive restores half HP")
local r2, payload = ItemEffects.use(Data, save, "TM_TOXIC", hurt)
eq(r2, "learn", "TM06 teaches Toxic to Bulbasaur")
eq(payload, "TOXIC", "TM payload is the move id")
local pikachu = fixedMon("PIKACHU", 10)
local r3 = ItemEffects.use(Data, save, "TM_TOXIC", pikachu)
check(r3 == "learn", "Pikachu can learn Toxic (in tmhm list)")
local r4 = ItemEffects.use(Data, save, "HM_SURF", pikachu)
eq(r4, "failed", "Pikachu can't learn Surf")
local r5, _, extra = ItemEffects.use(Data, save, "THUNDER_STONE", pikachu)
eq(r5, "consumed", "Thunder Stone works on Pikachu")
eq(extra.evolveTo, "RAICHU", "Thunder Stone evolves Pikachu to Raichu")

-- ---------------------------------------------------------------- evolution data
local Evolution = require("src.pokemon.Evolution")
local wart = fixedMon("SQUIRTLE", 16)
eq(Evolution.pendingLevelEvo(Data, wart), "WARTORTLE", "Squirtle evolves at 16")
local low = fixedMon("SQUIRTLE", 15)
eq(Evolution.pendingLevelEvo(Data, low), nil, "no evolution below 16")

-- ---------------------------------------------------------------- marts & trainer headers
local vmClerk = Data:textEntry("ViridianMart", "TEXT_VIRIDIANMART_CLERK")
check(vmClerk and vmClerk.mart and #vmClerk.mart == 4, "Viridian Mart sells 4 items")
eq(vmClerk.mart[1], "POKE_BALL", "Viridian Mart slot 1")
local nurse = Data:textEntry("ViridianPokecenter", "TEXT_VIRIDIANPOKECENTER_NURSE")
check(nurse and nurse.nurse == true, "Viridian nurse marked")
local hdr = Data:trainerHeader("Route3", 2)
check(hdr and hdr.range == 2 and hdr.event == "EVENT_BEAT_ROUTE_3_TRAINER_0",
      "Route 3 trainer header extracted")
check(Data.text[hdr.battle] ~= nil, "trainer battle text resolves")
check(Data.text._PokemonCenterWelcomeText:find("CENTER", 1, true) ~= nil,
      "engine strings extracted (nurse welcome)")

-- ---------------------------------------------------------------- field data
check(#Data.field.ledges == 8, "8 ledge rules")
check(#Data.field.cutTreeSwaps == 9, "9 cut tree swaps")

-- ---------------------------------------------------------------- story data
-- legendaries are static encounters, not trainers
local seafoam = Data.maps.SEAFOAM_ISLANDS_B4F
local articuno
for _, o in ipairs(seafoam.objects) do
  if o.pokemon then articuno = o end
end
check(articuno and articuno.pokemon == "ARTICUNO" and articuno.level == 50,
      "Articuno static encounter extracted")
-- the Silph Scope is an item ball in the hideout
local scope
for _, o in ipairs(Data.maps.ROCKET_HIDEOUT_B4F.objects) do
  if o.item == "SILPH_SCOPE" then scope = o end
end
check(scope ~= nil, "Silph Scope item ball extracted")
-- trades
eq(Data.field.trades[2].give, "ABRA", "trade 2 wants Abra")
eq(Data.field.trades[2].get, "MR_MIME", "trade 2 gives Mr. Mime")
eq(Data.field.trades[2].nickname, "MARCEL", "trade 2 nickname")
-- music song table (only when the full audio extraction ran)
if Data.audio and next(Data.audio.mapSongs) then
  check(Data.audio.mapSongs.PALLET_TOWN == "Music_PalletTown",
        "Pallet Town song mapped")
  check(Data.audio.songs.Music_PalletTown ~= nil, "Pallet Town song rendered")
end

-- Victory Road switch barriers: block (bx=3,by=4) on 2F must start
-- blocked and open up when replaced with $15 (scripts/VictoryRoad2F.asm)
local vr2 = MapLoader.load(Data, "VICTORY_ROAD_2F")
local beforeBlock = vr2:blockAt(3, 4)
local cellBlockedBefore = not vr2:isWalkableCell(7, 9)
vr2:setBlock(3, 4, 0x15)
local cellOpenAfter = vr2:isWalkableCell(7, 9)
vr2:setBlock(3, 4, beforeBlock) -- restore for other tests
check(cellBlockedBefore and cellOpenAfter,
      ("VR2F switch1 barrier opens (block %d -> $15, blocked %s open %s)")
      :format(beforeBlock, tostring(cellBlockedBefore), tostring(cellOpenAfter)))

-- ---------------------------------------------------------------- polish systems
-- dex entries
eq(Data.pokemon.BULBASAUR.dexEntry.kind, "SEED", "Bulbasaur dex kind")
check(Data.text[Data.pokemon.BULBASAUR.dexEntry.text] ~= nil, "dex description text")
-- AI move-choice mods
eq(#Data.trainers.OPP_YOUNGSTER.aiMods, 0, "Youngster has no AI mods")
eq(table.concat(Data.trainers.OPP_POKEMANIAC.aiMods, ","), "1,2,3", "Pokemaniac AI mods")
-- fly warps
eq(Data.field.flyWarps.PALLET_TOWN.x, 5, "Pallet fly spot")
-- badge boost: BoulderBadge multiplies attack x9/8 (atk 9 -> 10)
local badged = battler(fixedMon("BULBASAUR", 5), bulba)
badged.badges = { BOULDERBADGE = true }
local dmgBadge = Damage.compute(ruleset, badged, defender, tackle,
                                { rng = function() return 255 end, forceCrit = false })
eq(dmgBadge, 6, "BoulderBadge boosts physical damage (5 -> 6)")

-- the full badge map (ApplyBadgeStatBoosts): Boulder -> Attack,
-- Thunder -> DEFENSE, Soul -> SPEED, Volcano -> Special.
-- Synthetic 10/10/10/10 battlers at L10: base damage
-- floor(floor(6*100*10/10)/50)+2 = 14 at max roll; a 9/8 boost moves
-- the attacker to 15 and the defender to 12.
do
local function plainBattler(badges)
  return { curStats = { attack = 10, defense = 10, speed = 10, special = 10 },
           stages = {}, curTypes = {}, badges = badges, name = "TEST",
           mon = { level = 10 }, def = { baseStats = { speed = 10 } } }
end
local physTest = { id = "PHYS_TEST", power = 100, type = "NORMAL", accuracy = 100 }
local specTest = { id = "SPEC_TEST", power = 100, type = "FIRE", accuracy = 100 }
local maxRoll = { rng = function() return 255 end, forceCrit = false }
eq((Damage.compute(ruleset, plainBattler(nil), plainBattler(nil), physTest, maxRoll)),
   14, "badge-free baseline damage")
eq((Damage.compute(ruleset, plainBattler({ BOULDERBADGE = true }), plainBattler(nil),
                   physTest, maxRoll)),
   15, "BOULDERBADGE boosts attack")
eq((Damage.compute(ruleset, plainBattler(nil), plainBattler({ THUNDERBADGE = true }),
                   physTest, maxRoll)),
   12, "THUNDERBADGE boosts defense")
eq((Damage.compute(ruleset, plainBattler(nil), plainBattler({ SOULBADGE = true }),
                   physTest, maxRoll)),
   14, "SOULBADGE does not boost defense")
eq((Damage.compute(ruleset, plainBattler({ VOLCANOBADGE = true }), plainBattler(nil),
                   specTest, maxRoll)),
   15, "VOLCANOBADGE boosts special (attacking)")
eq((Damage.compute(ruleset, plainBattler(nil), plainBattler({ VOLCANOBADGE = true }),
                   specTest, maxRoll)),
   12, "VOLCANOBADGE boosts special (defending)")
local TurnOrder = require("src.battle.TurnOrder")
eq(TurnOrder.effectiveSpeed(plainBattler({ SOULBADGE = true })), 11,
   "SOULBADGE boosts speed")
eq(TurnOrder.effectiveSpeed(plainBattler({ THUNDERBADGE = true })), 10,
   "THUNDERBADGE does not boost speed")

-- confusion self-hit: typeless 40-power hit with no damage roll
-- (HandleSelfConfusionDamage skips RandomizeDamage) whose Reflect check
-- reads the OPPONENT's screens, not the user's own
local confused = plainBattler(nil)
local confMove = { id = "CONFUSED", power = 40, type = "NORMAL", accuracy = 100 }
local selfHitA = Damage.compute(ruleset, confused, confused, confMove,
                  { rng = function() return 255 end, forceCrit = false, typeless = true })
local selfHitB = Damage.compute(ruleset, confused, confused, confMove,
                  { rng = function(a) return a end, forceCrit = false, typeless = true })
eq(selfHitA, selfHitB, "confusion self-hit damage is deterministic")
confused.reflect = true
eq((Damage.compute(ruleset, confused, confused, confMove,
                   { rng = function() return 255 end, forceCrit = false, typeless = true })),
   selfHitA, "own Reflect does not soften the self-hit")
local reflOpp = plainBattler(nil)
reflOpp.reflect = true
check(Damage.compute(ruleset, confused, confused, confMove,
                     { rng = function() return 255 end, forceCrit = false,
                       typeless = true, screens = reflOpp }) < selfHitA,
      "the opponent's Reflect doubles the self-hit defense")

-- MIST blocks primary stat drops but NOT side-effect drops
-- (StatModifierDownEffect's side-effect branch skips MoveHitTest)
local MoveEffects = require("src.battle.MoveEffects")
local sideRng = { rng = function() return 0 end }
local misted = { stages = {}, mist = true, name = "MISTY", mon = {} }
MoveEffects.secondary.ATTACK_DOWN_SIDE_EFFECT(sideRng, nil, misted)
eq(misted.stages.attack, -1, "secondary stat drop pierces MIST")
local misted2 = { stages = {}, mist = true, name = "MISTY", mon = {} }
local mistMsgs = MoveEffects.primary.ATTACK_DOWN1_EFFECT(sideRng, nil, misted2)
check(misted2.stages.attack == nil
      and mistMsgs[1]:find("MIST", 1, true) ~= nil,
      "primary stat drop still blocked by MIST")

-- Substitute boundary: built at exactly 1/4 max HP, leaving 0 HP
-- (substitute.asm only fails on subtraction underflow)
local subUser = { mon = { stats = { hp = 40 }, hp = 10 }, name = "SUBBY" }
MoveEffects.primary.SUBSTITUTE_EFFECT(sideRng, subUser)
check(subUser.substituteHP ~= nil and subUser.mon.hp == 0,
      "substitute built at exactly 1/4 max HP leaves 0 HP")
local subUser2 = { mon = { stats = { hp = 40 }, hp = 9 }, name = "SUBBY" }
local subMsgs = MoveEffects.primary.SUBSTITUTE_EFFECT(sideRng, subUser2)
check(subUser2.substituteHP == nil
      and subMsgs[1]:find("weak", 1, true) ~= nil,
      "substitute fails below 1/4 max HP")

-- Haze clears Disable/X ACCURACY on both sides and forfeits the turn of
-- a mon whose sleep/freeze it just cured (haze.asm selected move $ff)
local hazeUser = { stages = { attack = 2 }, xAccuracy = true, mon = {}, name = "HAZER" }
local hazeTarget = { stages = {}, disabledSlot = 1, disabledTurns = 3,
                     mon = { status = "FRZ" }, name = "FROZEN" }
MoveEffects.primary.HAZE_EFFECT(sideRng, hazeUser, hazeTarget)
check(hazeUser.xAccuracy == nil and hazeTarget.disabledSlot == nil,
      "Haze clears X ACCURACY and Disable")
check(hazeTarget.mon.status == nil and hazeTarget.skipMove == true,
      "Haze cures the target's freeze and forfeits its move")
local StatusMod = require("src.battle.Status")
local hazeCanMove, hazeMsgs = StatusMod.beforeMove(hazeTarget, sideRng.rng)
check(hazeCanMove == false and #hazeMsgs == 0 and hazeTarget.skipMove == nil,
      "the forfeited move is skipped silently")
end
-- X item in a stub battle
local ItemFx = require("src.inventory.ItemEffects")
local stubBattle = { player = badged, kind = "wild" }
local xr = ItemFx.use(Data, Game and Game.save or require("src.core.SaveData").newGame(),
                      "X_ATTACK", nil, stubBattle)
eq(xr, "consumed", "X ATTACK usable in battle")
eq(badged.stages.attack, 1, "X ATTACK raises attack stage")
local xr2 = ItemFx.use(Data, require("src.core.SaveData").newGame(), "X_ATTACK", nil, nil)
eq(xr2, "failed", "X ATTACK unusable outside battle")

-- ---------------------------------------------------------------- battle loop (scripted)
local Game = require("src.core.Game")
local Input = require("src.core.Input")
local StateStack = require("src.core.StateStack")
Game.data = Data
Game.input = Input; Input:init()
Game.stack = StateStack; StateStack:init()
Game.save = require("src.core.SaveData").newGame()
table.insert(Game.save.party, Pokemon.new(Data, "BULBASAUR", 5))

local BattleState = require("src.battle.BattleState")
local finished = nil
local battle = BattleState.newWild(Game, "RATTATA", 2)
battle.onFinish = function(result) finished = result end
StateStack:push(battle)

-- drive the battle: mash A and pick FIGHT/first move until it ends
local guard = 0
while finished == nil and guard < 20000 do
  guard = guard + 1
  Input:keypressed("z") -- A button
  Input:step()
  Input.pressed = { a = true }
  StateStack:update(1 / 60)
  Input:keyreleased("z")
end
check(finished == "win" or finished == "lose",
      "wild battle runs to completion (result: " .. tostring(finished) .. ")")
check(Game.save.party[1].exp > Growth.expForLevel("MEDIUM_SLOW", 5) or finished == "lose",
      "winner gained experience")

-- ---------------------------------------------------------------- script runner
local ScriptRunner = require("src.script.ScriptRunner")
local Flags = require("src.script.Flags")
local runner = ScriptRunner.new(Game, nil)
local ranBattle = false
runner.overworld = nil
local script = {
  { "set_flag", "TEST_FLAG" },
  { "check_flag", "TEST_FLAG" },
  { "jump_if_false", 5 },
  { "give_item", "POTION", 2 },
  { "clear_flag", "TEST_FLAG" },
}
runner:run(script, {})
-- give_item now blocks on its received-item box (GiveItem prints and
-- waits, like the original); pump the stack until the script finishes
local scriptGuard = 0
while runner:isRunning() and scriptGuard < 2000 do
  scriptGuard = scriptGuard + 1
  Input:keypressed("z")
  Input:step()
  Input.pressed = { a = true }
  StateStack:update(1 / 60)
  Input:keyreleased("z")
end
check(not Flags.get(Game.save, "TEST_FLAG"), "script flag set/clear")
eq(Game.save.inventory.POTION, 2, "script give_item")

-- ---------------------------------------------------------------- parcel quest chain
local mapScripts = require("data.scripts.init")
local function runScript(script)
  local r = ScriptRunner.new(Game, nil)
  r:run(script, {})
  local guard = 0
  while r:isRunning() and guard < 2000 do
    guard = guard + 1
    Input.pressed = { a = true }
    StateStack:update(1 / 60)
    r:update()
  end
  Input.pressed = {}
  return not r:isRunning()
end

Flags.set(Game.save, "EVENT_GOT_STARTER")
check(runScript(mapScripts.talkScript("VIRIDIAN_MART", "TEXT_VIRIDIANMART_CLERK")),
      "mart clerk script completes")
eq(Game.save.inventory.OAKS_PARCEL, 1, "clerk hands over Oak's Parcel")
check(Flags.get(Game.save, "EVENT_GOT_OAKS_PARCEL"), "parcel flag set")

check(runScript(mapScripts.talkScript("OAKS_LAB", "TEXT_OAKSLAB_OAK1")),
      "Oak delivery script completes")
eq(Game.save.inventory.OAKS_PARCEL, nil, "parcel delivered")
check(Flags.get(Game.save, "EVENT_OAK_GOT_PARCEL"), "delivery flag set")
check(Flags.get(Game.save, "EVENT_GOT_POKEDEX"), "Pokedex flag set")

-- captain gives HM01 exactly once
check(runScript(mapScripts.talkScript("SS_ANNE_CAPTAINS_ROOM",
                                      "TEXT_SSANNECAPTAINSROOM_CAPTAIN")),
      "captain script completes")
eq(Game.save.inventory.HM_CUT, 1, "captain gives HM01 Cut")
runScript(mapScripts.talkScript("SS_ANNE_CAPTAINS_ROOM",
                                "TEXT_SSANNECAPTAINSROOM_CAPTAIN"))
eq(Game.save.inventory.HM_CUT, 1, "HM01 only given once")

-- ---------------------------------------------------------------- hidden items / spinners / slots data
local hi = Data.field.hiddenItems.VIRIDIAN_FOREST
check(hi and hi[1].item == "POTION" and hi[1].x == 1 and hi[1].y == 18,
      "Viridian Forest hidden POTION at (1,18)")
check(Data.field.hiddenCoins.GAME_CORNER and #Data.field.hiddenCoins.GAME_CORNER >= 6,
      "Game Corner hidden coins extracted")
local slotSeats = Data.field.slotMachines.GAME_CORNER
check(slotSeats and #slotSeats >= 30, "Game Corner slot machine seats extracted")
eq(#Data.field.slotWheels, 3, "three slot wheels")
eq(Data.field.slotWheels[1][1], "7", "wheel 1 starts with 7")
eq(#Data.field.slotWheels[1], 18, "wheel 1 has 18 symbols")
local vgSpin = Data.field.spinners.VIRIDIAN_GYM
check(vgSpin and #vgSpin >= 10, "Viridian Gym spinner tiles extracted")
local b2f = Data.field.spinners.ROCKET_HIDEOUT_B2F
local found49
for _, sp in ipairs(b2f) do
  if sp.x == 4 and sp.y == 9 then found49 = sp end
end
check(found49 and found49.moves[1].dir == "left" and found49.moves[1].count == 2,
      "Rocket Hideout B2F (4,9) arrow slides left 2")

-- ---------------------------------------------------------------- cries
local cries = Data.audio and Data.audio.cries or {}
local cryCount = 0
for _ in pairs(cries) do cryCount = cryCount + 1 end
check(cryCount >= 150, "cries rendered for the full dex (" .. cryCount .. ")")

-- ---------------------------------------------------------------- slot machine paylines
local SlotMachine = require("src.ui.SlotMachine")
local w7 = { { "7", "7", "7" }, { "7", "7", "7" }, { "7", "7", "7" } }
local win = SlotMachine.evaluate(w7, { 1, 1, 1 }, 1)
check(win and win.payout == 300 and win.symbol == "7", "7-7-7 pays 300")
local wBar = { { "X", "BAR", "Y" }, { "A", "BAR", "B" }, { "C", "BAR", "D" } }
win = SlotMachine.evaluate(wBar, { 1, 1, 1 }, 1)
check(win and win.payout == 100, "BAR middle row pays 100")
-- top row only counts from bet 2 up
local wTop = { { "X", "Y", "CHERRY" }, { "A", "B", "CHERRY" }, { "C", "D", "CHERRY" } }
check(SlotMachine.evaluate(wTop, { 1, 1, 1 }, 1) == nil, "bet 1 ignores top row")
win = SlotMachine.evaluate(wTop, { 1, 1, 1 }, 2)
check(win and win.payout == 8, "bet 2 pays the CHERRY top row (8)")
-- diagonal only counts at bet 3
local wDiag = { { "X", "Y", "FISH" }, { "A", "FISH", "B" }, { "FISH", "C", "D" } }
check(SlotMachine.evaluate(wDiag, { 1, 1, 1 }, 2) == nil, "bet 2 ignores diagonals")
win = SlotMachine.evaluate(wDiag, { 1, 1, 1 }, 3)
check(win and win.payout == 15, "bet 3 pays the FISH diagonal (15)")
-- matches are taken in pokered's line-check order, not by best payout
-- (SlotMachine_CheckForMatches: bet 2 checks the top row before the middle)
local wOrder = { { "X", "7", "FISH" }, { "Y", "7", "FISH" }, { "Z", "7", "FISH" } }
win = SlotMachine.evaluate(wOrder, { 1, 1, 1 }, 2)
check(win and win.payout == 15 and win.symbol == "FISH",
      "first matching line wins (top row checked before middle)")

-- wheel 1 stop rule (SlotMachine_StopWheel1Early): stop unless the centred
-- middle symbol is a cherry; the seven-and-bar branch is pokered's bug and
-- never stops early
local wSlip1 = { { "7", "CHERRY", "BAR", "MOUSE" }, {}, {} }
check(not SlotMachine.stopWheel1Early(wSlip1, 1, false),
      "wheel 1 slips past a centred cherry")
check(SlotMachine.stopWheel1Early(wSlip1, 2, false),
      "wheel 1 stops when the middle symbol is not a cherry")
check(not SlotMachine.stopWheel1Early(wSlip1, 2, true),
      "seven-and-bar wheel 1 never stops early (pokered bug)")

-- wheel 2 slip rule (SlotMachine_StopWheel2Early /
-- SlotMachine_FindWheel1Wheel2Matches)
local wSlip2 = { { "7", "BAR", "CHERRY", "MOUSE", "FISH" },
                 { "MOUSE", "BIRD", "FISH", "BAR", "7" }, {} }
local matched, tile = SlotMachine.findWheel1Wheel2Matches(wSlip2, 1, 1)
check(not matched and tile == "MOUSE",
      "no wheel-1/2 alignment reports wheel 2's bottom tile")
matched, tile = SlotMachine.findWheel1Wheel2Matches(wSlip2, 1, 3)
check(matched and tile == "BAR", "middle/middle BAR alignment found")
check(not SlotMachine.stopWheel2Early(wSlip2, 1, 1, false),
      "wheel 2 slips while no match is lined up")
check(SlotMachine.stopWheel2Early(wSlip2, 1, 3, false),
      "wheel 2 stops as soon as a match is lined up")
check(SlotMachine.stopWheel2Early(wSlip2, 1, 3, true),
      "seven-and-bar wheel 2 stops on a lined-up BAR")
local wCher = { { "A", "CHERRY", "B" }, { "C", "CHERRY", "D" }, {} }
check(SlotMachine.stopWheel2Early(wCher, 1, 1, false),
      "normal wheel 2 stops on a lined-up cherry")
check(not SlotMachine.stopWheel2Early(wCher, 1, 1, true),
      "seven-and-bar wheel 2 slips past a lined-up cherry")
local wBot7 = { { "A", "B", "C" }, { "7", "D", "E" }, {} }
check(SlotMachine.stopWheel2Early(wBot7, 1, 1, true),
      "seven-and-bar wheel 2 stops on a bottom 7 even with no match")

-- wheel 3 bias (SlotMachine_CheckForMatches): matches the flags forbid
-- are rolled past; allowed ones are accepted
local action = SlotMachine.checkForMatch(w7, { 1, 1, 1 }, 1, false, false)
check(action == "roll", "flags clear: wheel 3 rolls past any match")
action = SlotMachine.checkForMatch(w7, { 1, 1, 1 }, 1, true, false)
check(action == "roll", "can-win mode still rolls past a 7/BAR match")
action = SlotMachine.checkForMatch(w7, { 1, 1, 1 }, 1, false, true)
check(action == "accept", "seven-and-bar mode accepts the 7 match")
action = SlotMachine.checkForMatch(wTop, { 1, 1, 1 }, 2, true, false)
check(action == "accept", "can-win mode accepts a cherry match")
check(SlotMachine.checkForMatch(wTop, { 1, 1, 1 }, 1, true, false) == "nomatch",
      "no lined-up symbols reports nomatch")

-- reroll counter (wSlotMachineRerollCounter): a winnable no-match spin
-- rolls wheel 3 toward a match, burning one charge per symbol
local smStub = setmetatable({
  game = { data = {}, save = { coins = 10 } },
  wheels = { { "A", "A", "A" }, { "B", "B", "B" }, { "C", "C", "C" } },
  bet = 1, canWin = true, sevenBar = false,
  offset = { 1, 1, 1 }, stopping = 3, slip = { 0, 0 }, reroll = 4,
}, SlotMachine)
smStub:checkForMatches()
check(smStub.stage == "reroll" and smStub.reroll == 3,
      "winnable no-match spin rerolls wheel 3 (one charge burned)")
smStub.reroll = 1
smStub:checkForMatches()
check(smStub.stage == "message" and smStub.message == "Not this time!",
      "exhausted reroll counter gives 'Not this time!'")

-- ---------------------------------------------------------------- 12-box PC
local Boxes = require("src.pokemon.Boxes")
local bsave = { box = { { species = "PIDGEY" } } }
Boxes.ensure(bsave)
eq(#bsave.boxes[1], 1, "legacy single box migrates into box 1")
check(bsave.box == nil, "legacy box field removed")
eq(#bsave.boxes, 12, "12 boxes")
for _ = 1, Boxes.CAPACITY - 1 do
  table.insert(bsave.boxes[1], { species = "RATTATA" })
end
local usedBox = Boxes.deposit(bsave, { species = "SPEAROW" })
eq(usedBox, 2, "full box overflows into the next box")
eq(#bsave.boxes[2], 1, "overflow mon landed in box 2")

-- ---------------------------------------------------------------- Itemfinder
local ifr = ItemFx.use(Data, Game.save, "ITEMFINDER", nil, nil)
eq(ifr, "itemfinder", "ITEMFINDER asks the overworld for hidden items")

-- ---------------------------------------------------------------- Safari game
check(mapScripts.get("SAFARI_ZONE_GATE") and mapScripts.get("SAFARI_ZONE_GATE").onStep,
      "Safari gate script registered")
Game.save.safari = { balls = 30, steps = 502 }
local sb = BattleState.newWild(Game, "NIDORAN_M", 22)
sb:makeSafari(Game.save.safari)
eq(sb.safariCatchRate, Data.pokemon.NIDORAN_M.catchRate,
   "safari catch rate starts at the species rate")
sb.rng = function(a, b) return b end -- deterministic max rolls
sb:safariAction("rock")
eq(sb.safariCatchRate, math.min(255, Data.pokemon.NIDORAN_M.catchRate * 2),
   "ROCK doubles the catch rate")
eq(sb.escapeFactor, 5, "ROCK raises the escape factor")
eq(sb.baitFactor, 0, "ROCK zeroes the bait factor")
sb:safariAction("bait")
eq(sb.safariCatchRate, math.floor(math.min(255, Data.pokemon.NIDORAN_M.catchRate * 2) / 2),
   "BAIT halves the catch rate")
eq(sb.baitFactor, 5, "BAIT raises the bait factor")
eq(sb.escapeFactor, 0, "BAIT zeroes the escape factor")

-- a full safari encounter driven to completion (mashing A throws balls)
Game.save.safari = { balls = 30, steps = 502 }
local sfin = nil
local sb2 = BattleState.newWild(Game, "CATERPIE", 5)
sb2:makeSafari(Game.save.safari)
sb2.onFinish = function(r) sfin = r end
StateStack:push(sb2)
guard = 0
while sfin == nil and guard < 20000 do
  guard = guard + 1
  Input:keypressed("z")
  Input:step()
  Input.pressed = { a = true }
  StateStack:update(1 / 60)
  Input:keyreleased("z")
end
check(sfin == "caught" or sfin == "run",
      "safari battle runs to completion (result: " .. tostring(sfin) .. ")")
check(Game.save.safari.balls < 30, "safari balls consumed")
Game.save.safari = nil

-- ---------------------------------------------------------------- new extracted systems
check(Data.field.cardKeyDoors and Data.field.cardKeyDoors.doorTiles[1] == 24,
      "card key door tiles extracted ($18)")
eq(#Data.field.badgeGates.ROUTE_23.guards, 7, "seven Route 23 badge guards")
eq(Data.field.badgeGates.ROUTE_23.guards[1].badge, "EARTHBADGE",
   "first Route 23 guard checks the EARTHBADGE")
-- Route22Gate_Script: every frame Y < 4 -> wLastMap = ROUTE_23, else
-- ROUTE_22, so the north LAST_MAP warps leave onto Route 23
do
  local OW = require("src.world.OverworldController")
  local FieldDefaults = require("src.world.FieldDefaults")
  local rewrite = FieldDefaults.field(Data, "lastMapRewrites").ROUTE_22_GATE
  local function outdoorAt(cellY)
    return OW.rewrittenLastMap(rewrite, 0, cellY)
  end
  eq(outdoorAt(0), "ROUTE_23", "Route22Gate Y=0 -> Route 23")
  eq(outdoorAt(3), "ROUTE_23", "Route22Gate Y=3 -> Route 23")
  eq(outdoorAt(4), "ROUTE_22", "Route22Gate Y=4 -> Route 22")
  eq(outdoorAt(7), "ROUTE_22", "Route22Gate Y=7 -> Route 22")
  local north = Data.maps.ROUTE_22_GATE.warps[3]
  local m, x, y = Warp.destination(Data, north,
    { id = outdoorAt(0), x = 0, y = 0 })
  eq(m, "ROUTE_23", "north gate LAST_MAP with Y rewrite lands on Route 23")
  eq(x, 7, "north gate lands on Route 23 south warp x")
  eq(y, 139, "north gate lands on Route 23 south warp y")
  local south = Data.maps.ROUTE_22_GATE.warps[1]
  m, x, y = Warp.destination(Data, south,
    { id = outdoorAt(7), x = 0, y = 0 })
  eq(m, "ROUTE_22", "south gate LAST_MAP with Y rewrite lands on Route 22")
  eq(x, 8, "south gate lands on Route 22 gate warp x")
  eq(y, 5, "south gate lands on Route 22 gate warp y")
end
-- UndergroundPathRoute{5,6,7,8}_Script force wLastMap to their own route on
-- map load, so crossing the tunnel and taking the far building's LAST_MAP exit
-- lands you on that route rather than the one you entered from (issue #1)
do
  local OW = require("src.world.OverworldController")
  local FieldDefaults = require("src.world.FieldDefaults")
  local rewrites = FieldDefaults.field(Data, "lastMapRewrites")
  local cases = {
    { map = "UNDERGROUND_PATH_ROUTE_5", route = "ROUTE_5", x = 17, y = 27 },
    { map = "UNDERGROUND_PATH_ROUTE_6", route = "ROUTE_6", x = 17, y = 13 },
    { map = "UNDERGROUND_PATH_ROUTE_7", route = "ROUTE_7", x = 5, y = 13 },
    { map = "UNDERGROUND_PATH_ROUTE_8", route = "ROUTE_8", x = 13, y = 3 },
    -- DiglettsCaveRoute{2,11}_Script: same pattern for the cave's two ends
    { map = "DIGLETTS_CAVE_ROUTE_2", route = "ROUTE_2", x = 12, y = 9 },
    { map = "DIGLETTS_CAVE_ROUTE_11", route = "ROUTE_11", x = 4, y = 5 },
  }
  for _, c in ipairs(cases) do
    local rewrite = rewrites[c.map]
    check(rewrite ~= nil, c.map .. " rewrites wLastMap to its own route")
    eq(OW.rewrittenLastMap(rewrite, 0, 0), c.route, c.map .. " -> " .. c.route)
    local door = Data.maps[c.map].warps[1]
    local m, x, y = Warp.destination(Data, door, { id = c.route, x = 0, y = 0 })
    eq(m, c.route, c.map .. " door exits onto " .. c.route)
    eq(x, c.x, c.map .. " door lands on the " .. c.route .. " entrance x")
    eq(y, c.y, c.map .. " door lands on the " .. c.route .. " entrance y")
  end
end
eq(Data.field.forcedMovement.slopeMaps[1], "ROUTE_17", "Cycling Road slope map")
check(Data.field.seafoam.SEAFOAM_ISLANDS_B3F.currents[1].moves[1] ~= nil,
      "Seafoam B3F current movement extracted")
eq(Data.field.gameCornerPoster.closedBlock, 42, "poster wall block $2a")
eq(Data.field.presetNames.player[1], "RED", "preset player names")
eq(Data.field.darkMaps.maps[1], "ROCK_TUNNEL_1F", "Rock Tunnel is dark")
check(Data.field.hiddenExtras.trashCans.adjacent[0][1] == 1,
      "trash can adjacency table extracted")
check(#Data.field.hiddenExtras.trashCans.cans == 15, "15 Vermilion trash cans")
local tf = io.open(Data.field.title.logo.path, "rb")
check(tf ~= nil, "title logo asset exists")
if tf then tf:close() end
check(Data.moves.POUND.anim and Data.moves.POUND.anim.sound == "Pound",
      "POUND plays its own sound")
local animCount = 0
for _, mv in pairs(Data.moves) do
  if mv.anim and mv.anim.sound then animCount = animCount + 1 end
end
eq(animCount, 165, "every move has an animation sound")
check(Data.moves.EARTHQUAKE.anim.shake == true, "EARTHQUAKE shakes the screen")

-- ---------------------------------------------------------------- catch wobbles
local Catching = require("src.battle.Catching")
local wobbleMon = { status = nil, stats = { hp = 100 }, hp = 100 }
local caught, shakes = Catching.attempt("POKE_BALL", wobbleMon, { catchRate = 3 },
                                        function(a, b) return b end) -- max rolls
check(caught == false and shakes == 0,
      "hopeless throw misses with 0 wobbles (Mewtwo-style)")
caught = Catching.attempt("MASTER_BALL", wobbleMon, { catchRate = 3 },
                          function(a, b) return b end)
check(caught == true, "MASTER BALL never fails")

-- ---------------------------------------------------------------- battle mechanics parity
-- scripted-rng probes of the move pipeline (trapping counter, raw-damage
-- recoil/drain, the 1/256 status-move miss, EXP.ALL's second pass)
do
  local Damage = require("src.battle.Damage")
  local function mkseq(vals) -- scripted rng: pops vals, then max rolls
    local i = 0
    return function(a, b)
      i = i + 1
      return vals[i] ~= nil and vals[i] or b
    end
  end
  local savedParty = Game.save.party

  -- #1: trapping moves total 2-5 attacks (counter 1-4 continuations)
  do
    Game.save.party = { Pokemon.new(Data, "BULBASAUR", 10) }
    local tb = BattleState.newWild(Game, "RATTATA", 5)
    -- rng order: accuracy, crit, damage random, trapping counter
    tb.rng = mkseq({ 0, 255, 255, 0 }) -- counter roll 0 -> 1 continuation
    tb:performMove(tb.player, tb.enemy, { id = "WRAP", pp = 10 })
    eq(tb.player.trappingTurns, 1,
       "trapping roll 0 gives 1 continuation (2 attacks total)")
    local tb2 = BattleState.newWild(Game, "RATTATA", 5)
    tb2.rng = mkseq({ 0, 255, 255, 7 }) -- counter roll 7 -> 4 continuations
    tb2:performMove(tb2.player, tb2.enemy, { id = "WRAP", pp = 10 })
    eq(tb2.player.trappingTurns, 4,
       "trapping roll 7 gives 4 continuations (5 attacks total)")
    -- the victim stays held through the final hit; the bit clears only
    -- at end of turn (CheckNumAttacksLeft)
    tb:continueTrapping(tb.player, tb.enemy)
    eq(tb.player.trappingTurns, 0, "final continuation leaves the counter at 0")
    check(tb:lockedAction(tb.enemy) ~= nil
          and tb:lockedAction(tb.enemy).special == "bound",
          "victim is still held while the counter sits at 0")
    tb:endOfTurn()
    eq(tb.player.trappingTurns, nil, "end of turn releases the trap")
    check(tb:lockedAction(tb.enemy) == nil, "victim is free after the release")
  end

  -- #2: recoil and drain use the RAW computed damage, not the HP-capped
  -- amount dealt
  do
    Game.save.party = { Pokemon.new(Data, "BULBASAUR", 20) }
    local rb = BattleState.newWild(Game, "RATTATA", 3)
    rb.enemy.mon.hp = 1 -- overkill target
    local raw = Damage.compute(rb.ruleset, rb.player, rb.enemy,
                               Data.moves.TAKE_DOWN, { rng = mkseq({ 255, 255 }) })
    check(raw >= 8, "raw TAKE DOWN damage is meaningful (" .. raw .. ")")
    rb.rng = mkseq({ 0, 255, 255 })
    local hpBefore = rb.player.mon.hp
    rb:performMove(rb.player, rb.enemy, { id = "TAKE_DOWN", pp = 10 })
    eq(hpBefore - rb.player.mon.hp, math.floor(raw / 4),
       "recoil is raw damage / 4 even when only 1 HP was dealt")

    local db = BattleState.newWild(Game, "RATTATA", 3)
    db.enemy.mon.hp = 1
    db.player.mon.hp = 1
    local rawD = Damage.compute(db.ruleset, db.player, db.enemy,
                                Data.moves.MEGA_DRAIN, { rng = mkseq({ 255, 255 }) })
    check(rawD >= 4, "raw MEGA DRAIN damage is meaningful (" .. rawD .. ")")
    db.rng = mkseq({ 0, 255, 255 })
    db:performMove(db.player, db.enemy, { id = "MEGA_DRAIN", pp = 10 })
    eq(db.player.mon.hp - 1, math.floor(rawD / 2),
       "drain heals raw damage / 2 even when only 1 HP was dealt")
    eq(db.lastDamage, math.floor(rawD / 2),
       "drain halves wDamage in place (Counter would see the half)")
  end

  -- #8: 100%-accuracy status moves still miss on the 255 roll
  do
    Game.save.party = { Pokemon.new(Data, "BULBASAUR", 10) }
    local ab = BattleState.newWild(Game, "RATTATA", 5)
    ab.rng = mkseq({ 255 }) -- the 1/256 miss
    ab:performMove(ab.player, ab.enemy, { id = "THUNDER_WAVE", pp = 10 })
    eq(ab.enemy.mon.status, nil, "THUNDER WAVE misses on the 255 roll")
    local function hasAnim(b)
      for _, r in ipairs(b.queue) do if r.anim then return true end end
      return false
    end
    check(not hasAnim(ab), "a missed THUNDER WAVE plays no move animation")
    ab.rng = mkseq({ 254 })
    ab:performMove(ab.player, ab.enemy, { id = "THUNDER_WAVE", pp = 10 })
    eq(ab.enemy.mon.status, "PAR", "THUNDER WAVE lands on the 254 roll")
    -- self-targeting status moves never roll accuracy at all
    local sbst = BattleState.newWild(Game, "RATTATA", 5)
    sbst.rng = function() error("self move must not roll accuracy") end
    sbst:performMove(sbst.player, sbst.enemy, { id = "SHARPEN", pp = 10 })
    eq(sbst.player.stages.attack, 1, "SHARPEN skips the accuracy roll")
  end

  -- HandleIfPlayerMoveMissed: skip PlayMoveAnimation on a miss
  -- (unless EXPLODE_EFFECT)
  do
    Game.save.party = { Pokemon.new(Data, "BULBASAUR", 20) }
    local function hasAnim(b)
      for _, r in ipairs(b.queue) do if r.anim then return true end end
      return false
    end
    local function sawMiss(b)
      for _, r in ipairs(b.queue) do
        if r.text and r.text:find("attack missed!", 1, true) then return true end
      end
      return false
    end
    local mb = BattleState.newWild(Game, "RATTATA", 5)
    mb.rng = function(a, b) return b end -- accuracy 255: miss
    mb:performMove(mb.player, mb.enemy, { id = "TACKLE", pp = 10 })
    check(sawMiss(mb), "TACKLE miss prints AttackMissedText")
    check(not hasAnim(mb), "a missed TACKLE plays no move animation")
    eq(mb.enemy.mon.hp, mb.enemy.mon.stats.hp, "a missed TACKLE deals no damage")

    local hb = BattleState.newWild(Game, "RATTATA", 5)
    hb.rng = function(a, b) return a end -- hit
    hb:performMove(hb.player, hb.enemy, { id = "TACKLE", pp = 10 })
    check(hasAnim(hb), "a landing TACKLE still queues its move animation")
  end

  -- #14: EXP.ALL second pass inherits the participant divisor and skips
  -- fainted mons
  do
    local Experience = require("src.battle.Experience")
    local mon1 = Pokemon.new(Data, "BULBASAUR", 30)
    local mon2 = Pokemon.new(Data, "PIDGEY", 30)
    mon2.hp = 0
    Game.save.party = { mon1, mon2 }
    Game.save.inventory.EXP_ALL = 1
    local xb = BattleState.newWild(Game, "RATTATA", 10)
    xb.participants = { [mon1] = true }
    local exp1, exp2 = mon1.exp, mon2.exp
    xb:enemyMonFainted()
    local rat = Data.pokemon.RATTATA
    eq(mon1.exp - exp1,
       Experience.gainFor(rat, 10, false, 2, false)
       + Experience.gainFor(rat, 10, false, 4, false),
       "EXP.ALL: participant gets the half share plus the party share")
    eq(mon2.exp - exp2, 0, "EXP.ALL second pass skips fainted mons")
    Game.save.inventory.EXP_ALL = nil
  end

  Game.save.party = savedParty
end

-- ---------------------------------------------------------------- battle text/presentation parity
-- "Enemy " prefix, send-out variants, HP-bar drain, catch dex flow,
-- exact pokered strings (all verified against pret/pokered text files)
do
  local savedParty = Game.save.party
  local function mkseq(vals)
    local i = 0
    return function(a, b)
      i = i + 1
      return vals[i] ~= nil and vals[i] or b
    end
  end
  local function hasText(b, s)
    for _, it in ipairs(b.queue) do
      if it.text and it.text:find(s, 1, true) then return true end
    end
    return false
  end
  local function hasDrain(b)
    for _, it in ipairs(b.queue) do
      if it.drain then return true end
    end
    return false
  end

  -- the enemy-name prefix (<USER>/<TARGET> macros print "Enemy ")
  Game.save.party = { Pokemon.new(Data, "BULBASAUR", 10) }
  local pb = BattleState.newWild(Game, "RATTATA", 5)
  pb.rng = mkseq({ 0, 255, 255 })
  pb:performMove(pb.enemy, pb.player, { id = "TACKLE", pp = 10 })
  check(hasText(pb, "Enemy RATTATA\nused TACKLE!"),
        "enemy move announcement carries the Enemy prefix")
  pb.rng = mkseq({ 0, 255, 255 })
  pb:performMove(pb.player, pb.enemy, { id = "TACKLE", pp = 10 })
  check(hasText(pb, "BULBASAUR\nused TACKLE!")
        and not hasText(pb, "Enemy BULBASAUR"),
        "player move announcement has no prefix")
  check(hasDrain(pb), "damage queues an HP-bar drain wait")
  pb.enemy.mon.hp = 0
  pb:onFaint(pb.enemy)
  check(hasText(pb, "Enemy RATTATA\nfainted!"),
        "_EnemyMonFaintedText has the Enemy prefix")

  -- pre-built Status messages get the prefix spliced in
  local MoveFx = require("src.battle.MoveEffects")
  local parMsgs = MoveFx.primary.PARALYZE_EFFECT(
    { rng = mkseq({}) }, pb.player, pb.enemy, Data.moves.THUNDER_WAVE)
  eq(parMsgs[1], "Enemy RATTATA's\nparalyzed! It may\nnot attack!",
     "_ParalyzedMayNotAttackText wording + prefix")
  local failMsgs = MoveFx.primary.PARALYZE_EFFECT(
    { rng = mkseq({}) }, pb.player, pb.enemy, Data.moves.THUNDER_WAVE)
  eq(failMsgs[1], "But, it failed!", "_ButItFailedText has the comma")

  -- send-out shout buckets (PrintSendOutMonMessage thresholds)
  pb.enemy.mon.stats = { hp = 20 }
  pb.enemy.mon.hp = 20
  eq(pb:sendOutText("PIKA"), "Go! PIKA!", "send-out at full HP")
  pb.enemy.mon.hp = 13 -- 65%
  eq(pb:sendOutText("PIKA"), "Do it! PIKA!", "send-out at 40-69%")
  pb.enemy.mon.hp = 3 -- 15%
  eq(pb:sendOutText("PIKA"), "Get'm! PIKA!", "send-out at 10-39%")
  pb.enemy.mon.hp = 1 -- 5%
  eq(pb:sendOutText("PIKA"), "The enemy's weak!\nGet'm! PIKA!",
     "send-out below 10%")

  -- HP-bar drain converges at UpdateHPBar's pixel pace (maxHP/96/frame)
  local db = BattleState.newWild(Game, "RATTATA", 5)
  local maxHP = db.enemy.mon.stats.hp
  db.enemy.mon.hp = math.max(0, db.enemy.mon.hp - 5)
  local frames = 0
  while db:stepHPDrain() and frames < 2000 do frames = frames + 1 end
  eq(db.enemy.shownHP, db.enemy.mon.hp, "drain settles on the true HP")
  local expect = math.ceil(5 / (maxHP / 96))
  check(math.abs(frames - expect) <= 1,
        ("drain speed ~2 frames per bar pixel (%d ~ %d)"):format(frames, expect))

  -- multi-hit count text: player vs enemy variants, always plural
  Game.save.party = { Pokemon.new(Data, "BULBASAUR", 10) }
  local mh = BattleState.newWild(Game, "SNORLAX", 30)
  mh.rng = mkseq({ 7, 0, 255, 255 }) -- 5 hits, hit, no crit, max roll
  mh:performMove(mh.player, mh.enemy, { id = "DOUBLESLAP", pp = 10 })
  check(hasText(mh, "Hit the enemy\n5 times!"),
        "player multi-hit uses _MultiHitText")
  Game.save.party = { Pokemon.new(Data, "SNORLAX", 30) }
  local mh2 = BattleState.newWild(Game, "RATTATA", 5)
  mh2.rng = mkseq({ 7, 0, 255, 255 })
  mh2:performMove(mh2.enemy, mh2.player, { id = "DOUBLESLAP", pp = 10 })
  check(hasText(mh2, "Hit 5 times!"),
        "enemy multi-hit uses _HitXTimesText (plural, no '(s)')")

  -- GainedText parity (experience.asm:342-354 + text_2.asm:1207-1226):
  -- the amount from wExpAmountGained, "a boosted" for traded mons,
  -- "with EXP.ALL," on the second pass -- and no invented summary
  local Experience = require("src.battle.Experience")
  Game.save.party = { Pokemon.new(Data, "BULBASAUR", 30) }
  local eb = BattleState.newWild(Game, "RATTATA", 10)
  eb.participants = { [Game.save.party[1]] = true }
  eb:enemyMonFainted()
  local gain = Experience.gainFor(Data.pokemon.RATTATA, 10, false, 1, false)
  check(hasText(eb, ("BULBASAUR gained\n%d EXP. Points!"):format(gain)),
        "_GainedText + _ExpPointsText show the amount")

  Game.save.party = { Pokemon.new(Data, "BULBASAUR", 30) }
  Game.save.party[1].traded = true
  local eb2 = BattleState.newWild(Game, "RATTATA", 10)
  eb2.participants = { [Game.save.party[1]] = true }
  eb2:enemyMonFainted()
  local boosted = Experience.gainFor(Data.pokemon.RATTATA, 10, false, 1, true)
  check(hasText(eb2, ("BULBASAUR gained\na boosted\n%d EXP. Points!"):format(boosted)),
        "_BoostedText tail for traded mons")

  Game.save.party = { Pokemon.new(Data, "BULBASAUR", 30) }
  Game.save.inventory.EXP_ALL = 1
  local eb3 = BattleState.newWild(Game, "RATTATA", 10)
  eb3.participants = { [Game.save.party[1]] = true }
  eb3:enemyMonFainted()
  local share = Experience.gainFor(Data.pokemon.RATTATA, 10, false, 2, false)
  check(hasText(eb3, ("BULBASAUR gained\nwith EXP.ALL,\n%d EXP. Points!"):format(share)),
        "_WithExpAllText tail on the EXP.ALL pass")
  check(not hasText(eb3, "divided"), "no invented EXP.ALL summary line")
  Game.save.inventory.EXP_ALL = nil

  -- trainer next-mon send-out (EnemySendOutFirstMon, core.asm:1413-1435):
  -- the announcement prints while the enemy pic + HUD are hidden, then
  -- the pic grows out of the ball (AnimateSendingOutMon, core.asm:6801)
  -- and the cry follows; no POOF on the enemy path
  Game.save.party = { Pokemon.new(Data, "BULBASAUR", 30) }
  local nb = BattleState.newTrainer(Game, "OPP_YOUNGSTER", 1)
  nb.enemy.mon.hp = 0
  nb:enemyMonFainted()
  local pumps = 0
  while #nb.queue > 0 and not nb.enemySendingOut and pumps < 200 do
    pumps = pumps + 1
    local item = table.remove(nb.queue, 1)
    if item.fn then
      nb.nextInsert = 0 -- updateQueue resets the insert cursor per fn
      item.fn()
    end
  end
  check(nb.enemySendingOut, "next enemy mon stays hidden while announced")
  check(nb.enemy.mon.species == "EKANS", "the swap loaded the next party mon")
  check(nb.queue[1] and nb.queue[1].text
        and nb.queue[1].text:find("sent\nout EKANS!", 1, true),
        "TrainerSentOutText queued before the reveal")
  check(not (nb.queue[1] and nb.queue[1].anim)
        and not (nb.queue[2] and nb.queue[2].anim),
        "no POOF row on the enemy send-out path")
  check(nb.queue[2] and nb.queue[2].fn, "the reveal act follows the text")
  table.remove(nb.queue, 1) -- the sent-out text
  local reveal = table.remove(nb.queue, 1)
  nb.nextInsert = 0
  reveal.fn()
  check(nb.enemySendingOut == false, "pic + HUD return after the text")
  check(nb.growIn and nb.growIn.battler == nb.enemy,
        "the reveal starts the AnimateSendingOutMon grow-in")
  eq(nb:growInScale(nb.enemy), 0, "grow-in opens with the ball beat")
  check(nb.queue[1] and nb.queue[1].wait == 12, "a queued hold covers the grow")
  for _ = 1, 3 do nb:updateFx() end
  eq(nb:growInScale(nb.enemy), 3 / 7, "3x3 stage after the ball beat")
  for _ = 1, 4 do nb:updateFx() end
  eq(nb:growInScale(nb.enemy), 5 / 7, "5x5 stage")
  for _ = 1, 5 do nb:updateFx() end
  check(nb.growIn == nil, "grow-in ends at full size after 12 frames")
  table.remove(nb.queue, 1) -- the hold
  local SoundMod = require("src.core.Sound")
  local oldCry, criedSpecies = SoundMod.playCry, nil
  SoundMod.playCry = function(_, species) criedSpecies = species end
  local cryAct = table.remove(nb.queue, 1)
  nb.nextInsert = 0
  cryAct.fn()
  SoundMod.playCry = oldCry
  eq(criedSpecies, "EKANS", "the new mon's cry plays after the grow")

  -- first-catch flow: new dex data text + registration; box transfer text
  Game.save.party = { Pokemon.new(Data, "BULBASAUR", 10) }
  Game.save.pokedex.owned.EKANS = nil
  local cb = BattleState.newWild(Game, "EKANS", 5)
  cb:storeCaughtMon()
  check(hasText(cb, "New POKéDEX data\nwill be added for\nEKANS!"),
        "_ItemUseBallText06 on a first catch")
  check(Game.save.pokedex.owned.EKANS == true, "species registered as owned")
  eq(cb.result, "caught", "catch resolves the battle")
  eq(#Game.save.party, 2, "caught mon joined the party")

  Game.save.party = {}
  for _ = 1, 6 do table.insert(Game.save.party, Pokemon.new(Data, "RATTATA", 5)) end
  local cb2 = BattleState.newWild(Game, "EKANS", 5)
  cb2:storeCaughtMon()
  check(hasText(cb2, "EKANS was\ntransferred to\nsomeone's PC!"),
        "_ItemUseBallText08 before meeting Bill")
  check(not hasText(cb2, "New POKéDEX data"),
        "no dex page for an already-owned species")
  Game.save.flags.EVENT_MET_BILL = true
  local cb3 = BattleState.newWild(Game, "EKANS", 5)
  cb3:storeCaughtMon()
  check(hasText(cb3, "EKANS was\ntransferred to\nBILL's PC!"),
        "_ItemUseBallText07 after meeting Bill")
  Game.save.flags.EVENT_MET_BILL = nil

  -- trainer defeat wording (_TrainerDefeatedText)
  Game.save.party = { Pokemon.new(Data, "BULBASAUR", 30) }
  local tb = BattleState.newTrainer(Game, "OPP_YOUNGSTER", 1)
  tb.enemyIndex = #tb.enemyParty
  tb.enemy = { mon = tb.enemyParty[#tb.enemyParty], def = tb.enemy.def,
               name = tb.enemy.name, isPlayer = false }
  tb.enemy.mon.hp = 0
  tb:enemyMonFainted()
  check(hasText(tb, ("%s defeated\n%s!"):format(Game.save.player.name,
                                                tb.trainer.name)),
        "trainer defeat uses '<PLAYER> defeated <TRAINER>!'")

  -- pret GetTrainerName_: rival classes show wRivalName, not "RIVAL1"
  do
    local savedRival = Game.save.player.rival
    Game.save.player.rival = "GARY"
    Game.save.party = { Pokemon.new(Data, "BULBASAUR", 30) }
    local rb = BattleState.newTrainer(Game, "OPP_RIVAL1", 1)
    eq(rb.trainer.name, "GARY", "rival battle uses saved rival name")
    check(rb.introText:find("GARY", 1, true),
          "rival intro wants-to-fight uses rival name")
    check(Data.trainers.OPP_RIVAL1.name == "RIVAL1",
          "shared trainer data keeps the RIVAL1 placeholder")
    Game.save.player.rival = savedRival
  end

  -- PartyMenu onCancel fires when backing out without a pick
  do
    local PartyMenu = require("src.ui.PartyMenu")
    local cancelled = false
    local pm = PartyMenu.new(Game, { pickOnly = true,
                                     onCancel = function() cancelled = true end })
    StateStack:push(pm)
    Input.pressed = { b = true }
    StateStack:update(1 / 60)
    Input.pressed = {}
    check(cancelled, "PartyMenu onCancel fires on B")
  end

  Game.save.party = savedParty
end

-- ---------------------------------------------------------------- trainer class AI
local aiClasses = require("data.scripts.ai_classes")
check(aiClasses.OPP_BROCK.onStatus and aiClasses.OPP_BROCK.item == "FULL_HEAL",
      "Brock full-heals status")
local TrainerAI = require("src.battle.TrainerAI")
local stubEnemy = { mon = { status = "SLP", hp = 50, stats = { hp = 50 } },
                    stages = {}, name = "ONIX" }
local stubBattleAI = { kind = "trainer", trainer = { id = "OPP_BROCK", name = "BROCK" },
                       enemy = stubEnemy, aiUses = 5, rng = function() return 0 end,
                       data = Data }
local act = TrainerAI.classAction(stubBattleAI)
check(act and act.special == "aiItem" and act.item == "FULL_HEAL",
      "Brock's AI reaches for a FULL HEAL")
local msgs = TrainerAI.useItem(stubBattleAI, "FULL_HEAL")
check(stubEnemy.mon.status == nil and #msgs >= 1, "AI FULL HEAL cures the status")

-- AI layer 1: zero-power status-ailment moves vs an already-statused
-- player are heavily discouraged (pokered adds +5 to the score); the
-- faithful min-score pick then never selects them over a better move
-- (trainer_ai.asm min-score selection, not the old weighted-random)
do
local aiMon1 = { curMoves = { { id = "TOXIC", pp = 10 }, { id = "TACKLE", pp = 10 } } }
local aiBattle1 = { enemyAIMods = { 1 }, data = Data,
                    player = { mon = { status = "PAR" }, curTypes = { "NORMAL" } } }
-- scores land at {15, 10}: TACKLE is the sole minimum, chosen for any roll
eq(TrainerAI.chooseMove(aiMon1, function(a, b) return a end, aiBattle1).id,
   "TACKLE", "discouraged status move is never chosen over a better move")
eq(TrainerAI.chooseMove(aiMon1, function(a, b) return b end, aiBattle1).id,
   "TACKLE", "status move heavily discouraged when the player is statused")

-- AI layer 2: stat-modifying effects encouraged only on the SECOND
-- selection per enemy mon (wAILayer2Encouragement == 1)
local aiMon2 = { curMoves = { { id = "GROWL", pp = 10 }, { id = "TACKLE", pp = 10 } } }
local aiBattle2 = { enemyAIMods = { 2 }, data = Data,
                    player = { mon = {}, curTypes = { "NORMAL" } } }
local pick11 = function(a, b) return math.min(b, 11) end
eq(TrainerAI.chooseMove(aiMon2, pick11, aiBattle2).id, "TACKLE",
   "no layer-2 encouragement on the first selection")
eq(TrainerAI.chooseMove(aiMon2, pick11, aiBattle2).id, "GROWL",
   "stat moves encouraged on the second selection")
eq(TrainerAI.chooseMove(aiMon2, pick11, aiBattle2).id, "TACKLE",
   "the encouragement expires after the second selection")

-- AI layer 3: single-row type lookup covers non-damaging moves too
-- (THUNDER_WAVE vs a Water-type reads the ELECTRIC->WATER row)
local aiMon3 = { curMoves = { { id = "THUNDER_WAVE", pp = 10 },
                              { id = "TACKLE", pp = 10 } } }
local aiBattle3 = { enemyAIMods = { 3 }, data = Data,
                    player = { mon = {}, curTypes = { "WATER" } } }
eq(TrainerAI.chooseMove(aiMon3, function(a, b) return math.min(b, 30) end, aiBattle3).id,
   "THUNDER_WAVE", "layer 3 encourages a super-effective status move")
end

-- ---------------------------------------------------------------- exp split / traded boost
local Experience = require("src.battle.Experience")
local rattataDef = Data.pokemon.RATTATA
local soloExp = Experience.gainFor(rattataDef, 10, false, 1, false)
local splitExp = Experience.gainFor(rattataDef, 10, false, 2, false)
local tradedExp = Experience.gainFor(rattataDef, 10, false, 1, true)
eq(splitExp, math.floor(soloExp / 2), "exp splits between two participants")
eq(tradedExp, math.floor(soloExp * 3 / 2), "traded mons earn x1.5 exp")

-- ---------------------------------------------------------------- lockstep tie inversion
local TurnOrder = require("src.battle.TurnOrder")
local fast = { curStats = { speed = 50 }, stages = {}, mon = { status = nil } }
local fast2 = { curStats = { speed = 50 }, stages = {}, mon = { status = nil } }
local tieRng = function() return 0 end -- always "a first"
check(TurnOrder.firstMover(fast, nil, fast2, nil, tieRng) == true,
      "speed tie: roll 0 means a moves first")
check(TurnOrder.firstMover(fast, nil, fast2, nil, tieRng, true) == false,
      "the link guest inverts the shared tie roll")

-- ---------------------------------------------------------------- naming screen
local NamingScreen = require("src.ui.NamingScreen")
local named = nil
local ns = NamingScreen.new(Game, { title = "TEST?", maxLen = 7, presets = { "RED" },
                                    onDone = function(n) named = n end })
StateStack:push(ns)
guard = 0
while named == nil and guard < 2000 do
  guard = guard + 1
  Input:keypressed("z")
  Input:step()
  Input.pressed = { a = true }
  StateStack:update(1 / 60)
  Input:keyreleased("z")
end
check(named ~= nil and #named > 0, "naming screen produces a name (" .. tostring(named) .. ")")

-- ---------------------------------------------------------------- town map / credits / emotes / slots art
local tmap = Data.field.townMap
check(tmap and tmap.locations.PALLET_TOWN.x == 2 and tmap.locations.PALLET_TOWN.y == 11,
      "Pallet Town at (2,11) on the town map")
check(tmap.locations.SILPH_CO_11F ~= nil, "indoor maps resolve to town map entries")
eq(#Data.field.credits.screens, 35, "35 credit screens extracted")
eq(Data.field.credits.screens[2].lines[1].text, "DIRECTOR", "credits screen 2 is DIRECTOR")
eq(Data.field.credits.screens[2].lines[2].text, "SATOSHI TAJIRI", "credited to Satoshi Tajiri")
check(#Data.field.credits.mons == 15, "15 credits mons")
local eb = Data.field.emotionBubbles
check(eb and eb.bubbles[1].name == "EXCLAMATION_BUBBLE", "exclamation bubble crop first")
local ef = io.open(eb.path, "rb")
check(ef ~= nil, "emotes sheet exists") if ef then ef:close() end
local ss = Data.field.slotSymbols
check(ss and ss.symbols["7"] and ss.symbols.BAR and ss.symbols.CHERRY,
      "slot symbol crops extracted")
local sf = io.open(ss.sheet, "rb")
check(sf ~= nil, "slot symbols sheet exists") if sf then sf:close() end
eq(Data.field.oldManBattle.species, "WEEDLE", "old man demos a Weedle")
eq(Data.field.oldManBattle.level, 5, "at level 5")
eq(Data.field.pcItemCap, 50, "PC item capacity is 50")
eq(Data.field.coinPurchases[1].coins, 50, "the clerk sells 50 coins")
eq(#Data.field.coinPurchases, 1, "and only 50 (no 500-coin purchase exists)")

-- ---------------------------------------------------------------- battle animations
check(Data.battle_anims ~= nil, "battle_anims data loads")
local animMoves = 0
for _ in pairs(Data.battle_anims.moveAnims) do animMoves = animMoves + 1 end
eq(animMoves, 202, "all 165 moves + 37 misc anims have sequences")
check(Data.battle_anims.moveAnims.POOF_ANIM ~= nil, "send-out POOF anim extracted")
check(Data.battle_anims.moveAnims.TOSS_ANIM ~= nil, "ball TOSS anim extracted")
local AnimPlayer = require("src.battle.AnimPlayer")
local ap = AnimPlayer.new(Data.battle_anims)
ap:start("POUND", true)
local frames = 0
while not ap:isDone() and frames < 300 do
  frames = frames + 1
  ap:update()
end
check(ap:isDone() and frames > 4, "POUND's animation plays (" .. frames .. " frames)")
ap:start("THUNDERBOLT", false)
frames = 0
while not ap:isDone() and frames < 600 do
  frames = frames + 1
  ap:update()
end
check(ap:isDone(), "THUNDERBOLT plays mirrored for the enemy")

-- ---------------------------------------------------------------- tile-pair collisions
check(Data.field.tilePairs and #Data.field.tilePairs.land > 0,
      "tile-pair (elevation) collisions extracted")
local hasForestPair = false
for _, p in ipairs(Data.field.tilePairs.land) do
  if p.tileset == "FOREST" and p.a == 0x30 and p.b == 0x2E then hasForestPair = true end
end
check(hasForestPair, "Viridian Forest ledge pair $30/$2E present")
local Collision = require("src.world.Collision")
Collision.load(Data)
-- a fake forest map: standing on $30, moving onto $2E must be blocked
local fakeForest = {
  def = { tileset = "FOREST" },
  inBounds = function() return true end,
  isWalkableCell = function() return true end,
  isWaterCell = function() return false end,
  cellTile = function(_, cx, cy) return cy == 0 and 0x30 or 0x2E end,
}
local mover = { cellX = 0, cellY = 0, surfing = false }
local ok2 = Collision.canMove(fakeForest, { mover }, mover, "down")
check(ok2 == false, "tile-pair blocks crossing a forest elevation edge")

-- ---------------------------------------------------------------- START menu gating
local StartMenu = require("src.ui.StartMenu")
local blankSave = require("src.core.SaveData").newGame()
local gs = { data = Data, save = blankSave, overworld = nil }
local menu = StartMenu.new(gs)
local labels = {}
for _, it in ipairs(menu.items) do labels[it.label] = true end
check(not labels["POKéDEX"], "POKéDEX hidden before the dex is earned")
check(labels["POKéMON"], "POKéMON always listed (draw_start_menu.asm; empty party no-ops)")
check(labels["ITEM"] and labels["SAVE"], "ITEM and SAVE always present")
blankSave.flags.EVENT_GOT_POKEDEX = true
table.insert(blankSave.party, Pokemon.new(Data, "PIKACHU", 5))
local menu2 = StartMenu.new(gs)
local labels2 = {}
for _, it in ipairs(menu2.items) do labels2[it.label] = true end
check(labels2["POKéDEX"] and labels2["POKéMON"],
      "POKéDEX and POKéMON appear once earned")

-- ---------------------------------------------------------------- old man catch demo
local demoBattle = BattleState.newWild(Game, "WEEDLE", 5)
demoBattle:makeOldManDemo()
local demoDone = nil
demoBattle.onFinish = function(r) demoDone = r end
local partyBefore = #Game.save.party
StateStack:push(demoBattle)
guard = 0
while demoDone == nil and guard < 5000 do
  guard = guard + 1
  Input:keypressed("z")
  Input:step()
  Input.pressed = { a = true }
  StateStack:update(1 / 60)
  Input:keyreleased("z")
end
check(demoDone ~= nil, "old man catch demo runs to completion")
eq(#Game.save.party, partyBefore, "the demo Weedle is not kept")

-- save round trip
local SaveData = require("src.core.SaveData")
SaveData.save(Game.save)
local loaded = SaveData.load()
eq(loaded.inventory.POTION, 2, "save/load round trip")
eq(loaded.party[1].species, "BULBASAUR", "party persisted")

-- ---------------------------------------------------------------- save/load deep round trip
-- A representative save table survives SaveData.save -> load exactly
-- (the love stub keeps the file in memory, so no temp path is needed).
do
  local SD = require("src.core.SaveData")
  local rep = SD.newGame()
  rep.player.id = 54321
  rep.player.map = "CERULEAN_CITY"
  rep.player.x, rep.player.y, rep.player.facing = 10, 12, "left"
  local mon = Pokemon.new(Data, "PIKACHU", 25)
  mon.dvs = { attack = 10, defense = 5, speed = 15, special = 0, hp = 4 }
  mon.statExp = { hp = 1234, attack = 999, defense = 0, speed = 65535, special = 7 }
  mon.status = "PAR"
  mon.moves[1].pp = 3
  mon.moves[1].ppUps = 2
  mon.otId = 12345
  mon.nickname = "SPARKY"
  table.insert(rep.party, mon)
  rep.boxes = {}
  for i = 1, 12 do rep.boxes[i] = {} end
  table.insert(rep.boxes[3], Pokemon.new(Data, "CATERPIE", 4))
  rep.currentBox = 3
  rep.flags = { EVENT_GOT_STARTER = true, EVENT_GOT_OAKS_PARCEL = true }
  rep.inventory = { POTION = 3, POKE_BALL = 10, TOWN_MAP = 1 }
  rep.bagOrder = { "POKE_BALL", "POTION", "TOWN_MAP" }
  rep.pcItems = { ANTIDOTE = 2 }
  rep.coins = 777
  rep.money = 2469
  rep.playTime = 123.5
  -- Options persist in options.lua (separate from the game save).  A full
  -- set of keys is used so mergeOptions doesn't invent extras that would
  -- trip deepEq if we compared the live tables naively.
  rep.options = {
    textSpeed = 3, animations = false, battleStyle = "SET",
    ruleset = "gen1_faithful", musicVol = 4, sfxVol = 2, musicFilter = 2,
    colors = "og", tilt = 2, gbcfx = 3,
  }
  rep.defeatedTrainers = { ["OPP_BROCK:1"] = true }
  rep.pokedex = { seen = { PIKACHU = true, CATERPIE = true },
                  owned = { PIKACHU = true } }

  local function deepEq(a, b, path)
    if type(a) ~= type(b) then return false, path end
    if type(a) ~= "table" then
      if a ~= b then return false, path end
      return true
    end
    for k, v in pairs(a) do
      local ok, p = deepEq(v, b[k], path .. "." .. tostring(k))
      if not ok then return false, p end
    end
    for k in pairs(b) do
      if a[k] == nil then return false, path .. "." .. tostring(k) end
    end
    return true
  end
  check(SD.save(rep), "representative save writes")
  local back = SD.load()
  -- Progress is in save.lua; options come back from options.lua.
  eq(back.options.musicVol, 4, "options.lua round-trips musicVol")
  eq(back.options.sfxVol, 2, "options.lua round-trips sfxVol")
  eq(back.options.animations, false, "options.lua round-trips animations")
  eq(back.options.colors, "og", "options.lua round-trips colors")
  eq(back.options.tilt, 2, "options.lua round-trips tilt")
  eq(back.options.gbcfx, 3, "options.lua round-trips gbcfx")
  local origOpts, loadedOpts = rep.options, back.options
  rep.options, back.options = nil, nil
  local same, where = deepEq(rep, back, "save")
  check(same, "save/load deep round trip" .. (same and "" or (" (differs at " .. where .. ")")))
  rep.options, back.options = origOpts, loadedOpts
  -- leave defaults for later tests that expect a clean options.lua
  SD.saveOptions(SD.defaultOptions())
end

-- ---------------------------------------------------------------- crit thresholds (CriticalHitTest)
-- The threshold byte b from engine/battle/core.asm's shift chain:
-- srl (speed/2), then sla (cap 255) without Focus Energy or srl with the
-- FE bug, then sla+sla (cap) for high-crit moves or srl for normal ones;
-- crit when rand(0..255) < b.
do
  local function critThreshold(speed, moveId, focusEnergy, rs)
    local a = { def = { baseStats = { speed = speed } }, focusEnergy = focusEnergy }
    local n = 0
    for i = 0, 255 do
      if Damage.critRoll(rs or ruleset, a, moveId, function() return i end) then
        n = n + 1
      end
    end
    return n
  end
  eq(critThreshold(128, "TACKLE", false), 64, "crit: speed 128 normal move -> 64/256")
  eq(critThreshold(90, "TACKLE", false), 45, "crit: srl/sla/srl floors (speed 90 -> 45)")
  eq(critThreshold(128, "SLASH", false), 255, "crit: speed 128 high-crit capped at 255/256")
  eq(critThreshold(115, "SLASH", false), 255, "crit: Persian-speed Slash also caps at 255")
  eq(critThreshold(60, "SLASH", false), 240, "crit: speed 60 high-crit -> 240/256 (uncapped x4)")
  eq(critThreshold(128, "TACKLE", true), 16, "crit: Focus Energy bug quarters (128 -> 16/256)")
  eq(critThreshold(128, "SLASH", true), 128, "crit: FE bug + high-crit (srl then sla sla -> 128)")
  local rsFixed = { focusEnergyBug = false }
  eq(critThreshold(32, "TACKLE", true, rsFixed), 64,
     "crit: FE without the bug quadruples (32 -> 64/256 vs 16)")
end

-- ---------------------------------------------------------------- catch RNG order (ItemUseBall)
-- pokered rolls Rand1 (0..ballMax), subtracts the status bonus (underflow
-- = instant catch), compares against the catch rate (failure never rolls
-- again), then rolls Rand2 (0..255) against the HP factor X.
do
  local Catching2 = require("src.battle.Catching")
  local function seq(vals)
    local calls, i = {}, 0
    return function(a, b)
      i = i + 1
      table.insert(calls, { a, b })
      return assert(vals[i], "rng over-consumed")
    end, calls
  end
  -- full-HP 100-max mon, POKe BALL: X = floor(floor(100*255/12)/25) = 85
  local mon = { status = nil, stats = { hp = 100 }, hp = 100 }

  -- MASTER BALL rolls nothing
  local rng, calls = seq({})
  local caught, shakes = Catching2.attempt("MASTER_BALL", mon, { catchRate = 3 }, rng)
  check(caught == true and #calls == 0, "MASTER BALL consumes no rolls")

  -- Rand1 > rate fails without a second roll; z = floor(85*39/255) = 13 -> 1 shake
  rng, calls = seq({ 150 })
  caught, shakes = Catching2.attempt("POKE_BALL", mon, { catchRate = 100 }, rng)
  check(caught == false, "Rand1 above catch rate fails")
  eq(#calls, 1, "rate-compare failure consumes exactly one roll")
  eq(calls[1][2], 255, "Rand1 range is 0..255 for a POKe BALL")
  eq(shakes, 1, "z=13 wobble tier -> 1 shake")

  -- Rand1 == rate proceeds; Rand2 == X catches (<= compare)
  rng, calls = seq({ 100, 85 })
  caught = Catching2.attempt("POKE_BALL", mon, { catchRate = 100 }, rng)
  check(caught == true, "Rand1 == rate proceeds and Rand2 == X catches")
  eq(#calls, 2, "successful catch consumed Rand1 then Rand2")
  eq(calls[2][1], 0, "Rand2 lower bound is 0")
  eq(calls[2][2], 255, "Rand2 range is 0..255 regardless of ball")

  -- Rand2 = X+1 fails on the wobble roll with the same shake tiers
  rng, calls = seq({ 100, 86 })
  caught, shakes = Catching2.attempt("POKE_BALL", mon, { catchRate = 100 }, rng)
  check(caught == false and #calls == 2, "Rand2 above X fails after two rolls")
  eq(shakes, 1, "second-path failure shares the shake tiers")

  -- status subtraction underflow: sleep bonus 25 auto-catches on Rand1 < 25
  local slp = { status = "SLP", stats = { hp = 100 }, hp = 100 }
  rng, calls = seq({ 24 })
  caught, shakes = Catching2.attempt("POKE_BALL", slp, { catchRate = 0 }, rng)
  check(caught == true and #calls == 1, "sleep underflow catches on Rand1 alone")
  eq(shakes, 3, "underflow catch reports the full 3 shakes")

  -- rate >= ball max: the rate compare can never fail (GREAT BALL 0..200)
  rng, calls = seq({ 200, 255 })
  caught, shakes = Catching2.attempt("GREAT_BALL", mon, { catchRate = 255 }, rng)
  eq(calls[1][2], 200, "GREAT BALL Rand1 range is 0..200")
  check(caught == false and #calls == 2,
        "rate above ball max always reaches Rand2 (255 > X=127 fails)")
  eq(shakes, 2, "GREAT BALL fail: z = floor(127*127/255) = 63 -> 2 shakes")

  -- 3-shake tier: rate 200, low HP (X=255): z = floor(255*78/255) = 78
  local weak = { status = nil, stats = { hp = 100 }, hp = 4 }
  rng, calls = seq({ 255 })
  caught, shakes = Catching2.attempt("POKE_BALL", weak, { catchRate = 200 }, rng)
  check(caught == false, "Rand1 255 > rate 200 fails")
  eq(shakes, 3, "z=78 wobble tier -> 3 shakes")
end

-- ---------------------------------------------------------------- survey zoom
do
  local Zoom = require("src.render.Zoom")
  local S = 6
  eq(Zoom.scale(S), 6, "default zoom = fit scale")
  Zoom.step(-1, S)
  eq(Zoom.scale(S), 5, "wheel down steps out one level")
  for _ = 1, 20 do Zoom.step(-1, S) end
  eq(Zoom.scale(S), 1, "zoom out clamps at 1")
  for _ = 1, 40 do Zoom.step(1, S) end
  eq(Zoom.scale(S), 12, "zoom in clamps at 2*S")
  Zoom.reset()
  eq(Zoom.scale(S), 6, "reset restores default")

  -- offset-from-S: a window resize keeps the relative zoom
  Zoom.step(-2, S)
  eq(Zoom.scale(4), 2, "offset survives fit-scale change")

  -- world view size in world pixels
  local vw, vh = Zoom.viewSize(6, 160, 144) -- s' = 4
  eq(vw, 240, "view width at s'=4 of S=6")
  eq(vh, 216, "view height at s'=4 of S=6")
  Zoom.reset()
  vw, vh = Zoom.viewSize(6, 160, 144)
  eq(vw, 160, "default view width is 160")
  eq(vh, 144, "default view height is 144")

  -- window-filling world view (phone letterbox voids → more map)
  local fw, fh = Zoom.fillViewSize(2, 390, 844)
  eq(fw, 195, "fill view width at s'=2")
  eq(fh, 422, "fill view height at s'=2")

  -- input gate: only free-roaming overworld accepts zoom input
  local ow = { runner = { isRunning = function() return false end } }
  check(Zoom.gateOK(ow, ow), "gate open when overworld topmost")
  check(not Zoom.gateOK({}, ow), "gate closed when a menu is on top")
  check(not Zoom.gateOK(nil, ow), "gate closed with empty stack")
  ow.transitioning = true
  check(not Zoom.gateOK(ow, ow), "gate closed while transitioning")
  ow.transitioning = false
  ow.runner = { isRunning = function() return true end }
  check(not Zoom.gateOK(ow, ow), "gate closed while a script runs")
  Zoom.reset()
end

-- ---------------------------------------------------------------- zoom camera
do
  local Camera = require("src.render.Camera")
  local cam = Camera.new()
  cam:follow(160, 160)
  eq(cam.x, 96, "legacy follow x = px - 64")
  eq(cam.y, 96, "legacy follow y = py - 64")
  cam:follow(160, 160, 320, 288)
  eq(cam.x, 160 - (320 / 2 - 16), "wide view keeps player centered x")
  eq(cam.y, 160 - (288 / 2 - 8), "wide view keeps player centered y")
end

-- ---------------------------------------------------------------- spawn filter
do
  local OW = require("src.world.OverworldController")
  local save = { defeatedTrainers = {} }
  check(OW.objectVisible(save, "ROUTE_1", { index = 1 }),
        "plain NPC visible")
  check(not OW.objectVisible(save, "ROUTE_1", { index = 1, hidden = true }),
        "hidden object invisible")
  save.objectToggles = { ROUTE_1 = { GUARD = true } }
  check(OW.objectVisible(save, "ROUTE_1",
                         { index = 1, hidden = true, name = "GUARD" }),
        "show_object toggle overrides hidden")
  save.itemsTaken = { ROUTE_1_obj_2 = true }
  check(not OW.objectVisible(save, "ROUTE_1", { index = 2, item = "POTION" }),
        "collected item ball invisible")
  save.defeatedTrainers = { ROUTE_1_obj_3 = true }
  check(not OW.objectVisible(save, "ROUTE_1",
                             { index = 3, pokemon = "PIDGEY" }),
        "beaten static encounter gone")
end

-- ---------------------------------------------------------------- battle fx ordering
-- The hit blink and the faint fx must ride the message queue behind the
-- move-animation row (pokered: anim -> blink -> bar drain -> texts ->
-- faint slide -> faint text), never fire live at damage time.
do
  Game.save.party[1].hp = Game.save.party[1].stats.hp
  local function animPending(b)
    for _, r in ipairs(b.queue) do if r.anim then return true end end
    return false
  end

  -- hit blink
  local ob = BattleState.newWild(Game, "RATTATA", 2)
  ob.onFinish = function() end
  ob.rng = function(a, b) return a end
  ob.queue, ob.fx = {}, nil
  ob:performMove(ob.player, ob.enemy, { id = "TACKLE", pp = 10 })
  check(ob.enemy.mon.hp < ob.enemy.mon.stats.hp, "tackle dealt damage")
  check(not (ob.fx and ob.fx.blink), "hit blink is queued, not live")
  local sawBlink, steps = false, 0
  while steps < 2000 and not sawBlink do
    steps = steps + 1
    Input.pressed = { a = true }
    if not ob:updateQueue() then break end
    if ob.fx and ob.fx.blink then sawBlink = true end
  end
  check(sawBlink, "hit blink fires during queue playback")
  check(sawBlink and not animPending(ob), "blink waits for the anim row")

  -- faint fx
  Game.save.party[1].hp = Game.save.party[1].stats.hp
  local fb = BattleState.newWild(Game, "RATTATA", 2)
  fb.onFinish = function() end
  fb.rng = function(a, b) return a end
  fb.queue, fb.fx = {}, nil
  fb.enemy.mon.hp = 1
  fb:performMove(fb.player, fb.enemy, { id = "TACKLE", pp = 10 })
  eq(fb.enemy.mon.hp, 0, "lethal tackle empties HP")
  check(not fb.enemy.fainted and not (fb.fx and fb.fx.faint),
        "faint fx is queued, not live")
  local sawFaint
  steps = 0
  while steps < 2000 and not sawFaint do
    steps = steps + 1
    Input.pressed = { a = true }
    if not fb:updateQueue() then break end
    if fb.fx and fb.fx.faint then sawFaint = true end
  end
  check(sawFaint, "faint fx fires during queue playback")
  check(sawFaint and fb.enemy.fainted, "fainted flag set with the slide")
  check(sawFaint and not animPending(fb), "faint waits for the anim row")
end

-- ---------------------------------------------------------------- ball toss animation chain
-- ItemUseBall packs the outcome into wPokeBallAnimData and TossBallAnimation
-- (engine/battle/animations.asm:2582) chains toss -> POOF -> HIDEPIC ->
-- SHAKE xN (-> POOF -> SHOWPIC on breakout); DoBallShakeSpecialEffects
-- plays a tink + 40-frame pause per shake, rewinding the same subanim.
do
  local AnimPlayer = require("src.battle.AnimPlayer")
  local ap = AnimPlayer.new(require("data.generated.battle_anims"))
  ap:start("SHAKE_ANIM", true, { shakes = 3 })
  local tinks = 0
  for _, e in ipairs(ap.events) do
    if e.effect == "SFX_TINK" then tinks = tinks + 1 end
  end
  eq(tinks, 3, "SHAKE_ANIM x3 fires three tink events")
  local total = 0
  for _, s in ipairs(ap.steps) do total = total + s.dur end
  check(total >= 3 * 40 + 3 * 16,
        "three shakes include the 40-frame suspense pauses")
  ap:start("SHAKE_ANIM", true, { shakes = 1 })
  local total1 = 0
  for _, s in ipairs(ap.steps) do total1 = total1 + s.dur end
  check(total1 < total, "one shake is shorter than three")

  -- record the anim rows a ball throw queues, pumping the queue dry
  local function chainOf(b, ball)
    local seq = {}
    local orig = b.animNext
    b.animNext = function(s, name, isPlayer, shakes)
      seq[#seq + 1] = shakes and (name .. "x" .. shakes) or name
      return orig(s, name, isPlayer, shakes)
    end
    -- isolate the chain from the rest of the turn
    b.executeAction = function() end
    b.endOfTurn = function() end
    b.storeCaughtMon = function() end
    b.queue = {}
    b:throwBall(ball)
    local steps = 0
    while steps < 2000 do
      steps = steps + 1
      Input.pressed = { a = true }
      if not b:updateQueue() then break end
    end
    Input.pressed = {}
    return table.concat(seq, ",")
  end

  -- guaranteed capture (rng low): $43 anim data -> toss, poof, hide, 3 shakes
  Game.save.party[1].hp = Game.save.party[1].stats.hp
  local cb = BattleState.newWild(Game, "RATTATA", 3)
  cb.onFinish = function() end
  cb.rng = function(a, b) return a end
  eq(chainOf(cb, "POKE_BALL"),
     "TOSS_ANIM,POOF_ANIM,HIDEPIC_ANIM,SHAKE_ANIMx3",
     "capture chain matches $43 anim data")
  check(not (cb.fx and cb.fx.wobble), "no legacy wobble fx on capture")
  check(cb.enemyHidden == true, "enemy pic hidden once the ball closes")

  -- breakout (rng high vs RATTATA => 2 shakes): the full 6-anim chain
  local bb = BattleState.newWild(Game, "RATTATA", 3)
  bb.onFinish = function() end
  bb.rng = function(a, b) return b end
  eq(chainOf(bb, "POKE_BALL"),
     "TOSS_ANIM,POOF_ANIM,HIDEPIC_ANIM,SHAKE_ANIMx2,POOF_ANIM,SHOWPIC_ANIM",
     "breakout chain matches $62 anim data")
  check(not bb.enemyHidden, "enemy pic restored after the breakout")

  -- clean miss (rng high vs SNORLAX => 0 shakes): toss + poof only
  local mb = BattleState.newWild(Game, "SNORLAX", 30)
  mb.onFinish = function() end
  mb.rng = function(a, b) return b end
  eq(chainOf(mb, "POKE_BALL"),
     "TOSS_ANIM,POOF_ANIM",
     "clean miss stops after the poof ($20 anim data)")
  check(not mb.enemyHidden, "missed mon never hides")
end

-- ---------------------------------------------------------------- heal machine cadence
-- AnimateHealingMachine (engine/overworld/healing_machine.asm): one ball
-- per party mon every 30 frames (SFX_HEALING_MACHINE each), then the
-- healed jingle while the machine flashes 8 times (10 frames a toggle),
-- then a 32-frame beat after the jingle ends.
do
  local OW = require("src.world.OverworldController")
  local ha = { balls = 3, lit = 0, timer = 0, visible = true }
  local events, toggles = {}, 0
  local ok = pcall(function()
    for frame = 1, 400 do
      local wasVisible = ha.visible
      local ev = OW.stepHealAnim(ha)
      if ha.visible ~= wasVisible then toggles = toggles + 1 end
      if ev then events[#events + 1] = frame .. ev end
      if ev == "jingle" then ha.jingleDone = true end -- headless: no audio
      if ev == "done" then break end
    end
  end)
  check(ok, "stepHealAnim runs")
  eq(table.concat(events, ","),
     "1ball,31ball,61ball,91jingle,203done",
     "heal machine: a ball per mon every 30 frames, jingle, flash, done")
  eq(toggles, 8, "machine sprites flash 8 times")
  check(ha.visible, "machine sprites end visible")

  -- the wait phase holds until the jingle actually finishes
  local ha2 = { balls = 1, lit = 0, timer = 0, visible = true }
  local doneEarly = false
  pcall(function()
    for _ = 1, 300 do
      if OW.stepHealAnim(ha2) == "done" then doneEarly = true end
    end
  end)
  check(not doneEarly, "heal machine waits for the jingle to end")
  ha2.jingleDone = true
  local extra = 0
  pcall(function()
    repeat extra = extra + 1 until OW.stepHealAnim(ha2) == "done" or extra > 100
  end)
  eq(extra, 32, "32-frame beat after the jingle")
end

-- ---------------------------------------------------------------- HP bar right cap
-- DrawHPBar (home/pokemon.asm): the right-end tile depends on
-- wHPBarType -- only type 1 (player battle bar, status screen) uses the
-- double-bar $6D; the enemy bar (0) and party menu (2) end with the
-- near-blank $6C nub.
do
  local HudTiles = require("src.render.HudTiles")
  local ok = pcall(function()
    eq(HudTiles.capTile(0), 0x6C, "enemy bar cap is $6C")
    eq(HudTiles.capTile(1), 0x6D, "player battle bar cap is $6D")
    eq(HudTiles.capTile(2), 0x6C, "party menu bar cap is $6C")
  end)
  check(ok, "HudTiles.capTile exists")
end

-- ---------------------------------------------------------------- mart menu flow
-- DisplayPokemartDialogue_ loops the BUY/SELL/QUIT menu until QUIT, so
-- closing the buy list must land back on the mart menu and QUIT must
-- fire onQuit -- open_mart resumes its yielded script runner there,
-- and losing it softlocked the Viridian mart after a purchase.
do
  local ShopMenu = require("src.ui.ShopMenu")
  local quitCalled = false
  local depth0 = #StateStack.states
  local shop = ShopMenu.new(Game, { "POTION" }, function() quitCalled = true end)
  StateStack:push(shop)
  local function press(btn)
    Input.pressed = { [btn] = true }
    StateStack:update(1 / 60)
    Input.pressed = {}
  end
  press("a") -- BUY
  check(StateStack:top() ~= shop, "BUY opens the buy list")
  press("b") -- close the list
  eq(StateStack:top(), shop, "closing the list returns to the mart menu")
  press("down")
  press("down")
  press("a") -- QUIT
  check(quitCalled, "QUIT fires onQuit (script runner resume)")
  eq(#StateStack.states, depth0, "mart menu unwound cleanly")
end



-- ================= BUGS.md batch: battle-victory-music =================
-- FaintEnemyPokemon .wild_win (core.asm:792-795) / TrainerBattleVictory
-- (core.asm:915-933): the looping victory theme starts when the win is
-- decided, not at battle pop; finish() restores the map theme.
do
  local savedParty = Game.save.party
  local Music = require("src.core.Music")
  local Pokemon = require("src.pokemon.Pokemon")
  local realPlayVictory, realRestore = Music.playVictory, Music.restoreMap
  local restores = 0
  Music.restoreMap = function() restores = restores + 1 end

  -- wild win (level 10: TACKLE in slot 1, so mash-A wins fast)
  Game.save.party = { Pokemon.new(Data, "BULBASAUR", 10) }
  local vb = BattleState.newWild(Game, "RATTATA", 2)
  local vfin; vb.onFinish = function(r) vfin = r end
  StateStack:push(vb)
  local calls = {}
  Music.playVictory = function(data, kind)
    table.insert(calls, { kind = kind, resultAtCall = vb.result,
                          inBattle = StateStack:top() == vb })
  end
  local guard = 0
  while vfin == nil and guard < 20000 do
    guard = guard + 1
    Input:keypressed("z"); Input:step(); Input.pressed = { a = true }
    StateStack:update(1 / 60); Input:keyreleased("z")
  end
  eq(vfin, "win", "victory-music wild battle is won")
  eq(#calls, 1, "wild win starts the victory theme exactly once")
  eq(calls[1] and calls[1].kind, "wild", "wild win uses the DefeatedWildMon theme")
  check(calls[1] and calls[1].resultAtCall == nil and calls[1].inBattle,
        "wild victory theme starts before the fainted text, in battle")
  check(restores >= 1, "finish() restores the map theme at battle pop")
  vb:playVictoryMusic()
  eq(#calls, 1, "playVictoryMusic is idempotent")

  -- trainer win: theme starts while the defeated/prize texts are queued
  Game.save.party = { Pokemon.new(Data, "BULBASAUR", 60) }
  local tv = BattleState.newTrainer(Game, "OPP_YOUNGSTER", 1)
  tv.enemyParty = { tv.enemyParty[1] } -- single-mon party
  local tfin; tv.onFinish = function(r) tfin = r end
  StateStack:push(tv)
  calls = {}
  Music.playVictory = function(data, kind)
    local pendingDefeated = false
    for _, it in ipairs(tv.queue) do
      if it.text and it.text:find("defeated", 1, true) then pendingDefeated = true end
    end
    table.insert(calls, { kind = kind, pendingDefeated = pendingDefeated })
  end
  guard = 0
  while tfin == nil and guard < 20000 do
    guard = guard + 1
    Input:keypressed("z"); Input:step(); Input.pressed = { a = true }
    StateStack:update(1 / 60); Input:keyreleased("z")
  end
  eq(tfin, "win", "victory-music trainer battle is won")
  eq(#calls, 1, "trainer win starts the victory theme exactly once")
  eq(calls[1] and calls[1].kind, "trainer", "plain trainer uses the DefeatedTrainer theme")
  check(calls[1] and calls[1].pendingDefeated,
        "TrainerBattleVictory: theme starts before the defeated text")

  -- a loss never plays victory music
  Game.save.party = { Pokemon.new(Data, "CATERPIE", 2) }
  local lb = BattleState.newWild(Game, "SNORLAX", 50)
  local lfin; lb.onFinish = function(r) lfin = r end
  StateStack:push(lb)
  calls = {}
  Music.playVictory = function() table.insert(calls, true) end
  guard = 0
  while lfin == nil and guard < 20000 do
    guard = guard + 1
    Input:keypressed("z"); Input:step(); Input.pressed = { a = true }
    StateStack:update(1 / 60); Input:keyreleased("z")
  end
  eq(lfin, "lose", "loss battle ends in blackout")
  eq(#calls, 0, "no victory theme on a loss")
  Music.playVictory, Music.restoreMap = realPlayVictory, realRestore
  Game.save.party = savedParty
end

-- ================= BUGS.md batch: battle-caught-fanfare-locked-ball =================
-- SFX_CAUGHT_MON accompanies ItemUseBallText05 (sound_caught_mon,
-- item_effects.asm:608-614): the fanfare fires with the caught text,
-- after the wobble tinks, not after the message is dismissed; the
-- resting closed ball stays compiled for the caught text (the $43
-- chain ends after SHAKE_ANIM and the GB leaves the ball in OAM).
do
  local savedParty = Game.save.party
  local Pokemon = require("src.pokemon.Pokemon")
  local Sound = require("src.core.Sound")
  local log = {}
  local origPlay = Sound.play
  Sound.play = function(_, name) log[#log + 1] = "sfx:" .. name end
  Game.save.pokedex.owned.RATTATA = true
  Game.save.party = {}
  for _ = 1, 6 do table.insert(Game.save.party, Pokemon.new(Data, "PIDGEY", 5)) end
  local cb4 = BattleState.newWild(Game, "RATTATA", 3)
  cb4.onFinish = function() end
  cb4.rng = function(a, b) return a end -- rng low: guaranteed capture
  local origStart = cb4.startMessage
  cb4.startMessage = function(s, item)
    log[#log + 1] = "text:" .. item.text:gsub("\n.*", "")
    return origStart(s, item)
  end
  cb4.queue = {}
  cb4:throwBall("POKE_BALL")
  local steps = 0
  while steps < 4000 do
    steps = steps + 1
    Input.pressed = { a = true }
    if not cb4:updateQueue() then break end
  end
  Input.pressed = {}
  Sound.play = origPlay
  local caughtAt, fanfareAt, fanfares, tinks = nil, nil, 0, 0
  for i, e in ipairs(log) do
    if e == "sfx:Caught_Mon" then
      fanfares = fanfares + 1
      fanfareAt = fanfareAt or i
    elseif e == "sfx:Tink" then
      tinks = tinks + 1
      check(not fanfareAt, "wobble tinks all precede the fanfare")
    elseif e == "text:All right!" then
      caughtAt = caughtAt or i
    end
  end
  eq(fanfares, 1, "one caught fanfare per capture")
  eq(tinks, 3, "three wobble tinks on a $43 capture")
  check(fanfareAt and caughtAt and fanfareAt < caughtAt,
        "Caught_Mon sounds with the caught text, not after its dismissal")
  eq(cb4.result, "caught", "the capture resolved the battle")
  check(cb4.lockedBall and #cb4.lockedBall > 0,
        "the resting closed ball stays compiled for the caught text")
  Game.save.party = savedParty
end

-- ================= BUGS.md batch: battle-low-health-alarm =================
-- audio/low_health_alarm.asm + DrawPlayerHUDAndHPBar (core.asm:1846-
-- 1875): the alarm keys off the drawn bar color (red = max(1,
-- floor(hp*48/max)) < 10), gated by the drain, faint, and the win
-- disable (EndLowHealthAlarm sets wLowHealthAlarmDisabled).
do
  local savedParty = Game.save.party
  local Pokemon = require("src.pokemon.Pokemon")
  Game.save.party = { Pokemon.new(Data, "BULBASAUR", 30) }
  Game.save.party[1].hp = Game.save.party[1].stats.hp
  local lhb = BattleState.newWild(Game, "RATTATA", 3)
  local lp = lhb.player
  lhb.introSlide, lhb.showPlayerBack = 0, false
  lp.mon.stats.hp = 48
  lp.mon.hp, lp.shownHP = 10, 10
  check(not lhb:lowHealthAlarmActive(), "bar at 10 px: yellow, no alarm")
  lp.mon.hp, lp.shownHP = 9, 9
  check(lhb:lowHealthAlarmActive(), "bar under 10 px: red, alarm on")
  lp.shownHP = 20
  check(not lhb:lowHealthAlarmActive(), "alarm waits for the HP drain to catch up")
  lp.shownHP = 9
  lhb.result = "win"
  check(not lhb:lowHealthAlarmActive(), "decided battle keeps the alarm off (EndLowHealthAlarm)")
  lhb.result = nil
  lhb:playVictoryMusic()
  check(not lhb:lowHealthAlarmActive(),
        "playVictoryMusic disables the alarm (wLowHealthAlarmDisabled)")
  lhb.lowHealthAlarmDisabled, lhb.victoryMusicPlayed = nil, nil
  lp.mon.hp, lp.shownHP = 0, 0
  check(not lhb:lowHealthAlarmActive(), "fainted mon: no alarm")
  lp.mon.stats.hp = 250
  lp.mon.hp, lp.shownHP = 52, 52
  check(lhb:lowHealthAlarmActive(), "52/250 HP = 9 px is red (GetHPBarLength math)")
  lp.mon.hp, lp.shownHP = 53, 53
  check(not lhb:lowHealthAlarmActive(), "53/250 HP = 10 px is not red")
  Game.save.party = savedParty
end

-- ================= BUGS.md batch: options-menu =================
do
-- == Task 8: options screen scrolls option boxes + audio/display rows ==
-- The screen keeps pokered's one-box-per-option adaptation of
-- DisplayOptionMenu (engine/menus/main_menu.asm) but now scrolls the
-- option boxes (the port rows plus the MODS/CONTROLS entries) through a 4-box
-- viewport with a $EE ▼ marker; MUSIC VOL / SFX VOL clamp at 0..7 like
-- the text-speed cursor clamps at its ends (.pressedLeftInTextSpeed),
-- MUSIC FILTER cycles OFF/1X/2X/3X, and COLORS / TILT / GBC FX / VIDEO MODE
-- cycle their display modes.
do
  local OptionsMenu = require("src.ui.OptionsMenu")
  local OInput = require("src.core.Input")
  local PaletteFX = require("src.render.PaletteFX")
  local Tilt = require("src.render.Tilt")
  local GBCFX = require("src.render.GBCFX")
  local GameSpeed = require("src.core.GameSpeed")
  local VideoMode = require("src.core.VideoMode")
  local SD = require("src.core.SaveData")
  -- Isolate from earlier save/options writes in this suite
  SD.saveOptions(SD.defaultOptions())
  local popped = false
  local og = { data = Data, save = SD.newGame(),
               input = OInput, stack = { pop = function() popped = true end },
               writeOptions = function(self) SD.saveOptions(self.save.options) end }
  local om = OptionsMenu.new(og)
  local function press(btn)
    OInput.pressed = { [btn] = true }
    om:update(1 / 60)
    OInput.pressed = {}
  end
  eq(og.save.options.textSpeed, 3,
     "new saves default to MEDIUM text (InitOptions TEXT_DELAY_MEDIUM)")
  eq(og.save.options.colors, "gbc", "new saves default COLORS to GBC")
  eq(og.save.options.tilt, 0, "new saves default TILT to OFF")
  eq(og.save.options.gbcfx, 0, "new saves default GBC FX to OFF")
  eq(og.save.options.videoMode, "windowed",
     "new saves default VIDEO MODE to WINDOWED")
  eq(om.scroll, 0, "options viewport starts at the top")
  for _ = 1, 4 do press("down") end
  eq(om.index, 5, "cursor reaches MUSIC VOL")
  eq(om.scroll, 1, "viewport scrolls to keep MUSIC VOL on screen")
  press("left")
  eq(og.save.options.musicVol, 6, "left lowers MUSIC VOL")
  press("right")
  eq(og.save.options.musicVol, 7, "right raises MUSIC VOL back")
  press("right")
  eq(og.save.options.musicVol, 7, "MUSIC VOL clamps at 7")
  press("down"); press("left")
  eq(og.save.options.sfxVol, 6, "SFX VOL adjusts on its own row")
  press("down")
  for _ = 1, 3 do press("a") end
  eq(og.save.options.musicFilter, 3, "A cycles MUSIC FILTER to 3X")
  press("a")
  eq(og.save.options.musicFilter, 0, "MUSIC FILTER wraps back to OFF")
  press("down")
  eq(om.index, 8, "cursor reaches COLORS")
  press("a")
  eq(og.save.options.colors, "og", "A cycles COLORS to OG")
  eq(PaletteFX.mode, "og", "PaletteFX mode tracks COLORS option")
  for _ = 1, 4 do press("a") end
  eq(og.save.options.colors, "gbc", "COLORS wraps back to GBC")
  press("down")
  eq(om.index, 9, "cursor reaches TILT")
  press("a")
  eq(og.save.options.tilt, 1, "A cycles TILT to 15")
  eq(Tilt.level, 1, "Tilt level tracks TILT option")
  press("a"); press("a"); press("a")
  eq(og.save.options.tilt, 0, "TILT wraps back to OFF")
  press("down")
  eq(om.index, 10, "cursor reaches GBC FX")
  press("a")
  eq(og.save.options.gbcfx, 1, "A cycles GBC FX to 1")
  eq(GBCFX.level, 1, "GBCFX level tracks GBC FX option")
  for _ = 1, 4 do press("a") end
  eq(og.save.options.gbcfx, 0, "GBC FX wraps back to OFF")
  press("down")
  eq(om.index, 11, "cursor reaches VIDEO MODE")
  press("a")
  eq(og.save.options.videoMode, "borderless",
     "A cycles VIDEO MODE to BORDERLESS")
  press("a")
  eq(og.save.options.videoMode, "windowed",
     "VIDEO MODE wraps back to WINDOWED")
  press("down")
  eq(om.index, 12, "cursor reaches GAME SPEED")
  press("a")
  eq(og.save.options.speed, 2, "A cycles GAME SPEED to 2X")
  -- Driven by the level list rather than a literal press count: adding a
  -- speed (20X went in for the bot runs) otherwise fails this as a wrap
  -- bug when the cycling is fine and the row is simply one longer.
  for _ = 1, #GameSpeed.LEVELS - 1 do press("a") end
  eq(og.save.options.speed, 1, "GAME SPEED wraps back to NORMAL")
  press("down")
  eq(om.index, 13, "cursor reaches MODS")
  press("down")
  eq(om.index, 14, "cursor reaches CONTROLS")
  press("down")
  eq(om.index, 15, "CANCEL stays the fixed final row")
  eq(om.scroll, 10, "CANCEL keeps the last option boxes on screen")
  om:draw() -- smoke: scrolled layout draws under the headless stub
  press("a")
  check(popped, "A on CANCEL closes the options menu")
  local om2 = OptionsMenu.new(og)
  OInput.pressed = { up = true }; om2:update(1 / 60); OInput.pressed = {}
  eq(om2.index, 15, "up from the top wraps to CANCEL")
  eq(om2.scroll, 10, "wrapping to CANCEL scrolls to the tail")
  -- headless-safe: no love.audio, setters only update internal state
  require("src.core.Music").applyOptions(og.save.options)
  require("src.core.Sound").applyOptions(og.save.options)
  PaletteFX.applyOptions(og.save.options)
  Tilt.applyOptions(og.save.options)
  GBCFX.applyOptions(og.save.options)
  VideoMode.applyOptions(og.save.options)
end
end

-- ------------------------------------------------------------------
-- BUGS.md fix coverage (2026-07-14 batch A)
-- ------------------------------------------------------------------

-- ================= BUGS.md batch: menu-sfx =================
do
-- == Task 6: menu SFX paths stay headless-safe (HandleMenuInput_ A|B beep) ==
local Menu = require("src.ui.Menu")
local ChoiceBox = require("src.ui.ChoiceBox")
do
  local function stubGame(pressed)
    local popped = 0
    local game = {
      data = Data,
      -- like Input:wasPressed, edges hold for the whole step (no consume)
      input = { wasPressed = function(_, key) return pressed[key] or false end },
      stack = {},
    }
    game.stack.pop = function() popped = popped + 1 end
    game.popCount = function() return popped end
    return game
  end

  local game = stubGame({ a = true })
  local fired = false
  local menu = Menu.new(game, { { label = "X", onSelect = function() fired = true end } })
  menu:update(0)
  check(fired, "Menu A-press selects (SFX no-ops headless)")
  eq(game.popCount(), 1, "Menu A-press pops itself")

  game = stubGame({ b = true })
  local canceled = false
  menu = Menu.new(game, { { label = "X" } }, { onCancel = function() canceled = true end })
  menu:update(0)
  check(canceled, "Menu B-press cancels (SFX no-ops headless)")

  -- pokered's wMenuWatchedKeys mask varies per menu: the common PAD_A |
  -- PAD_B (and the list menu's + PAD_SELECT) masks omit PAD_START, so a
  -- default menu ignores START; only menus whose real mask adds PAD_START
  -- (the start menu, engine/menus/draw_start_menu.asm) opt in.
  game = stubGame({ start = true })
  menu = Menu.new(game, { { label = "X" } })
  menu:update(0)
  eq(game.popCount(), 0, "Menu START-press is ignored (mask omits PAD_START)")

  game = stubGame({ start = true })
  menu = Menu.new(game, { { label = "X" } }, { startCloses = true })
  menu:update(0)
  eq(game.popCount(), 1, "Menu START-press closes when startCloses (start menu's PAD_START mask; no beep per HandleMenuInput_)")

  game = stubGame({ a = true })
  local yes
  local box = ChoiceBox.new(game, function(v) yes = v end)
  box:update(0)
  eq(yes, true, "ChoiceBox A on YES chooses true")

  game = stubGame({ b = true })
  local no
  box = ChoiceBox.new(game, function(v) no = v end)
  box:update(0)
  eq(no, false, "ChoiceBox B chooses false")
end
end

-- ================= BUGS.md batch: quit-confirm =================
do
-- ---------------------------------------------------------------- START menu QUIT -> title
do
  local StartMenuQ = require("src.ui.StartMenu")
  local qsave = require("src.core.SaveData").newGame()
  local qstack = { states = {} }
  function qstack:push(s) table.insert(self.states, s) end
  function qstack:pop() return table.remove(self.states) end
  function qstack:top() return self.states[#self.states] end
  local qpressed = {}
  local qreturned = 0
  local qg = {
    data = Data, save = qsave, stack = qstack,
    input = { wasPressed = function(_, k) return qpressed[k] end },
    returnToTitle = function() qreturned = qreturned + 1 end,
  }
  local qmenu = StartMenuQ.new(qg)
  local quitIdx, hasExit
  for i, it in ipairs(qmenu.items) do
    if it.label == "QUIT" then quitIdx = i end
    if it.label == "EXIT" then hasExit = true end
  end
  check(quitIdx ~= nil, "START menu lists QUIT")
  check(not hasExit, "EXIT entry is gone")
  qstack:push(qmenu)
  qmenu.index = quitIdx
  qpressed = { a = true }
  qmenu:update(1 / 60)
  qpressed = {}
  eq(qsave.startMenuIndex, quitIdx, "QUIT selection persists the cursor slot")
  local qbox = qstack:top()
  check(qbox ~= qmenu and qbox ~= nil and qbox.pages ~= nil,
        "QUIT pushes a confirmation textbox")
  eq(qbox.pages[1][1], "RETURN TO MAIN", "confirm asks RETURN TO MAIN MENU?")
  qbox.onDone()
  local qchoice = qstack:top()
  check(qchoice ~= qbox and qchoice ~= nil and qchoice.onChoose ~= nil,
        "textbox is followed by a YES/NO choice")
  eq(qchoice.index, 2, "QUIT confirm defaults to NO")
  qchoice.onChoose(false)
  eq(qreturned, 0, "NO keeps playing")
  qchoice.onChoose(true)
  eq(qreturned, 1, "YES calls returnToTitle")

  -- Game:returnToTitle pops everything and pushes a fresh title
  local GameQ = require("src.core.Game")
  local tstack = { states = { {}, {}, {} } }
  function tstack:push(s) table.insert(self.states, s) end
  function tstack:pop() return table.remove(self.states) end
  function tstack:top() return self.states[#self.states] end
  local tg = { data = Data, stack = tstack,
               makeTitleState = GameQ.makeTitleState }
  local okTitle = pcall(GameQ.returnToTitle, tg)
  check(okTitle, "returnToTitle runs headless")
  if okTitle then
    eq(#tstack.states, 1, "returnToTitle leaves only the title state")
    check(tstack.states[1].onNewGame ~= nil,
          "fresh title carries the NEW GAME wiring")
  end
end
end

-- ================= BUGS.md batch: give-item =================

-- ================= BUGS.md batch: give-item =================
do
-- == Task 9: give_item announces the received item ==
-- pokered's GiveItem (home/give.asm) fills wStringBuffer and every gift
-- script prints a text ending "<PLAYER> got\n<item>!"; give_item's
-- default box uses that generic wording, an optional 4th arg picks a
-- per-script text, and false suppresses the box entirely.
do
  local ScriptCommands = require("src.script.Commands")
  local pushed = {}
  local giftSave = { inventory = {}, bagOrder = {}, player = { name = "RED" } }
  local fakeGame = { data = Data, save = giftSave,
                     stack = { push = function(_, s) table.insert(pushed, s) end } }
  local stubRunner = { yield = function() end, resume = function() end }
  local ctx = { game = fakeGame, save = giftSave, runner = stubRunner }
  local ret = ScriptCommands.give_item(ctx, "POTION", 1)
  eq(ret, nil, "give_item success returns nil (script continues)")
  eq(giftSave.inventory.POTION, 1, "give_item adds to the bag")
  eq(#pushed, 1, "give_item pushes the got-item textbox")
  local boxText = pushed[1] and table.concat(pushed[1].pages[1], "\n") or ""
  check(boxText:find("got", 1, true) ~= nil, "got-item box says got")
  check(boxText:find("RED", 1, true) ~= nil, "got-item box names the player")
  check(boxText:find(Data.items.POTION.name, 1, true) ~= nil, "got-item box names the item")
  eq(fakeGame.stringBuffer, Data.items.POTION.name,
     "give_item fills the wStringBuffer analog")
  -- gotText = false: the script prints its own received row; no box
  ScriptCommands.give_item(ctx, "S_S_TICKET", 1, false)
  eq(giftSave.inventory.S_S_TICKET, 1, "suppressed give still adds to the bag")
  eq(#pushed, 1, "gotText=false pushes no box")
  -- gotText label: authentic per-script text, {RAM:wStringBuffer} filled
  ScriptCommands.give_item(ctx, "TOWN_MAP", 1, "_GotMapText")
  eq(#pushed, 2, "gotText label pushes the authentic box")
  local mapText = pushed[2] and table.concat(pushed[2].pages[1], "\n") or ""
  check(mapText:find("TOWN MAP", 1, true) ~= nil,
        "{RAM:wStringBuffer} renders the item name")
end
end

-- ================= BUGS.md batch: ledge-shadow =================
do
-- == Task 12: ledge-hop shadow is the 2x2 mirrored OAM block ==
-- LoadHoppingShadowOAM (engine/overworld/ledges.asm) writes the 8x8
-- shadow tile as a 2x2 OAM block -- normal, X-flip, Y-flip, XY-flip
-- (LedgeHoppingShadowOAMBlock) -- at OAM y=$54, x=$48: screen (64,68),
-- the ground cell's left edge, 4px below its top.
do
  local Player = require("src.world.Player")
  local p = Player.new(Data, 5, 6, "down")
  check(p.shadowImg ~= nil, "hop shadow image loads")
  p.hopFrames, p.hopTotal = 32, 32
  local calls = {}
  local origDraw = love.graphics.draw
  love.graphics.draw = function(img, x, y, r, sxs, sys)
    if img == p.shadowImg then
      calls[#calls + 1] = { x, y, sxs or 1, sys or 1 }
    end
  end
  -- camera centered on the player, like Camera:follow at 160x144
  p:draw(p.px - 64, p.py - 64)
  love.graphics.draw = origDraw
  eq(#calls, 4, "hop shadow drawn as a 2x2 OAM block")
  local want = {
    { 64, 68, 1, 1 },   -- upper left
    { 80, 68, -1, 1 },  -- upper right, X-flipped
    { 64, 84, 1, -1 },  -- lower left, Y-flipped
    { 80, 84, -1, -1 }, -- lower right, XY-flipped
  }
  for i, w in ipairs(want) do
    local c = calls[i] or {}
    check(c[1] == w[1] and c[2] == w[2] and c[3] == w[3] and c[4] == w[4],
          ("hop shadow quadrant %d at (%s,%s) scale (%s,%s)")
            :format(i, tostring(c[1]), tostring(c[2]),
                    tostring(c[3]), tostring(c[4])))
  end
end
end

-- ================= BUGS.md batch: border-tree =================
do
-- ---------------------------------------------------------------- border fill (tree wall)
local TileRenderer = require("src.render.TileRenderer")
-- OVERWORLD maps fill beyond-edge space with the solid tree wall $0F
-- (ViridianCity/CeruleanCity/CeladonCity border_block: four regular-tree
-- metatiles); per-map borders like Pallet's all-grass $0B (the
-- CutTreeBlockSwaps $0B->$0A block) only apply to other tilesets
eq(TileRenderer.borderBlockFor({ def = { tileset = "OVERWORLD", borderBlock = 33 } }), 0x0F,
   "OVERWORLD border fill uses the tree wall block")
eq(TileRenderer.borderBlockFor({ def = { tileset = "HOUSE", borderBlock = 7 } }), 7,
   "interior border fill keeps the map's border block")
eq(TileRenderer.borderBlockFor({ def = Data.maps.PALLET_TOWN }), 0x0F,
   "Pallet Town border fill is trees, not its all-grass border block")
local treeWallCuttable = false
for _, swap in ipairs(Data.field.cutTreeSwaps) do
  if swap.before == 0x0F then treeWallCuttable = true end
end
check(not treeWallCuttable, "tree wall block is not a cut-tree swap source")
end

-- ================= BUGS.md batch: overworld-group =================
do
-- ---------------------------------------------------------------- neighbor graph & npc pool
do
  local OW = require("src.world.OverworldController")
  local function find(list, id)
    for _, n in ipairs(list) do if n.id == id then return n end end
    return nil
  end
  local one = OW.computeNeighbors(Data.maps, "PALLET_TOWN", 1)
  check(find(one, "ROUTE_1") and find(one, "ROUTE_21"),
        "one hop reaches Pallet's direct connections")
  check(not find(one, "VIRIDIAN_CITY"), "one hop stops before Viridian")
  eq(find(one, "ROUTE_1").oy, -Data.maps.ROUTE_1.height * 32,
     "north strip sits its full height above")

  local two = OW.computeNeighbors(Data.maps, "PALLET_TOWN", 2)
  local r1 = find(two, "ROUTE_1")
  local vc = find(two, "VIRIDIAN_CITY")
  check(vc, "two hops reach Viridian via Route 1")
  check(not find(two, "PALLET_TOWN"), "the current map is never a neighbor")
  eq(vc.ox, r1.ox + Data.maps.ROUTE_1.connections.north.offset * 32,
     "two-hop x offset composes the Route 1 -> Viridian alignment")
  eq(vc.oy, r1.oy - Data.maps.VIRIDIAN_CITY.height * 32,
     "two-hop y offset stacks Viridian above Route 1")
  local counts = {}
  local dup = false
  for _, n in ipairs(two) do
    counts[n.id] = (counts[n.id] or 0) + 1
    if counts[n.id] > 1 then dup = true end
  end
  check(not dup, "neighbors deduped by map id")

  -- NPC pool: same map object -> same instance, so ghost wander
  -- positions survive becoming the real NPCs at a crossing
  local pool = {}
  local obj = Data.maps.ROUTE_1.objects[1]
  local a = OW.pooledNPC(pool, Data, "ROUTE_1", obj)
  a.cellX, a.cellY, a.facing = a.cellX + 1, a.cellY + 2, "left"
  local b = OW.pooledNPC(pool, Data, "ROUTE_1", obj)
  check(rawequal(a, b), "pool reuses the NPC instance per map object")
  eq(b.cellX, obj.x + 1, "wandered position carries through the pool")
  eq(b.facing, "left", "facing carries through the pool")
  local fresh = OW.pooledNPC({}, Data, "ROUTE_1", obj)
  eq(fresh.cellX, obj.x, "a fresh pool (warp) respawns at object coords")
end
end

-- ================= BUGS.md batch: party-icons =================

-- ================= BUGS.md batch: party-icons =================
do
-- ---------------------------------------------------------------- party icons
-- menu_icons.asm dex mapping survives the 16x32 two-frame sheet rebuild
eq(Data.icons.byDex[19], "QUADRUPED", "Rattata icon is QUADRUPED")
eq(Data.icons.byDex[10], "BUG", "Caterpie icon is BUG")
eq(Data.icons.byDex[1], "GRASS", "Bulbasaur icon is GRASS")
eq(Data.icons.byDex[23], "SNAKE", "Ekans icon is SNAKE")
for _, name in ipairs({ "BUG", "GRASS", "SNAKE", "QUADRUPED", "BALL", "HELIX" }) do
  local path = Data.icons.icons[name]
  check(type(path) == "string", "icon path for " .. name)
  local f = io.open(path, "rb")
  check(f ~= nil, "icon image exists: " .. tostring(path))
  if f then f:close() end
end

-- per-icon rest/alt frames (data/icon_pointers.asm MonPartySpritePointers):
-- the base entries are the RESTING frame, the +ICONOFFSET entries the
-- animated alternate.  BUG/GRASS rest on Frame2 (sheet index 1) and
-- animate to Frame1; SNAKE/QUADRUPED the reverse.  MON/FAIRY/BIRD rest
-- on the overworld walk frame (tile 12 = index 3) and animate to
-- standing; WATER (Seel) is the reverse.  BALL/HELIX y-bob instead.
local frameFor = require("src.ui.PartyMenu").frameFor
eq(frameFor("BUG", false), 1, "BUG rests on Frame2")
eq(frameFor("BUG", true), 0, "BUG animates to Frame1")
eq(frameFor("GRASS", false), 1, "GRASS rests on Frame2")
eq(frameFor("GRASS", true), 0, "GRASS animates to Frame1")
eq(frameFor("SNAKE", false), 0, "SNAKE rests on Frame1")
eq(frameFor("SNAKE", true), 1, "SNAKE animates to Frame2")
eq(frameFor("QUADRUPED", false), 0, "QUADRUPED rests on Frame1")
eq(frameFor("QUADRUPED", true), 1, "QUADRUPED animates to Frame2")
eq(frameFor("MON", false), 3, "MON rests on the walk frame (tile 12)")
eq(frameFor("MON", true), 0, "MON animates to standing (tile 0)")
eq(frameFor("FAIRY", false), 3, "FAIRY rests on the walk frame")
eq(frameFor("FAIRY", true), 0, "FAIRY animates to standing")
eq(frameFor("BIRD", false), 3, "BIRD rests on the walk frame")
eq(frameFor("BIRD", true), 0, "BIRD animates to standing")
eq(frameFor("WATER", false), 0, "WATER (Seel) rests standing")
eq(frameFor("WATER", true), 3, "WATER animates to the walk frame")
-- icons outside the table keep the old uniform fallback
eq(frameFor("BALL", true, 96), 3, "fallback: 16x96 sheet animates to 3")
eq(frameFor("HELIX", true, 32), 1, "fallback: 16x32 sheet animates to 1")
end

-- ---------------------------------------------- suite discovery
-- The chains below used to be hard-coded arrays, so adding a suite meant
-- editing a list and forgetting to meant the suite silently never ran.
-- They are globbed now (21-testing-and-ci §CI).
--
-- Order still matters: these suites share one process and one Data, and
-- the sequence they were chained in is the sequence they are known to
-- pass in.  So the known order runs first and anything the glob newly
-- turned up runs after it, alphabetically -- a new suite runs without a
-- code change, and no existing suite moves.
local function orderedGlob(pattern, preferred, skip)
  local seen, ordered = {}, {}
  for _, path in ipairs(preferred) do
    local handle = io.open(path, "r")
    if handle then
      handle:close()
      seen[path] = true
      ordered[#ordered + 1] = path
    end
  end
  local discovered = {}
  local pipe = io.popen("ls -1 " .. pattern .. " 2>/dev/null")
  if pipe then
    for line in pipe:lines() do
      if line ~= "" and not seen[line] and not (skip and skip[line]) then
        seen[line] = true
        discovered[#discovered + 1] = line
      end
    end
    pipe:close()
  end
  table.sort(discovered)
  for _, path in ipairs(discovered) do ordered[#ordered + 1] = path end
  return ordered
end

local function runSuites(paths)
  for _, path in ipairs(paths) do
    local label = path:match("([^/]+)%.lua$") or path
    local ok, err = pcall(dofile, path)
    check(ok, label .. (ok and " suite" or (": " .. tostring(err))))
  end
end

-- ---------------------------------------------- mod runtime & loader
-- Self-contained like the parity files below: own bootstrap, assert-based
-- checks, error() on any failure.
runSuites(orderedGlob("tests/mod_*.lua tests/modkit_tests.lua", {
  "tests/mod_runtime_tests.lua", "tests/mod_loader_tests.lua",
  "tests/mod_registry_tests.lua", "tests/mod_manifest_tests.lua",
  "tests/mod_constants_tests.lua", "tests/mod_catalog_tests.lua",
  "tests/mod_audio_tests.lua", "tests/mod_world_tests.lua",
  "tests/mod_battle_tests.lua", "tests/mod_graphics_tests.lua",
  "tests/mod_scripting_tests.lua", "tests/mod_ui_tests.lua",
  "tests/mod_save_tests.lua", "tests/modkit_tests.lua",
}, {
  -- run_link_tests.lua owns this one; dofiling it here as well would
  -- stand a second loader up over the same Data in this process
  ["tests/mod_link_tests.lua"] = true,
}))

-- the editor mod-awareness suite boots App.load's own loader over the
-- singleton Data, which collides with the loader Game:load already merged
-- in this process (one loader per process), so it gets a process to itself
do
  local lua = (arg and arg[-1]) or "luajit"
  local status = os.execute(("%q tests/save_editor_mod_tests.lua"):format(lua))
  check(status == 0 or status == true, "save_editor_mod_tests suite")
end

-- ---------------------------------------------- parity workstream tests
-- Each tests/parity_*.lua is a self-contained file (own bootstrap + check,
-- error()s if any assertion fails).  Globbed, so dropping a new parity
-- file into tests/ is enough to make it run.
runSuites(orderedGlob("tests/parity_*.lua", {
  "tests/parity_D.lua", "tests/parity_F.lua", "tests/parity_E.lua",
  "tests/parity_C.lua", "tests/parity_K.lua", "tests/parity_L.lua",
  "tests/parity_H.lua", "tests/parity_G.lua", "tests/parity_I_M.lua",
  "tests/parity_B.lua", "tests/parity_J.lua", "tests/parity_A.lua",
  "tests/parity_flavor.lua", "tests/parity_trainer_sight.lua",
  "tests/parity_static.lua", "tests/parity_trashcans.lua",
  "tests/parity_hof.lua", "tests/parity_trade_gift.lua",
  "tests/parity_intro.lua", "tests/parity_tilt.lua",
  "tests/parity_gbcfx.lua",
}))

-- ---------------------------------------------- the globbed tiers
-- content_red (T3, the Red-pinned facts split out of this file),
-- engine (T2, invariants over the fixture dataset) and modkit (T4, the
-- public mod API) each stand a loader up per suite -- and a second
-- Builtins.install over a Data this process already merged raises -- so
-- every one of their suites gets its own process, the way
-- save_editor_mod_tests already does above.  Chaining the three runners
-- here keeps `luajit tests/run_tests.lua` the single green bar it has
-- always been; scripts/test.sh also runs them directly.
do
  local lua = (arg and arg[-1]) or "luajit"
  for _, tier in ipairs({ "tests/run_content_red.lua",
      "tests/run_engine.lua", "tests/run_modkit.lua" }) do
    local handle = io.open(tier, "r")
    if handle then
      handle:close()
      local status = os.execute(("%q %s > /dev/null 2>&1"):format(lua, tier))
      check(status == 0 or status == true, tier:match("([^/]+)%.lua$") .. " tier")
    end
  end
end

local failures = T.failures
print(("\n%s"):format(failures == 0 and "ALL TESTS PASSED" or failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
