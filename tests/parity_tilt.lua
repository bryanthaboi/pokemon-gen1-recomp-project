-- Parity test,  overworld tilt mode.
-- Unit-tests src/render/Tilt.lua headless under the love stub: the
-- cycle/tween state machine (OFF/15/35/50), the free-roam input gate,
-- the groundPoint projection contract (identity at angle 0, monotonic
-- depth at a non-zero angle) and the world-view growth that keeps the
-- tilted plane covering the window.
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
local S = require("tests.harness").suite("parity tilt")
local check, eq = S.check, S.eq

-- === assertions ===

local Tilt = require("src.render.Tilt")

-- clean slate
Tilt.reset()
eq(Tilt.level, 0, "tilt starts at level 0 (OFF)")
eq(Tilt.enabled, false, "tilt starts disabled")
eq(Tilt.angle, 0, "tilt starts flat")
check(not Tilt.active(), "tilt inactive while flat and disabled")

-- cycle ON to 15° and run the ~0.25s ease-in tween to completion
Tilt.cycle()
eq(Tilt.level, 1, "first cycle selects 15°")
eq(Tilt.enabled, true, "cycle enables tilt")
check(Tilt.active(), "tilt active immediately after enabling")
eq(Tilt.TARGET_ANGLE, math.rad(15), "target is 15 degrees")
Tilt.update(0.05)
check(Tilt.angle > 0 and Tilt.angle < Tilt.TARGET_ANGLE,
      "tilt eases in to a partial angle")
for _ = 1, 20 do Tilt.update(0.05) end
check(math.abs(Tilt.angle - Tilt.TARGET_ANGLE) < 1e-9,
      "tilt reaches the 15° target")

-- cycle through 35 and 50
Tilt.cycle()
eq(Tilt.level, 2, "second cycle selects 35°")
for _ = 1, 20 do Tilt.update(0.05) end
check(math.abs(Tilt.angle - math.rad(35)) < 1e-9, "tilt reaches 35°")
Tilt.cycle()
eq(Tilt.level, 3, "third cycle selects 50°")
for _ = 1, 20 do Tilt.update(0.05) end
check(math.abs(Tilt.angle - math.rad(50)) < 1e-9, "tilt reaches 50°")

-- cycle back to OFF and tween out
Tilt.cycle()
eq(Tilt.level, 0, "fourth cycle returns to OFF")
eq(Tilt.enabled, false, "cycle disables tilt")
check(Tilt.active(), "tilt still active while tweening out")
for _ = 1, 20 do Tilt.update(0.05) end
eq(Tilt.angle, 0, "tilt returns exactly to flat")
check(not Tilt.active(), "tilt inactive once fully tweened out")

-- reset clears the state anytime, mid-tween
Tilt.cycle(); Tilt.update(0.1)
Tilt.reset()
eq(Tilt.enabled, false, "reset disables tilt")
eq(Tilt.level, 0, "reset zeroes the level")
eq(Tilt.angle, 0, "reset zeroes the angle")
eq(Tilt.t, 1, "reset leaves tween settled")
check(not Tilt.active(), "reset makes tilt inactive")

-- toggle is an alias for cycle
Tilt.reset()
Tilt.toggle()
eq(Tilt.level, 1, "toggle advances one level like cycle")

-- input gate mirrors survey zoom (free-roam overworld only)
local ow = { transitioning = false }
check(Tilt.gateOK(ow, ow), "gate open while free-roaming the overworld")
check(not Tilt.gateOK(nil, ow), "gate closed with no active state")
check(not Tilt.gateOK({}, ow), "gate closed when top is not the overworld")
ow.transitioning = true
check(not Tilt.gateOK(ow, ow), "gate closed during a transition")
ow.transitioning = false
ow.runner = { isRunning = function() return true end }
check(not Tilt.gateOK(ow, ow), "gate closed while a script runs")

-- groundPoint is the exact identity at angle 0
Tilt.reset()
local vw, vh = 240, 160
local gx, gy, gsc = Tilt.groundPoint(37, 91, vw, vh)
eq(gx, 37, "groundPoint identity X at angle 0")
eq(gy, 91, "groundPoint identity Y at angle 0")
eq(gsc, 1, "groundPoint identity depthScale at angle 0")

-- at 50°: focus row fixed, above recedes, below approaches
Tilt.setLevel(3)
Tilt.angle = Tilt.TARGET_ANGLE
Tilt.t = 1
local _, _, scMid = Tilt.groundPoint(vw / 2, vh / 2, vw, vh)
check(math.abs(scMid - 1) < 1e-9, "depthScale is 1 on the focus row")
local _, _, scTop = Tilt.groundPoint(vw / 2, vh * 0.25, vw, vh)
local _, _, scBot = Tilt.groundPoint(vw / 2, vh * 0.75, vw, vh)
check(scTop < 1, "rows above centre recede (depthScale < 1)")
check(scBot > 1, "rows below centre approach (depthScale > 1)")
do
  local last, mono = -1, true
  for row = 0, vh, 16 do
    local _, _, sc = Tilt.groundPoint(vw / 2, row, vw, vh)
    if sc <= last then mono = false end
    last = sc
  end
  check(mono, "depthScale increases monotonically top to bottom")
end

