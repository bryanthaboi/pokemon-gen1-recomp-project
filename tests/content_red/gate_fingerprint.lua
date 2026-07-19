-- T3: the vanilla fingerprint gate (21-testing-and-ci "the fingerprint
-- gate", local variant).
--
-- The fixture gate in tests/engine/ proves the mechanism; this one pins
-- the number that actually matters for players -- the digest two vanilla
-- Red builds must agree on to link.  If a change to a built-in registry
-- record moves this hash, every existing build stops linking with every
-- new one, silently.  That is a parity change, and it has to be a
-- deliberate one: re-bless with scripts/test.sh --bless only after
-- recording it in the tri-ledger (docs/known-differences.md or
-- docs/new-features.md).

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local Fingerprint = require("src.link.Fingerprint")

local GOLDEN = "tests/goldens/vanilla_fingerprint.txt"

local Data = require("src.core.Data")
Data:load()

local run = T.sdk.loadNone({ data = Data })
T.eq(#run.errors, 0, "the generated dataset loads with no mods and no errors")

local actual = Fingerprint.compute(Data, {})

local handle = io.open(GOLDEN, "r")
T.check(handle ~= nil, "the committed vanilla fingerprint golden exists: " .. GOLDEN)
if handle then
  local golden = handle:read("*l")
  handle:close()
  golden = golden and golden:gsub("%s+$", "")
  T.eq(actual, golden, "the vanilla link fingerprint matches the committed golden")
end

-- the digest must not depend on anything but the data: recomputing it has
-- to give the same answer, or two builds of the same commit disagree
T.eq(Fingerprint.compute(Data, {}), actual, "the vanilla fingerprint is stable")

-- a link-affecting mod must move it, which is what makes a modded peer
-- detectable at handshake time
T.neq(Fingerprint.compute(Data, { { id = "x", version = "1.0.0", affectsLink = true } }),
  actual, "a link-affecting mod moves the vanilla fingerprint")

run.release()

T.finish("content_red_gate_fingerprint")
