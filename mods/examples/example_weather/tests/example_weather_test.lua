-- Standalone: luajit mods/examples/example_weather/tests/example_weather_test.lua
-- Drives the battle.damage hook through the runtime bus, both with the
-- ruleset on and with it off.
package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local Runtime = require("src.mods.Runtime")
local Data = require("src.core.Data")
Data:load()

local run = T.sdk.loadMod("mods/examples/example_weather", { data = Data })
T.eq(#run.errors, 0, "loads clean (" .. tostring(run.errors[1]) .. ")")

local weather = Data.rulesets.example_weather_battles
T.check(weather ~= nil, "the ruleset merged and is selectable")
T.eq(weather.name, "WEATHER", "the ruleset carries a display name")
T.eq(weather.oneIn256Miss, Data.rulesets.gen1_faithful.oneIn256Miss,
  "the derived ruleset keeps every gen1_faithful rule")
T.check(Data.statuses.EXAMPLE_RAIN ~= nil, "the rain status record merged")

-- the vanilla stand-in the hook wraps; 100 damage and an info table
local function vanilla() return 100, { crit = false, typeMult = 10 } end

local function hit(ruleset, moveType)
  return Runtime.call("battle.damage", vanilla,
    { ruleset = ruleset, move = { type = moveType } })
end

-- ------- ruleset off: the mod is installed and changes nothing

Runtime.emit("battle.started", { battle = { ruleset = Data.rulesets.gen1_faithful } })
T.eq(hit(Data.rulesets.gen1_faithful, "WATER"), 100,
  "gen1_faithful is untouched with the mod installed")
T.eq(hit(Data.rulesets.gen1_faithful, "FIRE"), 100,
  "FIRE is untouched under gen1_faithful too")

-- ------- ruleset on: rain scales WATER up and FIRE down

Runtime.emit("battle.started", { battle = { ruleset = weather } })
T.eq(hit(weather, "WATER"), 150, "rain boosts WATER damage")
T.eq(hit(weather, "FIRE"), 50, "rain dampens FIRE damage")
T.eq(hit(weather, "NORMAL"), 100, "every other type is untouched")

local damage, info = hit(weather, "WATER")
T.eq(damage, 150, "the scaled damage is the first return")
T.check(info ~= nil and info.typeMult == 10,
  "the info table survives the wrap")

-- ------- the counter runs out

for _ = 1, 5 do Runtime.emit("battle.turn_started", {}) end
T.eq(hit(weather, "WATER"), 100, "rain stops after its turn count")

Runtime.emit("battle.started", { battle = { ruleset = weather } })
T.eq(hit(weather, "WATER"), 150, "a new battle starts the rain again")
Runtime.emit("battle.ended", {})
T.eq(hit(weather, "WATER"), 100, "battle.ended clears the rain")

run.release()
T.finish("example_weather")
