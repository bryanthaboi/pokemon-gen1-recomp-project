-- Standalone: luajit mods/examples/example_jukebox/tests/example_jukebox_test.lua
-- Asserts the song assembles, the cry merges, and music.select swaps only
-- the map this mod claims.
package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local Runtime = require("src.mods.Runtime")
local Data = require("src.core.Data")
Data:load()

local run = T.sdk.loadMod("mods/examples/example_jukebox", { data = Data })
T.eq(#run.errors, 0, "loads clean (" .. tostring(run.errors[1]) .. ")")

-- ------- the authored song

local song = Data.audio.songs.Music_ExamplePalletRain
T.check(type(song) == "table", "the song registered")
T.check(type(song.chip) == "table" and #song.chip.blob > 0,
  "it assembled to a non-empty program blob")
T.eq(#song.chip.channels, 2, "both channels are laid out")
T.eq(song.chip.channels[1].address, 0x4000,
  "the first channel is based at the 0x4000 window")

-- ------- the cry

local cry = Data.audio.cries.MEW
T.check(type(cry) == "table" and type(cry.chip) == "table",
  "the MEW cry is an authored chip program")
T.check(#cry.chip.blob > 0, "the cry program is non-empty")
T.eq(cry.chip.channels[1].number, 5,
  "an sfx program lives on the effect channels (5-8)")

-- ------- the hook swaps exactly one map

local function select(song_, ctx)
  return Runtime.call("music.select", function(chosen) return chosen end, song_, ctx)
end
T.eq(select("Music_PalletTown", { reason = "map", mapId = "PALLET_TOWN" }),
  "Music_ExamplePalletRain", "Pallet Town gets the new theme")
T.eq(select("Music_Routes1", { reason = "map", mapId = "ROUTE_1" }),
  "Music_Routes1", "every other map defers to the vanilla choice")
T.eq(select("Music_Battle", { reason = "battle", kind = "wild" }),
  "Music_Battle", "battle music defers too")
T.eq(select("Music_PalletTown", nil), "Music_PalletTown",
  "a direct play with no context defers")

-- ------- the screen and its options row

local Font = require("src.render.Font")
Font.load(Data)
local Screens = require("src.ui.Screens")
Screens.invalidate()
local factory = Screens.get({ data = Data }, "ExampleJukebox")
T.check(factory and factory.new, "the jukebox resolves through the screens registry")
local screen = factory.new({ data = Data })
T.check(#screen.items > 0, "the jukebox lists the merged music registry")
local listed = false
for _, item in ipairs(screen.items) do
  if item.value == "Music_ExamplePalletRain" then listed = true end
end
T.check(listed, "the mod's own song is in the list")

local rows = Runtime.call("ui.options.rows", function(_, r) return r end,
  { data = Data }, { { id = "text_speed" } })
T.eq(#rows, 2, "the options hook added exactly one row")
T.eq(rows[2].id, "example_jukebox", "the row is the jukebox entry")

run.release()
Screens.invalidate()
T.finish("example_jukebox")
