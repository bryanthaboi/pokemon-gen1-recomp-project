-- Parity test,  Workstream G.
-- Covers: spinner arrow tile animation. pokered's
-- engine/overworld/spinners.asm LoadSpinnerArrowTiles VRAM-patches 4 fixed
-- tile IDs per tileset (Gym/Facility), flickering between the blur graphic
-- (gfx/overworld/spinners.2bpp) and the tileset's own static graphic once
-- per forced-movement step while wMovementFlags.BIT_SPINNING is set. This
-- checks (a) TileRenderer.SPINNER_ARROW_TILES ids are real walkable tile
-- ids on the GYM/FACILITY tilesets (data/tilesets/spinner_tiles.asm), and
-- (b) the headless-safe setSpinning()/spinBlurActive() toggle behavior.
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end
local fails, total = 0, 0
local function check(c, m) total = total + 1; if c then print("ok   " .. m) else fails = fails + 1; print("FAIL " .. m) end end
local function eq(g, w, m) check(g == w, ("%s (got %s, want %s)"):format(m, tostring(g), tostring(w))) end

local TileRenderer = require("src.render.TileRenderer")

-- === (a) SPINNER_ARROW_TILES ids are walkable metatile ids on the real
-- tilesets (data/tilesets/spinner_tiles.asm dest tile ids) ===
local function idInList(id, list)
  for _, v in ipairs(list) do
    if v == id then return true end
  end
  return false
end

check(TileRenderer.SPINNER_ARROW_TILES ~= nil, "TileRenderer exports SPINNER_ARROW_TILES")
if TileRenderer.SPINNER_ARROW_TILES then
  local gymWalkable = Data.tilesets.GYM.walkable
  for _, id in ipairs(TileRenderer.SPINNER_ARROW_TILES.GYM) do
    check(idInList(id, gymWalkable),
          ("GYM spinner tile 0x%x is walkable"):format(id))
  end
  local facilityWalkable = Data.tilesets.FACILITY.walkable
  for _, id in ipairs(TileRenderer.SPINNER_ARROW_TILES.FACILITY) do
    check(idInList(id, facilityWalkable),
          ("FACILITY spinner tile 0x%x is walkable"):format(id))
  end
end

-- === (b) setSpinning()/spinBlurActive() toggle (headless-safe: pure
-- state, no love.image dependency) ===
TileRenderer.setSpinning(false)
check(not TileRenderer.spinBlurActive(), "no arrow blur frame outside a spin")

TileRenderer.setSpinning(true)
local a = TileRenderer.spinBlurActive()
for i = 1, 8 do TileRenderer.tick() end
local b = TileRenderer.spinBlurActive()
check(a ~= b, "arrow blur frame toggles every ~8 ticks while spinning")

TileRenderer.setSpinning(false)
check(not TileRenderer.spinBlurActive(), "blur frame turns off once the spin ends")

print(("parity G: %d/%d passed"):format(total - fails, total))
if fails > 0 then error(fails .. " parity-G assertion(s) failed") end
