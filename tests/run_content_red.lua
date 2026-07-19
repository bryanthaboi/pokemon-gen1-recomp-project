-- T3 content-parity tier: the facts that are true of Pokemon Red and of
-- nothing else.  Needs an imported ROM (data/generated/), so CI skips it
-- and scripts/test.sh only runs it when the generated data is present.
-- A total conversion swaps this directory for its own content_<mod>/.
--   luajit tests/run_content_red.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

require("tests.tier_runner").main({ "tests/content_red" }, "content_red")
