-- #114: launcher must restore the arrow cursor when leaving for boot.
-- Self-contained: `luajit tests/rom_importer_cursor_test.lua`; also dofile'd
-- by tests/run_tests.lua.
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end

local S = require("tests.harness").suite("rom importer cursor")
local eq = S.eq

local currentCursor = "arrow"
love.mouse.isCursorSupported = function() return true end
love.mouse.getSystemCursor = function(name) return name end
love.mouse.setCursor = function(c) currentCursor = c or "arrow" end

local RomImporter = require("src.import.RomImporter")

local booted = nil
local ri = setmetatable({
  android = false,
  workState = nil,
  ready = { red = true, blue = false },
  onComplete = function(version) booted = version end,
}, RomImporter)

-- Simulate leaving Play while the hand cursor is still active (hover).
currentCursor = "hand"
ri:play("red")
eq(booted, "red", "play boots the chosen version")
eq(currentCursor, "arrow", "play restores the arrow cursor before boot")

-- Android / unsupported cursors must not error.
booted = nil
currentCursor = "hand"
ri.android = true
ri:play("red")
eq(booted, "red", "android play still boots")
eq(currentCursor, "hand", "android play leaves the cursor alone")

S.finish()