-- the projected corners still centre on the canvas centre (u = 0 point is
-- fixed) and carry their depthScale through as the mesh's per-vertex q
local corners = Tilt.meshCorners(vw, vh)
eq(#corners, 4, "meshCorners yields a 4-vertex quad")
eq(#corners[1], 5, "each corner is {sx, sy, u, v, depthScale}")

-- view-size growth: none when flat, grows (>= ~1/cos) while tilted
Tilt.reset()
eq(Tilt.viewGrowth(), 1, "no view growth while flat")
Tilt.setLevel(3)
Tilt.angle = Tilt.TARGET_ANGLE
Tilt.t = 1
check(Tilt.viewGrowth() >= 1 / math.cos(Tilt.TARGET_ANGLE) - 1e-9,
      "view grows at least ~1/cos(angle) while tilted")

local Renderer = require("src.render.Renderer")
Tilt.reset()
local baseW, baseH = Renderer:worldViewSize()
Tilt.setLevel(3)
Tilt.angle = Tilt.TARGET_ANGLE
Tilt.t = 1
local tiltW, tiltH = Renderer:worldViewSize()
check(tiltH > baseH, "world view grows vertically while tilted")
check(tiltW >= baseW, "world view does not shrink horizontally while tilted")
Tilt.reset()

-- === upright billboard pass ====================
-- The reworked model tilts ONLY the ground.  A standing thing draws upright
-- and UNSCALED -- pixel-identical to flat -- and the sole thing tilt changes
-- is its on-screen anchor: OverworldState:billboard slides the flat foot
-- (fx, fy) to where Tilt.groundPoint projects it, with a single translate and
-- NO scale (depthScale is ignored for sizing).  We record the transform ops
-- (colors = nil keeps it shader-free) to observe that one translate = the
-- projected-minus-flat offset, and that scale is never touched.
local OW = require("src.world.OverworldController")
local g = love.graphics
local realPush, realPop, realT, realS = g.push, g.pop, g.translate, g.scale
local rec
g.push = function() end
g.pop = function() end
g.translate = function(x, y) if rec then rec.t[#rec.t + 1] = { x, y } end end
g.scale = function(x, y) if rec then rec.s[#rec.s + 1] = { x, y } end end
local function record(fx, fy, bw, bh)
  rec = { t = {}, s = {} }
  OW.billboard({}, fx, fy, bw, bh, nil, false, function() end)
end

-- Billboards at the mild 15° level: approaching rows still project lower
-- (at steeper angles cos foreshortening can outweigh perspective growth).
Tilt.reset(); Tilt.setLevel(1); Tilt.angle = Tilt.TARGET_ANGLE; Tilt.t = 1
local bw, bh = 240, 160

-- the billboard never scales -- only the ground tilts
local function noScale() return #rec.s == 0 end

-- a foot on the focus row (viewport centre) is anchored unmoved (offset 0)
record(bw / 2, bh / 2, bw, bh)
eq(#rec.t, 1, "billboard emits a single translate (no scale, no re-origin)")
check(math.abs(rec.t[1][1]) < 1e-9 and math.abs(rec.t[1][2]) < 1e-9,
      "billboard leaves a centre foot unmoved")
check(noScale(), "billboard never scales a centre foot (only the ground tilts)")

-- a foot below centre: the translate slides it to exactly its groundPoint,
-- unscaled; it lands lower on screen (approaching row) but keeps its size
record(bw / 2, bh * 0.75, bw, bh)
local ex, ey = Tilt.groundPoint(bw / 2, bh * 0.75, bw, bh)
check(math.abs(rec.t[1][1] - (ex - bw / 2)) < 1e-9
      and math.abs(rec.t[1][2] - (ey - bh * 0.75)) < 1e-9,
      "billboard slides a below-centre foot onto its groundPoint")
check(ey > bh * 0.75, "a below-centre foot projects lower (approaching row)")
check(noScale(), "billboard never scales a below-centre foot")

-- a foot above centre is a receding row: it compresses toward the focus
-- centre (its projected y drifts down toward centre) but never past it,
-- and is still drawn unscaled
record(bw / 2, bh * 0.25, bw, bh)
local _, ay = Tilt.groundPoint(bw / 2, bh * 0.25, bw, bh)
check(ay > bh * 0.25 and ay < bh / 2,
      "an above-centre foot recedes toward the focus row (compresses inward)")
check(noScale(), "billboard never scales an above-centre foot")

rec = nil
g.push, g.pop, g.translate, g.scale = realPush, realPop, realT, realS

-- the upright canvas plumbing: flat frames never touch it, tilt frames
-- allocate one matching the world view for endFrame to composite
Tilt.reset()
Renderer:init()
Renderer:beginFrame(true)
eq(Renderer.uprightActive, false, "upright pass inactive on a fresh frame")
Renderer:beginWorldPass()
eq(Renderer.uprightActive, false, "world pass alone leaves the upright pass off")
Renderer:beginUprightPass()
eq(Renderer.uprightActive, true, "beginUprightPass activates the upright pass")
local uw, uh = Renderer.uprightCanvas:getWidth(), Renderer.uprightCanvas:getHeight()
local vpw, vph = Renderer:worldViewSize()
local M = Renderer.UPRIGHT_MARGIN
check(uw == vpw + 2 * M and uh == vph + 2 * M,
      "upright canvas is the world view grown by the edge margin on all sides")
Renderer:endUprightPass()
Tilt.reset()

-- === Ground-only revision: buildings/trees/fences/signs are map tiles, so
-- they draw into the ground canvas and tilt with it like grass or paths --
-- no per-tileset classification or per-structure extraction is needed.  A
-- real map's renderer must never carry the (now removed) upright-structure
-- extraction machinery.
local Data = require("src.core.Data")
Data:load()
local MapLoader = require("src.world.MapLoader")
MapLoader.clearCache()
local pallet = MapLoader.load(Data, "PALLET_TOWN")
check(pallet.renderer.structures == nil,
      "TileRenderer no longer extracts upright structures")
check(pallet.renderer.drawTilt == nil and pallet.renderer.drawTiltMapOnly == nil,
      "TileRenderer no longer has a separate tilt ground draw path")
MapLoader.clearCache()

S.finish()
