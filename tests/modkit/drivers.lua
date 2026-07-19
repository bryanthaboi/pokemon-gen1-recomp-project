-- The frame-driver helper kit, published as require-able SDK API
-- (21-testing-and-ci "golden screenshots").
--
-- tests/drivers/util.lua stays where it is: 22 committed driver scripts
-- reach it with dofile("tests/drivers/util.lua") and a POKEPORT_DRIVER
-- chunk runs before package.path is anyone's problem.  This module is the
-- require-able face of the same table, so a mod's driver can say
--   local U = require("tests.modkit.drivers")
-- and get wait/tap/hold/shot/newGame/teleport with no path juggling.

local ok, util = pcall(dofile, "tests/drivers/util.lua")
if not ok then
  error("tests/modkit/drivers requires tests/drivers/util.lua (run from the repo root): "
    .. tostring(util), 0)
end

return util
