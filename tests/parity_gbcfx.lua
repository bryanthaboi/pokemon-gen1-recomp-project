-- Parity test,  GBC FX ladder (Pixel Transparency shader).
-- Unit-tests the Lua-side API of src/render/GBCFX.lua headless under the
-- love stub: level clamping, the OFF→1→2→3→4→OFF cycle, options plumbing,
-- level labels, and that active()/present() degrade gracefully when the
-- stub offers no love.graphics.newShader (shader() returns nil).
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
local fails, total = 0, 0
local function check(c, m) total = total + 1; if c then print("ok   " .. m) else fails = fails + 1; print("FAIL " .. m) end end
local function eq(g, w, m) check(g == w, ("%s (got %s, want %s)"):format(m, tostring(g), tostring(w))) end

-- === assertions ===

local GBCFX = require("src.render.GBCFX")

-- defaults
eq(GBCFX.level, 0, "gbcfx starts at level 0 (OFF)")
eq(#GBCFX.LABELS, 5, "five labels (OFF + 4 levels)")
eq(GBCFX.LABELS[1], "OFF", "first label is OFF")

-- setLevel clamps and floors
GBCFX.setLevel(2)
eq(GBCFX.level, 2, "setLevel stores an in-range level")
GBCFX.setLevel(-3)
eq(GBCFX.level, 0, "setLevel clamps below to 0")
GBCFX.setLevel(99)
eq(GBCFX.level, 4, "setLevel clamps above to 4")
GBCFX.setLevel(2.9)
eq(GBCFX.level, 2, "setLevel floors fractional levels")
GBCFX.setLevel("3")
eq(GBCFX.level, 3, "setLevel accepts numeric strings")
GBCFX.setLevel(nil)
eq(GBCFX.level, 0, "setLevel(nil) resets to OFF")
GBCFX.setLevel("junk")
eq(GBCFX.level, 0, "setLevel(non-numeric) resets to OFF")

-- cycle wraps OFF→1→2→3→4→OFF and returns the new level
GBCFX.setLevel(0)
eq(GBCFX.cycle(), 1, "cycle OFF -> 1")
eq(GBCFX.cycle(), 2, "cycle 1 -> 2")
eq(GBCFX.cycle(), 3, "cycle 2 -> 3")
eq(GBCFX.cycle(), 4, "cycle 3 -> 4")
eq(GBCFX.cycle(), 0, "cycle 4 wraps to OFF")
eq(GBCFX.level, 0, "cycle leaves the wrapped level stored")

-- applyOptions reads opts.gbcfx
GBCFX.applyOptions({ gbcfx = 3 })
eq(GBCFX.level, 3, "applyOptions reads opts.gbcfx")
GBCFX.applyOptions({})
eq(GBCFX.level, 0, "applyOptions without gbcfx resets to OFF")
GBCFX.setLevel(2)
GBCFX.applyOptions(nil)
eq(GBCFX.level, 0, "applyOptions(nil) resets to OFF")

-- labels
eq(GBCFX.levelLabel(0), "OFF", "label for level 0")
eq(GBCFX.levelLabel(1), "1", "label for level 1")
eq(GBCFX.levelLabel(4), "4", "label for level 4")
GBCFX.setLevel(3)
eq(GBCFX.levelLabel(), "3", "levelLabel() defaults to the current level")
eq(GBCFX.levelLabel(42), "OFF", "out-of-range label falls back to OFF")

-- headless: the love stub has no newShader, so the shader never compiles
eq(GBCFX.shader(), nil, "shader() is nil headless")
GBCFX.setLevel(4)
check(not GBCFX.active(), "active() is false headless even at level 4")

-- present() falls back to a plain draw when the shader is unavailable
local drawn = nil
local g = love.graphics
local oldDraw, oldSetColor = g.draw, g.setColor
g.draw = function(c, x, y) drawn = { c, x, y } end
g.setColor = g.setColor or function() end
local canvas = {}
local ok, err = pcall(GBCFX.present, canvas, 5)
g.draw = oldDraw
g.setColor = oldSetColor
check(ok, "present() does not error headless (" .. tostring(err) .. ")")
check(drawn and drawn[1] == canvas and drawn[2] == 0 and drawn[3] == 0,
      "present() falls back to a plain draw at (0,0)")

GBCFX.setLevel(0)

-- === summary ===
print(("%d/%d checks passed"):format(total - fails, total))
if fails > 0 then error(("parity_gbcfx: %d checks failed"):format(fails)) end
