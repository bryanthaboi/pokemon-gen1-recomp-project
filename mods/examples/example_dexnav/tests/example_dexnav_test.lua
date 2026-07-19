-- Standalone: luajit mods/examples/example_dexnav/tests/example_dexnav_test.lua
-- Exercises the export surface, the start-menu wrap and the screen factory.
package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local Runtime = require("src.mods.Runtime")
local Data = require("src.core.Data")
Data:load()

local Font = require("src.render.Font")
Font.load(Data)

local run = T.sdk.loadMod("mods/examples/example_dexnav", { data = Data })
T.eq(#run.errors, 0, "loads clean (" .. tostring(run.errors[1]) .. ")")

local exports = run.loader.exports.example_dexnav
T.check(type(exports.countSeen) == "function", "countSeen is exported")
T.check(type(exports.species) == "function", "species is exported")
T.eq(#exports.species(), 151, "the export reads the whole merged dex")

local game = {
  data = Data,
  save = { pokedex = { seen = { PIKACHU = true, MEW = true },
                       owned = { PIKACHU = true } } },
}
T.eq(exports.countSeen(game), 2, "countSeen counts the seen set")
T.eq(exports.countOwned(game), 1, "countOwned counts the owned set")

-- an empty dex is a legal state, not a crash
T.eq(exports.countSeen({ data = Data, save = {} }), 0, "a fresh save counts zero")

-- ------- the start-menu wrap decorates rather than replaces

local vanilla = { { label = "POKéDEX" }, { label = "SAVE" }, { label = "QUIT" } }
local hooked = Runtime.call("ui.start_menu.items",
  function(_, items) return items end, game, vanilla)
T.eq(#hooked, 4, "the wrap added exactly one row")
T.eq(hooked[2].label, "DEXNAV", "the row is anchored before SAVE")
T.eq(hooked[3].label, "SAVE", "the vanilla rows are still in order")

-- ------- the screen factory builds a real state

local Screens = require("src.ui.Screens")
Screens.invalidate()
local factory = Screens.get(game, "ExampleDexNav")
T.check(factory and factory.new, "the screen resolves through the registry")
local screen = factory.new(game)
T.check(screen.items ~= nil and #screen.items == 151,
  "the list shows every species with SHOW UNSEEN on")
T.eq(screen.title, "DEXNAV 1/2", "the title carries the owned/seen counts")

run.release()
Screens.invalidate()
T.finish("example_dexnav")
