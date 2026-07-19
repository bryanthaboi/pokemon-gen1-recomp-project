-- The mod-SDK test harness (21-testing-and-ci "modkit test harness").
--
-- This is the whole public surface a mod's tests/ directory compiles
-- against, and the same code the engine's own T4 cases use.  A mod author
-- with a checkout of the engine and no ROM writes:
--
--   local T = require("tests.modkit")
--   local Data = T.fixtures.load()
--   local r = T.sdk.loadMod("mods/rare_soda", { data = Data })
--   T.check(#r.errors == 0, "mod loads clean")
--   T.finish()
--
-- Requiring this installs the love stub as the global `love`, because
-- everything below the fixture line touches it.  The love-free T1 tier
-- requires tests.harness directly instead.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?.lua;./?/init.lua;" .. package.path
end

if not _G.love then _G.love = require("tests.love_stub") end

local T = require("tests.harness")

local M = {}

-- assertions and the exit contract come straight off the shared harness,
-- so a mod's suite and an engine suite report identically
M.harness = T
M.check, M.eq, M.neq = T.check, T.eq, T.neq
M.same, M.raises = T.same, T.raises
M.rng = T.rng
M.finish = function(label) return T.finish(label or "modkit") end

function M.failures() return T.failures end

M.love = _G.love
M.fs = require("tests.fs_io")
M.fixtures = require("tests.modkit.fixtures")
M.sdk = require("tests.modkit.sdk")
M.record = require("tests.modkit.record")
M.link = require("tests.modkit.link")
M.shots = require("tests.modkit.shots")
M.catalog = require("tests.modkit.catalog")

-- drivers pull in tests/drivers/util.lua, which only makes sense inside a
-- real LOVE run; keep it lazy so a headless case never pays for it
setmetatable(M, { __index = function(_, key)
  if key == "drivers" then
    local drivers = require("tests.modkit.drivers")
    rawset(M, "drivers", drivers)
    return drivers
  end
  return nil
end })

return M
