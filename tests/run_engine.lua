-- T2 engine-invariant tier: formulas and machinery parameterized by the
-- loaded dataset, plus the no-mod parity gates.  Runs against
-- tests/fixture_data, so it needs no ROM and is the tier CI leans on.
--   luajit tests/run_engine.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

require("tests.tier_runner").main({ "tests/engine" }, "engine")
