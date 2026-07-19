-- M6 battle extensibility: effect-record coverage and parity, statuses/
-- balls/rulesets/ai_classes consumption, move-field promotion, the battle
-- hooks and events, and the side/field substrate.  Self-contained like the
-- other mod suites: own bootstrap, assert-based checks, error() on failure.
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local Data = require("src.core.Data")
if not Data.maps then Data:load() end
local Font = require("src.render.Font")
Font.load(Data)

local BattleState = require("src.battle.BattleState")
local Catching = require("src.battle.Catching")
local Damage = require("src.battle.Damage")
local Events = require("src.mods.Events")
local Evolution = require("src.pokemon.Evolution")
local Experience = require("src.battle.Experience")
local Growth = require("src.pokemon.Growth")
local Hooks = require("src.mods.Hooks")
local MoveEffects = require("src.battle.MoveEffects")
local Pokemon = require("src.pokemon.Pokemon")
local Runtime = require("src.mods.Runtime")
local SaveData = require("src.core.SaveData")
local Status = require("src.battle.Status")
local TrainerAI = require("src.battle.TrainerAI")
local TurnOrder = require("src.battle.TurnOrder")
local TypeChart = require("src.battle.TypeChart")

TypeChart.load(Data)
local ruleset = require("src.battle.rulesets.gen1_faithful")

local S = require("tests.harness").suite("mod battle")
local check = S.check

local function mkseq(vals) -- scripted rng: pops vals, then max rolls
  local i = 0
  return function(a, b)
    i = i + 1
    return vals[i] ~= nil and vals[i] or b
  end
end

