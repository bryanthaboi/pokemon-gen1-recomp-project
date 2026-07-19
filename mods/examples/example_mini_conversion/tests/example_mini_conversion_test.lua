-- Standalone: luajit mods/examples/example_mini_conversion/tests/example_mini_conversion_test.lua
-- Asserts the conversion owns the boot flow, the dex and the badge list.
package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local Data = require("src.core.Data")
Data:load()

local run = T.sdk.loadMod("mods/examples/example_mini_conversion", { data = Data })
T.eq(#run.errors, 0, "loads clean (" .. tostring(run.errors[1]) .. ")")
T.eq(run.mod and run.mod.manifest.profile, "total_conversion",
  "the manifest declares the total_conversion profile")

-- ------- boot: the new game the conversion starts

local boot = Data.field.boot
T.eq(boot.startMap, "SABLE_COVE", "boot spawns on the conversion's own map")
T.eq(boot.playerName, "SABLE", "boot renames the player")
T.eq(boot.screens.title, "SableTitle", "the conversion owns the title screen")
-- patch is a merge: the keys the conversion did not name keep their values
T.eq(boot.startFacing, "down", "an unnamed boot key survives the patch")

-- ------- the dex

T.eq(Data.constants.dexSize, 3, "the dex shrinks to three species")
T.eq(#Data.constants.badges, 1, "one badge replaces the eight")
T.eq(Data.constants.badges[1].id, "SABLE_TIDE_BADGE", "the badge is the mod's item")
T.check(Data.items.SABLE_TIDE_BADGE ~= nil, "the badge item merged")
-- constants is a deep registry, so untouched keys keep their imported value
T.eq(Data.constants.partyMax, 6, "an unpatched constant is unchanged")
-- and a deep list REPLACES only because the mod said override
T.eq(#Data.constants.hmMoves, 2, "override drops a deep list instead of appending")

for _, id in ipairs({ "SABLE_EMBERKIT", "SABLE_TIDEPUP", "SABLE_MOSSLING" }) do
  local mon = Data.pokemon[id]
  T.check(mon ~= nil, id .. " merged into the species table")
  T.check(Data.audio.cries[id] ~= nil, id .. " has a cry")
  T.check(Data.icons.bySpecies[id] ~= nil, id .. " has an icon")
  -- the art it points at really exists, not a path into the void.  Read it
  -- back through the loader's own filesystem: mod.path is whatever the
  -- loader mounted the mod at, which is not the repo-relative directory
  for _, path in ipairs({ mon.spriteFront, mon.spriteBack }) do
    T.check(run.loader.fs.getInfo(path) ~= nil,
      "sprite exists: " .. tostring(path))
  end
end

-- ------- the map and its encounters

local map = Data.maps.SABLE_COVE
T.check(map ~= nil, "the conversion's map merged")
T.eq(#map.blocks, map.width * map.height, "the block array matches the map size")
T.eq(#Data.encounters.SABLE_COVE.grass.slots, 10, "the map has a full slot table")

-- ------- the title screen resolves through the registry

local Screens = require("src.ui.Screens")
Screens.invalidate()
local factory = Screens.get({ data = Data }, "SableTitle")
T.check(factory and factory.new, "SableTitle resolves through the screens registry")
local reached = false
local state = factory.new({ data = Data, input = {
  wasPressed = function(_, key) return key == "a" end } },
  { onNewGame = function() reached = true end })
state:update()
T.check(reached, "pressing A on the title starts a new game")

run.release()
Screens.invalidate()
T.finish("example_mini_conversion")
