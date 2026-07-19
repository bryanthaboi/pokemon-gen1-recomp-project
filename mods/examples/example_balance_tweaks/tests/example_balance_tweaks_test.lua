-- Standalone: luajit mods/examples/example_balance_tweaks/tests/example_balance_tweaks_test.lua
-- Loads the mod through the real headless loader and asserts its stated
-- effect against the player's imported dataset.
package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local Data = require("src.core.Data")
Data:load()

local run = T.sdk.loadMod("mods/examples/example_balance_tweaks", { data = Data })
T.eq(#run.errors, 0, "loads clean (" .. tostring(run.errors[1]) .. ")")
T.eq(run.mod and run.mod.state, "loaded", "reached the loaded state")

T.eq(Data.pokemon.VENUSAUR.baseStats.speed, 100, "VENUSAUR speed patched")
T.eq(Data.pokemon.BLASTOISE.baseStats.speed, 100, "BLASTOISE speed patched")
-- the patch named one leaf, so everything else survived
T.check(#Data.pokemon.VENUSAUR.learnset > 0, "VENUSAUR keeps its learnset")
T.eq(Data.pokemon.VENUSAUR.types[1], "GRASS", "VENUSAUR keeps its types")

T.eq(Data.items.TM_TOXIC.price, 2000, "TM price halved")
T.eq(Data.items.POTION.price, 300, "a non-TM item is untouched")

T.eq(Data.encounters.ROUTE_1.grass.rate, 20, "Route 1 grass rate patched")
T.eq(Data.encounters.ROUTE_1.grass.slots[3].species, "SPEAROW",
  "Route 1 slot table re-slotted")

run.release()
T.finish("example_balance_tweaks")