-- a stub stack keeps the queue pump self-contained (no UI rows in these
-- probes, so top() never has to return the battle)
local function makeGame(party)
  local save = SaveData.newGame()
  save.party = party
  local stack = { states = {} }
  function stack:push(state) self.states[#self.states + 1] = state end
  function stack:pop() return table.remove(self.states) end
  function stack:top() return self.states[#self.states] end
  return { data = Data, save = save, stack = stack,
           input = { wasPressed = function() return true end } }
end

local function pump(battle, limit)
  local steps = 0
  while steps < (limit or 6000) do
    steps = steps + 1
    if not battle:updateQueue() then break end
  end
end

local function hasText(battle, fragment)
  for _, item in ipairs(battle.queue) do
    if item.text and item.text:find(fragment, 1, true) then return true end
  end
  return false
end

-- fresh buses for the hook/event sections; restored at the bottom
local savedEvents, savedHooks = Runtime.events, Runtime.hooks
local events, hooks = Events.new(), Hooks.new()
Runtime.install(events, hooks)

-- ------- every vanilla move's effect resolves to a registered record

local effectCount, fullCount = 0, 0
for _, move in pairs(Data.moves) do
  if move.effect then
    local record = MoveEffects.RECORDS[move.effect]
    check(record ~= nil, "effect record exists for " .. move.effect)
    check(record.kind == "primary" or record.kind == "secondary"
          or record.kind == "full", "effect record kind valid for " .. move.effect)
  end
end
for _, record in pairs(MoveEffects.RECORDS) do
  effectCount = effectCount + 1
  if record.kind == "full" then fullCount = fullCount + 1 end
end
check(fullCount >= 25, "the 25 inline effects registered as full records")
check(effectCount >= 60, "primary/secondary/full records all registered")
check(MoveEffects.RECORDS.SWIFT_EFFECT.neverMiss == true, "Swift record never misses")
check(MoveEffects.RECORDS.OHKO_EFFECT.gate ~= nil, "OHKO record carries its gate")
check(MoveEffects.RECORDS.TWINEEDLE_EFFECT.kind == "full"
      and MoveEffects.RECORDS.TWINEEDLE_EFFECT.run ~= nil,
      "Twineedle is a full record with its secondary run")
check(MoveEffects.RECORDS.SLEEP_EFFECT.accuracyChecked == true
      and MoveEffects.RECORDS.ATTACK_UP1_EFFECT.accuracyChecked == nil,
      "accuracyChecked marks the MoveHitTest primaries")

-- ------- category-vs-isSpecial equivalence

local typeCount = 0
for id, record in pairs(TypeChart.TYPES) do
  typeCount = typeCount + 1
  check(Damage.isSpecial(id) == (record.category == "special"),
        "category matches isSpecial for " .. id)
end
check(typeCount == 15, "all 15 vanilla types checked")
check(TypeChart.displayName("PSYCHIC_TYPE") == "PSYCHIC", "type display name")

-- ------- record-driven parity probes

do
  -- fixed damage through the SPECIAL_DAMAGE record
  local game = makeGame({ Pokemon.new(Data, "BULBASAUR", 20) })
  local battle = BattleState.newWild(game, "SNORLAX", 30)
  battle.rng = mkseq({ 0 }) -- accuracy only: SONICBOOM rolls nothing else
  local before = battle.enemy.mon.hp
  battle:performMove(battle.player, battle.enemy, { id = "SONICBOOM", pp = 10 })
  check(before - battle.enemy.mon.hp == 20, "SONICBOOM deals a fixed 20")

  -- OHKO gate fails against a faster target
  local game2 = makeGame({ Pokemon.new(Data, "BULBASAUR", 5) })
  local slow = BattleState.newWild(game2, "RATTATA", 30)
  slow.rng = mkseq({})
  slow:performMove(slow.player, slow.enemy, { id = "FISSURE", pp = 5 })
  check(hasText(slow, "But, it failed!"), "OHKO fails against a faster target")
  check(slow.enemy.mon.hp == slow.enemy.mon.stats.hp, "no damage through a failed gate")
end

-- ------- a mod-registered move effect drives a battle

do
  local landed = false
  local effects = {}
  for id, record in pairs(MoveEffects.RECORDS) do effects[id] = record end
  effects.TEST_SIDE_EFFECT = { kind = "secondary", run = function(ctx)
    landed = true
    return { "It tingles!" }
  end }
  Data.move_effects = effects
  Data.moves.TEST_STRIKE = { id = "TEST_STRIKE", name = "TEST STRIKE",
    type = "NORMAL", power = 40, accuracy = 100, pp = 10,
    effect = "TEST_SIDE_EFFECT" }
  local game = makeGame({ Pokemon.new(Data, "BULBASAUR", 20) })
  local battle = BattleState.newWild(game, "SNORLAX", 30)
  battle.rng = mkseq({ 0, 255, 255 })
  battle:performMove(battle.player, battle.enemy, { id = "TEST_STRIKE", pp = 10 })
  check(landed, "a registered move effect runs post-damage")
  check(hasText(battle, "It tingles!"), "the effect's message is queued")
  check(battle.enemy.mon.hp < battle.enemy.mon.stats.hp,
        "an unknown-kind move still deals its damage")
  Data.move_effects = nil
  Data.moves.TEST_STRIKE = nil
end

-- ------- statuses registry: gauntlet, residual, HUD, catch bonus

do
  local statuses = {}
  for id, record in pairs(Status.RECORDS) do statuses[id] = record end
  statuses.FBT = {
    id = "FBT", label = "FBT", hudLabel = "FBT",
    catchBonus = 20, shakeBonus = 30,
    beforeMovePriority = 40,
    beforeMove = function(battler)
      return false, { battler.name .. "\nis frostbitten!" }
    end,
    residual = function(battler)
      battler.mon.hp = math.max(0, battler.mon.hp - 3)
      return { "The frostbite\nhurts!" }
    end,
  }
  Data.statuses = statuses
  local game = makeGame({ Pokemon.new(Data, "BULBASAUR", 20) })
  local battle = BattleState.newWild(game, "SNORLAX", 30)
  battle.enemy.mon.status = "FBT"
  local canMove, msgs = Status.beforeMove(battle.enemy, battle.rng, battle)
  check(canMove == false and msgs[1]:find("frostbitten", 1, true),
        "a registered status joins the beforeMove gauntlet")
  local hp = battle.enemy.mon.hp
  local residualMsgs = Status.residual(battle.enemy, battle.player, battle)
  check(battle.enemy.mon.hp == hp - 3 and #residualMsgs == 1,
        "a registered status joins the residual sweep")
  check(battle:statusLabel(battle.enemy.mon) == "FBT",
        "the HUD reads the registered hudLabel")

  -- the catch roll subtracts the registered catchBonus
  local mon = { status = "FBT", stats = { hp = 100 }, hp = 100 }
  local caught = Catching.attempt("POKE_BALL", mon, { catchRate = 0 },
    mkseq({ 19 }), nil, { statuses = statuses })
  check(caught == true, "registered catchBonus underflows the catch roll")
  local uncaught = Catching.attempt("POKE_BALL", mon, { catchRate = 0 },
    mkseq({ 19 }), nil, nil)
  check(uncaught == false, "an unknown status grants no catch bonus")

  -- the failure wobble adds the registered shakeBonus (fallback +5)
  local _, wobbles = Catching.attempt("POKE_BALL", mon, { catchRate = 50 },
    mkseq({ 100 }), nil, { statuses = statuses })
  check(wobbles == 2, "registered shakeBonus feeds the wobble math")
  local _, plain = Catching.attempt("POKE_BALL", mon, { catchRate = 50 },
    mkseq({ 100 }), nil, nil)
  check(plain == 1, "an unknown status falls back to the stock wobble bonus")
  Data.statuses = nil

  -- vanilla gauntlet parity without a battle on hand
  local sleeper = { mon = { status = "SLP" }, sleepTurns = 2, name = "SLEEPY" }
  local slpMove, slpMsgs = Status.beforeMove(sleeper, mkseq({}))
  check(slpMove == false and slpMsgs[1]:find("fast asleep", 1, true),
        "vanilla sleep runs through its record")
  local par = { mon = { status = "PAR" }, name = "ZAPPED" }
  local parMove = Status.beforeMove(par, mkseq({ 62 }))
  check(parMove == false, "full paralysis on a low roll")
  local parFree = Status.beforeMove(par, mkseq({ 63 }))
  check(parFree == true, "paralysis clears on a high roll")
end

-- ------- balls registry: record fields and the attempt override

do
  local calls = {}
  local rng = function(a, b)
    calls[#calls + 1] = { a, b }
    return b
  end
  local mon = { status = nil, stats = { hp = 100 }, hp = 100 }
  Catching.attempt("MOD_BALL", mon, { catchRate = 100 }, rng, nil,
    { ballDef = { randMax = 100, hpFactor = 12, wobbleFactor = 150 } })
  check(calls[1][2] == 100, "a registered ball's randMax bounds the roll")

  local auto = Catching.attempt("MOD_BALL", mon, { catchRate = 0 },
    function() error("autoCatch must not roll") end, nil,
    { ballDef = { randMax = 0, autoCatch = true } })
  check(auto == true, "autoCatch skips every roll")

  -- an attempt override doubles the rate then falls through to the math
  local caught = Catching.attempt("MOD_BALL", mon, { catchRate = 100 },
    mkseq({ 100, 85 }), nil,
    { ballDef = { randMax = 255, hpFactor = 12, wobbleFactor = 150,
      attempt = function(ctx)
        ctx.rateOverride = math.min(255, ctx.targetDef.catchRate * 2)
        return ctx.vanillaAttempt()
      end } })
  check(caught == true, "an attempt override rewrites the rate and delegates")

  -- toss/flicker resolve from the records
  local game = makeGame({ Pokemon.new(Data, "BULBASAUR", 20) })
  local battle = BattleState.newWild(game, "RATTATA", 5)
  check(battle:tossAnimFor("GREAT_BALL") == "GREATTOSS_ANIM", "toss arc from record")
  check(battle:ballFlicker("ULTRA_BALL") == true, "Ultra flickers")
  check(battle:ballFlicker("POKE_BALL") == false, "Poke ball does not flicker")
end

-- ------- rulesets from the merged registry

do
  Data.rulesets = {
    gen1_faithful = ruleset,
    test_rules = { name = "test_rules", oneIn256Miss = false,
      critUsesBaseSpeed = true, critIgnoresStages = true,
      randMin = 255, randMax = 255, focusEnergyBug = true },
  }
  local game = makeGame({ Pokemon.new(Data, "BULBASAUR", 20) })
  game.save.options = { ruleset = "test_rules" }
  local battle = BattleState.newWild(game, "RATTATA", 5)
  check(battle.ruleset.name == "test_rules", "battle picks the registered ruleset")
  game.save.options = { ruleset = "no_such_rules" }
  local fallback = BattleState.newWild(game, "RATTATA", 5)
  check(fallback.ruleset == ruleset, "unknown ruleset falls back to the default")
  Data.rulesets = nil
end

-- ------- options menu cycles the merged ruleset registry

do
  local OptionsMenu = require("src.ui.OptionsMenu")
  Data.rulesets = {
    gen1_faithful = ruleset,
    modern_clean = require("src.battle.rulesets.modern_clean"),
    aaa_rules = { name = "aaa rules" },
    zz_hidden = { name = "hidden rules", hidden = true },
  }
  local pressed = {}
  local game = { data = Data, save = SaveData.newGame(),
                 input = { wasPressed = function(_, key)
                   return pressed[key] or false
                 end },
                 stack = { pop = function() end } }
  local menu = OptionsMenu.new(game)
  menu.index = 4
  local function press(key)
    pressed = { [key] = true }
    menu:update(1 / 60)
    pressed = {}
  end
  check(game.save.options.ruleset == "gen1_faithful",
        "new saves start on the default ruleset")
  press("right")
  check(game.save.options.ruleset == "modern_clean",
        "right steps to the next sorted id")
  press("right")
  check(game.save.options.ruleset == "aaa_rules",
        "a mod-registered ruleset is selectable")
  press("right")
  check(game.save.options.ruleset == "gen1_faithful",
        "the cycle wraps and never offers the hidden record")
  press("left")
  check(game.save.options.ruleset == "aaa_rules", "left steps backwards")

  local drawn = {}
  local savedDraw = Font.draw
  Font.draw = function(text) drawn[#drawn + 1] = text end
  menu:draw()
  Font.draw = savedDraw
  local shown = false
  for _, text in ipairs(drawn) do
    if text == "aaa rules" then shown = true end
  end
  check(shown, "the row displays the record's name, not the id")
  Data.rulesets = nil
end

-- ------- ai_classes: brains and layer records

do
  Data.ai_classes = { OPP_YOUNGSTER = { brain = function(battle)
    return { id = "SPLASH", pp = 1, brained = true }
  end } }
  local game = makeGame({ Pokemon.new(Data, "BULBASAUR", 20) })
  local battle = BattleState.newTrainer(game, "OPP_YOUNGSTER", 1)
  local action = battle:enemyAction()
  check(action.brained == true, "a registered brain chooses the enemy action")

  Data.ai_classes = { LAYER_1 = { score = function(view, moveDef, score)
    if moveDef and moveDef.id == "TACKLE" then return score + 50 end
    return score
  end } }
  local aiMon = { curMoves = { { id = "TACKLE", pp = 10 },
                               { id = "GROWL", pp = 10 } } }
  local aiBattle = { enemyAIMods = { 1 }, data = Data,
                     player = { mon = {}, curTypes = { "NORMAL" } } }
  local pick = TrainerAI.chooseMove(aiMon, mkseq({}), aiBattle)
  check(pick.id == "GROWL", "a registered layer record rescores the choice")
  Data.ai_classes = nil

  local brock = TrainerAI.classFor({ trainer = { id = "OPP_BROCK" }, data = Data })
  check(brock and brock.item == "FULL_HEAL", "class lookup falls back to the data file")
end

-- ------- move-field promotion

do
  -- priority beats speed
  local slow = { curStats = { speed = 5 }, stages = {}, mon = {} }
  local fast = { curStats = { speed = 99 }, stages = {}, mon = {} }
  check(TurnOrder.firstMover(slow, { id = "X", priority = 1 }, fast,
          { id = "TACKLE" }, mkseq({})) == true,
        "move.priority wins the turn order")
  check(TurnOrder.firstMover(slow, { id = "QUICK_ATTACK" }, fast,
          { id = "TACKLE" }, mkseq({})) == true,
        "legacy priority ids keep resolving")

  -- highCrit matches the legacy table's boosted rate
  local battler = { def = { baseStats = { speed = 128 } } }
  local function critCount(moveId, highCrit)
    local n = 0
    for i = 0, 255 do
      if Damage.critRoll(ruleset, battler, moveId, function() return i end,
                         highCrit) then
        n = n + 1
      end
    end
    return n
  end
  check(critCount("TACKLE", true) == critCount("SLASH", nil),
        "highCrit = true matches the legacy high-crit list")
  check(critCount("TACKLE", nil) == 64, "an unmarked move keeps the normal rate")

  -- fixedDamage field through the SPECIAL_DAMAGE record
  Data.moves.TEST_FIX = { id = "TEST_FIX", name = "TEST FIX", type = "NORMAL",
    power = 1, accuracy = 100, pp = 10, effect = "SPECIAL_DAMAGE_EFFECT",
    fixedDamage = 15 }
  local game = makeGame({ Pokemon.new(Data, "BULBASAUR", 20) })
  local battle = BattleState.newWild(game, "SNORLAX", 30)
  battle.rng = mkseq({ 0 })
  local before = battle.enemy.mon.hp
  battle:performMove(battle.player, battle.enemy, { id = "TEST_FIX", pp = 10 })
  check(before - battle.enemy.mon.hp == 15, "fixedDamage field sets the damage")
  Data.moves.TEST_FIX = nil

  -- chargeText and semiInvulnerable fields
  Data.moves.TEST_CHARGE = { id = "TEST_CHARGE", name = "TEST CHARGE",
    type = "NORMAL", power = 40, accuracy = 100, pp = 10,
    effect = "CHARGE_EFFECT", chargeText = "%s\nis winding up!",
    semiInvulnerable = true }
  local cb = BattleState.newWild(makeGame({ Pokemon.new(Data, "BULBASAUR", 20) }),
                                 "RATTATA", 5)
  cb.rng = mkseq({})
  local inst = { id = "TEST_CHARGE", pp = 10 }
  cb:performMove(cb.player, cb.enemy, inst)
  check(cb.player.charging == inst, "charge record starts the charge turn")
  check(cb.player.invulnerable == true, "semiInvulnerable field goes invulnerable")
  check(hasText(cb, "is winding up!"), "chargeText field picks the text")
  Data.moves.TEST_CHARGE = nil

  -- counterable field replaces the Normal/Fighting whitelist
  local counterGame = makeGame({ Pokemon.new(Data, "BULBASAUR", 20) })
  local counter = BattleState.newWild(counterGame, "SNORLAX", 30)
  counter.rng = mkseq({ 0 })
  counter.lastDamage = 30
  counter.enemy.lastMove = "WATER_GUN"
  counter:performMove(counter.player, counter.enemy, { id = "COUNTER", pp = 10 })
  check(hasText(counter, "attack missed!"), "a Water move is not counterable")
  Data.moves.WATER_GUN.counterable = true
  local counter2 = BattleState.newWild(counterGame, "SNORLAX", 30)
  counter2.rng = mkseq({ 0 })
  counter2.lastDamage = 30
  counter2.enemy.lastMove = "WATER_GUN"
  local hp = counter2.enemy.mon.hp
  counter2:performMove(counter2.player, counter2.enemy, { id = "COUNTER", pp = 10 })
  check(hp - counter2.enemy.mon.hp == 60, "counterable = true doubles the last damage")
  Data.moves.WATER_GUN.counterable = nil

  -- multiHit field: a plain count consumes no distribution roll
  Data.moves.TEST_MULTI = { id = "TEST_MULTI", name = "TEST MULTI",
    type = "NORMAL", power = 15, accuracy = 100, pp = 10,
    effect = "TWO_TO_FIVE_ATTACKS_EFFECT", multiHit = 2 }
  local mh = BattleState.newWild(makeGame({ Pokemon.new(Data, "BULBASAUR", 20) }),
                                 "SNORLAX", 30)
  mh.rng = mkseq({ 0, 255, 255 })
  mh:performMove(mh.player, mh.enemy, { id = "TEST_MULTI", pp = 10 })
  check(hasText(mh, "Hit the enemy\n2 times!"), "multiHit = 2 lands two hits")
  Data.moves.TEST_MULTI = nil
end

-- ------- constants: badge boosts and exp tuning

do
  local function plain(badges, boosts)
    return { curStats = { attack = 10, defense = 10, speed = 10, special = 10 },
             stages = {}, curTypes = {}, badges = badges, badgeBoosts = boosts,
             name = "TEST", mon = { level = 10 },
             def = { baseStats = { speed = 10 } } }
  end
  local physTest = { id = "PHYS", power = 100, type = "NORMAL", accuracy = 100 }
  local maxRoll = { rng = function() return 255 end, forceCrit = false }
  local rows = { { badge = "ZAPBADGE", stat = "attack", num = 2, den = 1 } }
  local boosted = Damage.compute(ruleset, plain({ ZAPBADGE = true }, rows),
                                 plain(nil), physTest, maxRoll)
  check(boosted == 26, "a registered badge boost row rescales the stat")
  local speedRows = { { badge = "ZAPBADGE", stat = "speed", num = 2, den = 1 } }
  check(TurnOrder.effectiveSpeed(plain({ ZAPBADGE = true }, speedRows)) == 20,
        "a registered speed boost row reaches TurnOrder")

  local rat = Data.pokemon.RATTATA
  check(Experience.gainFor(rat, 10, false, 1, false, { exp = { divisor = 14 } })
        == math.floor(rat.baseExp * 10 / 14),
        "constants.exp.divisor retunes the exp formula")
  check(Experience.gainFor(rat, 10, false, 1, false) ==
        math.floor(rat.baseExp * 10 / 7), "no constants keeps the /7 formula")
  check(Growth.levelForExp("MEDIUM_FAST", 100000000, 50) == 50,
        "levelForExp honors the level cap")
end

-- ------- growth rates registry

do
  local rates = { TESTCURVE = { expForLevel = function(n) return n * 100 end } }
  check(Growth.expForLevel("TESTCURVE", 3, rates) == 300,
        "a registered curve resolves through the rates table")
  check(Growth.levelForExp("TESTCURVE", 500, 100, rates) == 5,
        "levelForExp walks a registered curve")
  check(Growth.expForLevel("MEDIUM_FAST", 10) == 1000,
        "vanilla curves unchanged without a rates table")
end

-- ------- evolution methods and the evolution.check hook

do
  local egame = { data = {
    pokemon = { TESTMON = { evolutions = {
      { method = "LEVEL", level = 5, species = "RAICHU" } } } },
  } }
  local mon = { species = "TESTMON", level = 10 }
  local species = Evolution.pendingFor(egame, mon, { kind = "levelup" })
  check(species == "RAICHU", "LEVEL method fires through pendingFor")
  check(Evolution.pendingFor(egame, mon, { kind = "trade" }) == nil,
        "a trade trigger does not fire LEVEL")

  local unsub = hooks:wrap("evolution.check", function() return false end)
  check(Evolution.pendingFor(egame, mon, { kind = "levelup" }) == nil,
        "evolution.check can cancel an evolution")
  unsub()
  check(Evolution.pendingFor(egame, mon, { kind = "levelup" }) == "RAICHU",
        "unhooked dispatch is vanilla again")

  local fgame = { data = {
    pokemon = { TESTMON = { evolutions = {
      { method = "FRIENDSHIP", species = "RAICHU" } } } },
    evolution_methods = { FRIENDSHIP = { check = function(g, m, evo, trigger)
      return trigger.kind == "levelup" and (m.friendship or 0) >= 200
    end } },
  } }
  local buddy = { species = "TESTMON", level = 5, friendship = 250 }
  check(Evolution.pendingFor(fgame, buddy, { kind = "levelup" }) == "RAICHU",
        "a registered evolution method fires")
  buddy.friendship = 0
  check(Evolution.pendingFor(fgame, buddy, { kind = "levelup" }) == nil,
        "the registered method's own gate holds")
end

-- ------- the rare-candy flow runs the hook-wrapped dispatch

do
  local Bag = require("src.inventory.Bag")
  local BagMenu = require("src.ui.BagMenu")

  local pressed = {}
  local function uiGame(party)
    local save = SaveData.newGame()
    save.party = party
    local stack = { states = {} }
    function stack:push(state) self.states[#self.states + 1] = state end
    function stack:pop() return table.remove(self.states) end
    function stack:top() return self.states[#self.states] end
    return { data = Data, save = save, stack = stack,
             input = { wasPressed = function(_, key)
                         return pressed[key] or false
                       end,
                       isDown = function() return false end } }
  end

  -- feed one candy through the real bag UI: press A through the item
  -- list, USE, the party pick, the level text, the stat box and any
  -- evolution text until every state has popped
  local function candyFlow()
    local mon = Pokemon.new(Data, "CHARMANDER", 15)
    local game = uiGame({ mon })
    Bag.add(game.save, "RARE_CANDY", 1)
    game.stack:push(BagMenu.new(game))
    for _ = 1, 600 do
      local top = game.stack:top()
      if not top then break end
      pressed = { a = true }
      top:update(1)
      pressed = {}
    end
    check(game.stack:top() == nil, "the candy flow runs to completion")
    return mon
  end

  local fed = candyFlow()
  check(fed.level == 16, "the candy levels the mon")
  check(fed.species == "CHARMELEON", "the level evolution fires afterwards")

  local unsub = hooks:wrap("evolution.check", function() return false end)
  local blocked = candyFlow()
  check(blocked.level == 16, "the cancel hook leaves the level gain alone")
  check(blocked.species == "CHARMANDER",
        "evolution.check gates the rare-candy evolution")
  unsub()
end

-- ------- battle hooks: pass-through, transform, isolation

do
  local function tackleProbe()
    local game = makeGame({ Pokemon.new(Data, "BULBASAUR", 10) })
    local battle = BattleState.newWild(game, "SNORLAX", 30)
    battle.rng = mkseq({ 0, 255, 255 })
    local before = battle.enemy.mon.hp
    battle:performMove(battle.player, battle.enemy, { id = "TACKLE", pp = 10 })
    return before - battle.enemy.mon.hp
  end

  local baseline = tackleProbe()
  check(baseline > 0, "baseline tackle deals damage")
  check(tackleProbe() == baseline, "unhooked damage is deterministic")

  local unsub = hooks:wrap("battle.damage", function(nextFn, ctx)
    local dmg, info = nextFn(ctx)
    return dmg * 2, info
  end)
  check(tackleProbe() == baseline * 2, "battle.damage hook doubles the damage")
  unsub()
  check(tackleProbe() == baseline, "unwrapped damage is vanilla again")

  unsub = hooks:wrap("battle.damage", function() error("boom") end)
  check(tackleProbe() == baseline, "a throwing damage wrapper is skipped")
  unsub()

  unsub = hooks:wrap("battle.crit", function() return true end)
  local game = makeGame({ Pokemon.new(Data, "BULBASAUR", 10) })
  local critBattle = BattleState.newWild(game, "SNORLAX", 30)
  critBattle.rng = mkseq({ 0, 255 }) -- accuracy, damage; the hook owns the crit
  critBattle:performMove(critBattle.player, critBattle.enemy, { id = "TACKLE", pp = 10 })
  check(hasText(critBattle, "Critical hit!"), "battle.crit hook forces a crit")
  unsub()

  unsub = hooks:wrap("battle.accuracy", function() return false end)
  local missBattle = BattleState.newWild(game, "SNORLAX", 30)
  missBattle.rng = mkseq({})
  missBattle:performMove(missBattle.player, missBattle.enemy, { id = "TACKLE", pp = 10 })
  check(hasText(missBattle, "attack missed!"), "battle.accuracy hook forces a miss")
  unsub()

  unsub = hooks:wrap("catch.rate", function() return true, 3 end)
  local catchBattle = BattleState.newWild(game, "SNORLAX", 30)
  catchBattle.rng = mkseq({})
  local caught, shakes = catchBattle:catchAttempt("POKE_BALL")
  check(caught == true and shakes == 3, "catch.rate hook decides the catch")
  unsub()

  unsub = hooks:wrap("exp.gain", function(nextFn, ctx)
    return nextFn(ctx) * 2
  end)
  local mon = Pokemon.new(Data, "BULBASAUR", 10)
  local expBefore = mon.exp
  local _, gained = Experience.apply(Data, mon, Data.pokemon.RATTATA, 10,
                                     false, 1, false)
  check(gained == Experience.gainFor(Data.pokemon.RATTATA, 10, false, 1, false) * 2,
        "exp.gain hook doubles the award")
  check(mon.exp == expBefore + gained, "the doubled award is what lands")
  unsub()

  local sawOrder = false
  unsub = hooks:wrap("battle.turn_order", function(nextFn, a, aMove, b, bMove, ctx)
    sawOrder = true
    return nextFn(a, aMove, b, bMove, ctx)
  end)
  local orderGame = makeGame({ Pokemon.new(Data, "BULBASAUR", 10) })
  local orderBattle = BattleState.newWild(orderGame, "RATTATA", 5)
  orderBattle.rng = mkseq({})
  orderBattle:resolveTurn(orderBattle.player.curMoves[1])
  check(sawOrder, "battle.turn_order hook wraps the order roll")
  unsub()

  unsub = hooks:wrap("battle.run", function() return true end)
  local runGame = makeGame({ Pokemon.new(Data, "CATERPIE", 3) })
  local runBattle = BattleState.newWild(runGame, "RATTATA", 30)
  runBattle.rng = mkseq({ 0 })
  runBattle:tryRun()
  check(runBattle.result == "run", "battle.run hook forces the escape")
  unsub()

  unsub = hooks:wrap("battle.enemy_action", function()
    return { id = "TACKLE", pp = 1, hooked = true }
  end)
  local actGame = makeGame({ Pokemon.new(Data, "BULBASAUR", 10) })
  local actBattle = BattleState.newWild(actGame, "RATTATA", 5)
  check(actBattle:enemyAction().hooked == true,
        "battle.enemy_action hook rewrites the choice")
  unsub()
end

-- ------- battle events: the scripted sequence

do
  local log = {}
  local function listen(name)
    events:on(name, function(payload)
      log[#log + 1] = { name = name, payload = payload }
    end)
  end
  for _, name in ipairs({ "battle.started", "battle.turn_started",
      "battle.turn_ended", "battle.move_used", "battle.damage_dealt",
      "battle.fainted", "battle.exp_gained", "battle.ended",
      "battle.status_inflicted", "battle.ball_thrown", "pokemon.caught",
      "battle.battler_switched" }) do
    listen(name)
  end
  local function indexOf(name)
    for i, entry in ipairs(log) do
      if entry.name == name then return i end
    end
    return nil
  end

  local game = makeGame({ Pokemon.new(Data, "BULBASAUR", 50) })
  local battle = BattleState.newWild(game, "RATTATA", 2)
  battle.onFinish = function() end
  battle:enter()
  check(indexOf("battle.started") ~= nil, "battle.started fires on enter")
  check(log[indexOf("battle.started")].payload.kind == "wild",
        "battle.started carries the kind")
  battle.rng = function(a) return a end -- min rolls: the move always hits
  battle:resolveTurn(battle.player.curMoves[1])
  pump(battle)
  battle:finish()
  check(indexOf("battle.turn_started") ~= nil, "battle.turn_started fires")
  check(indexOf("battle.move_used") ~= nil, "battle.move_used fires")
  check(indexOf("battle.damage_dealt") ~= nil, "battle.damage_dealt fires")
  check(indexOf("battle.fainted") ~= nil, "battle.fainted fires")
  check(indexOf("battle.turn_ended") ~= nil, "battle.turn_ended fires")
  check(indexOf("battle.exp_gained") ~= nil, "battle.exp_gained fires")
  check(indexOf("battle.ended") ~= nil, "battle.ended fires")
  check(indexOf("battle.started") < indexOf("battle.turn_started")
        and indexOf("battle.turn_started") < indexOf("battle.move_used")
        and indexOf("battle.move_used") < indexOf("battle.damage_dealt")
        and indexOf("battle.damage_dealt") < indexOf("battle.fainted")
        and indexOf("battle.fainted") < indexOf("battle.ended"),
        "the battle events fire in order")

  -- status_inflicted on a landing Thunder Wave
  local waveGame = makeGame({ Pokemon.new(Data, "BULBASAUR", 10) })
  local wave = BattleState.newWild(waveGame, "RATTATA", 5)
  wave.rng = mkseq({ 254 })
  wave:performMove(wave.player, wave.enemy, { id = "THUNDER_WAVE", pp = 10 })
  local inflicted = indexOf("battle.status_inflicted")
  check(inflicted ~= nil and log[inflicted].payload.status == "PAR",
        "battle.status_inflicted carries the status")

  -- ball_thrown + pokemon.caught (box destination, no UI rows)
  local party = {}
  for _ = 1, 6 do party[#party + 1] = Pokemon.new(Data, "PIDGEY", 5) end
  local catchGame = makeGame(party)
  catchGame.save.pokedex.owned.RATTATA = true
  local catchBattle = BattleState.newWild(catchGame, "RATTATA", 3)
  catchBattle.onFinish = function() end
  catchBattle.rng = function(a) return a end
  catchBattle.queue = {}
  catchBattle:throwBall("POKE_BALL")
  pump(catchBattle)
  local thrown = indexOf("battle.ball_thrown")
  check(thrown ~= nil and log[thrown].payload.caught == true,
        "battle.ball_thrown reports the outcome")
  local caughtIdx = indexOf("pokemon.caught")
  check(caughtIdx ~= nil, "pokemon.caught fires")
  check(log[caughtIdx].payload.ball == "POKE_BALL"
        and log[caughtIdx].payload.destination == "box",
        "pokemon.caught carries ball and destination")

  -- battler_switched on a mid-battle switch
  local swGame = makeGame({ Pokemon.new(Data, "BULBASAUR", 20),
                            Pokemon.new(Data, "PIDGEY", 20) })
  local swBattle = BattleState.newWild(swGame, "RATTATA", 5)
  swBattle.rng = mkseq({})
  swBattle:resolveSwitch(swGame.save.party[2])
  pump(swBattle)
  local switched = indexOf("battle.battler_switched")
  check(switched ~= nil and log[switched].payload.side.index == 1,
        "battle.battler_switched names the side")
end

-- ------- side/field substrate

do
  local game = makeGame({ Pokemon.new(Data, "BULBASAUR", 20) })
  local battle = BattleState.newWild(game, "RATTATA", 5)
  battle:syncSides()
  check(battle.sides[1].battlers[1] == battle.player
        and battle.sides[2].battlers[1] == battle.enemy,
        "sides mirror the singles battlers")
  check(battle:sideOf(battle.enemy).index == 2, "sideOf maps by side")
  check(battle.field.sides == battle.sides and battle.field.weather == nil,
        "the field substrate starts empty")

  local residuals, expired = 0, false
  table.insert(battle.sides[2].tokens, { id = "test", turns = 2,
    onResidual = function() residuals = residuals + 1 end,
    onExpire = function() expired = true end })
  table.insert(battle.field.tokens, { id = "haze", turns = 1,
    onExpire = function() end })
  battle.rng = mkseq({})
  battle:endOfTurn()
  check(residuals == 1 and not expired, "side tokens tick each end of turn")
  check(#battle.field.tokens == 0, "an expired field token is removed")
  battle:endOfTurn()
  check(expired and #battle.sides[2].tokens == 0,
        "a side token expires after its turns run out")
end

Runtime.install(savedEvents, savedHooks)

S.finish()
