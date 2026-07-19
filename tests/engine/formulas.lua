-- T2 engine-invariant tier (21-testing-and-ci "test taxonomy"): the
-- formulas and machinery, parameterized by whatever dataset is loaded.
--
-- Nothing here names a Red value.  Every assertion is a property that has
-- to hold for any dataset the engine can boot -- which is what lets it run
-- in CI against tests/fixture_data with no ROM, and lets a total
-- conversion keep the whole tier green.  The pinned Red numbers live in
-- tests/content_red/ instead.

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")

local data = T.fixtures.fresh()
local run = T.sdk.loadNone({ data = data })
T.eq(#run.errors, 0, "the dataset under test loads with no mods and no errors")

local Pokemon = require("src.pokemon.Pokemon")
local Growth = require("src.pokemon.Growth")
local TypeChart = require("src.battle.TypeChart")
local Damage = require("src.battle.Damage")

TypeChart.load(data)

local speciesIds = {}
for id in pairs(data.pokemon) do speciesIds[#speciesIds + 1] = id end
table.sort(speciesIds)
T.check(#speciesIds > 0, "the dataset has at least one species")

-- ------- growth curves

-- the curve is an inverse pair; a dataset that ships a curve the level
-- lookup cannot invert breaks every exp gain in the game
for _, id in ipairs(speciesIds) do
  local def = data.pokemon[id]
  local rate = def.growthRate
  T.eq(Growth.expForLevel(rate, 1), 0, "level 1 costs no exp: " .. tostring(rate))

  local previous = -1
  local monotonic = true
  for level = 1, data.constants.levelCap do
    local need = Growth.expForLevel(rate, level)
    if need < previous then monotonic = false end
    previous = need
  end
  T.check(monotonic, "exp requirement never decreases with level: " .. tostring(rate))

  -- levelForExp is the inverse: standing exactly on a threshold reports
  -- that level, one point short reports the one below
  local mid = math.max(2, math.floor(data.constants.levelCap / 2))
  local atMid = Growth.expForLevel(rate, mid)
  T.eq(Growth.levelForExp(rate, atMid), mid,
    "levelForExp inverts expForLevel at a threshold: " .. tostring(rate))
  if atMid > 0 then
    T.check(Growth.levelForExp(rate, atMid - 1) < mid,
      "one exp short of a threshold is the level below: " .. tostring(rate))
  end
end

-- ------- stats

for _, id in ipairs(speciesIds) do
  local low = Pokemon.new(data, id, 5)
  local high = Pokemon.new(data, id, math.min(50, data.constants.levelCap))

  T.check(low.stats.hp > 0, "a fresh mon has positive max HP: " .. id)
  T.eq(low.hp, low.stats.hp, "a fresh mon starts at full HP: " .. id)
  T.check(#low.moves > 0, "a fresh mon knows at least one move: " .. id)
  T.check(#low.moves <= data.constants.moveMax,
    "a fresh mon never exceeds the move cap: " .. id)

  for _, stat in ipairs({ "hp", "attack", "defense", "speed", "special" }) do
    T.check(high.stats[stat] >= low.stats[stat],
      ("%s never decreases with level: %s"):format(stat, id))
  end

  -- level is clamped to the dataset's cap, not to a literal 100
  local capped = Pokemon.new(data, id, data.constants.levelCap)
  T.eq(capped.level, data.constants.levelCap, "a mon can reach the dataset's level cap: " .. id)
end

-- ------- type chart

-- categories come out of the loaded type records, not a hard-coded
-- physical/special split; this is the de-hard-coded seam from 07
local typeIds = {}
for id in pairs(data.type_chart.types or {}) do typeIds[#typeIds + 1] = id end
table.sort(typeIds)
T.check(#typeIds > 0, "the dataset supplies type category records")

for _, id in ipairs(typeIds) do
  local category = TypeChart.category(id)
  T.check(category == "physical" or category == "special",
    ("every type declares a damage category: %s (%s)"):format(id, tostring(category)))
  T.eq(Damage.isSpecial(id), category == "special",
    "Damage.isSpecial agrees with the loaded type record: " .. id)
end

-- every matchup the dataset declares is reachable through effectiveness,
-- and neutral is the default for an undeclared pair
for _, row in ipairs(data.type_chart.matchups or {}) do
  local mult = TypeChart.effectiveness(row.attacker, { row.defender })
  T.eq(mult, row.multiplier,
    ("declared matchup applies: %s vs %s"):format(row.attacker, row.defender))
end

do
  local declared = {}
  for _, row in ipairs(data.type_chart.matchups or {}) do
    declared[row.attacker .. ">" .. row.defender] = true
  end
  local checkedNeutral = false
  for _, attacker in ipairs(typeIds) do
    for _, defender in ipairs(typeIds) do
      if not declared[attacker .. ">" .. defender] and not checkedNeutral then
        T.eq(TypeChart.effectiveness(attacker, { defender }), 10,
          ("an undeclared matchup is neutral: %s vs %s"):format(attacker, defender))
        checkedNeutral = true
      end
    end
  end
  T.check(checkedNeutral, "the dataset has at least one undeclared (neutral) matchup")
end

-- ------- damage

do
  local ruleset = { critIgnoresStages = true }
  local attacker = Pokemon.new(data, speciesIds[1], 20)
  local defender = Pokemon.new(data, speciesIds[#speciesIds], 20)

  local function battler(mon)
    return { mon = mon, curStats = mon.stats, stages = {}, level = mon.level,
             curTypes = data.pokemon[mon.species].types }
  end

  local moveId = next(data.moves)
  local move = data.moves[moveId]

  -- max roll is deterministic under a fixed rng, and damage is never zero
  -- for a damaging move nor negative for any input
  local dealt = Damage.compute(ruleset, battler(attacker), battler(defender), move,
    { rng = T.rng.fixed(255), forceCrit = false })
  T.check(dealt >= 1, "a damaging move always deals at least 1: " .. moveId)

  local minRoll = Damage.compute(ruleset, battler(attacker), battler(defender), move,
    { rng = T.rng.fixed(0), forceCrit = false })
  T.check(minRoll <= dealt, "the low damage roll never exceeds the high roll")
  T.check(minRoll >= 1, "even the low roll deals at least 1")

  -- a crit is never weaker than the same non-crit roll
  local crit = Damage.compute(ruleset, battler(attacker), battler(defender), move,
    { rng = T.rng.fixed(255), forceCrit = true })
  T.check(crit >= dealt, "a critical hit never deals less than a normal hit")

  -- a zero-power move deals nothing regardless of the roll
  local status = { id = "T_STATUS", power = 0, type = move.type, category = "status" }
  local none, info = Damage.compute(ruleset, battler(attacker), battler(defender), status,
    { rng = T.rng.fixed(255) })
  T.eq(none, 0, "a zero-power move deals no damage")
  T.eq(info.typeMult, 10, "a zero-power move reports neutral effectiveness")
end

run.release()

T.finish("engine_formulas")
