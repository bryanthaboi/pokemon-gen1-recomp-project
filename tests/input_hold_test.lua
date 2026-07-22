-- Same-frame press→release and multi-source hold regressions for Input.lua.
-- Self-contained: `luajit tests/input_hold_test.lua`; also dofile'd by
-- tests/run_tests.lua.
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end

local S = require("tests.harness").suite("input hold")
local check = S.check
local Input = require("src.core.Input")

Input:init()

-- Quick tap before the next FixedStep must edge-fire without leaving isDown.
Input:keypressed("up")
Input:keyreleased("up")
Input:step()
check(Input:wasPressed("up"), "same-frame tap still edges wasPressed")
check(not Input:isDown("up"), "same-frame tap does not stick isDown")

Input:reset()
Input:keypressed("up")
Input:step()
check(Input:wasPressed("up"), "held press edges wasPressed")
check(Input:isDown("up"), "held press keeps isDown across step")
Input:step()
check(not Input:wasPressed("up"), "hold does not re-edge next step")
check(Input:isDown("up"), "hold stays down next step")
Input:keyreleased("up")
check(not Input:isDown("up"), "release clears isDown")

-- W and Up both map to up; releasing one must not drop the other.
Input:reset()
Input:keypressed("w")
Input:keypressed("up")
Input:step()
Input:keyreleased("w")
check(Input:isDown("up"), "second source keeps up held after first release")
Input:keyreleased("up")
check(not Input:isDown("up"), "last source release clears up")

-- Stick flick on→off before step must not stick.
Input:reset()
Input:gamepadaxis(nil, "leftx", -0.9)
Input:gamepadaxis(nil, "leftx", 0)
Input:step()
check(Input:wasPressed("left"), "stick flick edges wasPressed")
check(not Input:isDown("left"), "stick flick does not stick isDown")

-- Drivers that only inject pressQueue still get a one-step hold.
Input:reset()
table.insert(Input.pressQueue, "down")
Input:step()
check(Input:wasPressed("down"), "synthetic pressQueue edges wasPressed")
check(Input:isDown("down"), "synthetic pressQueue sets isDown")

S.finish()
