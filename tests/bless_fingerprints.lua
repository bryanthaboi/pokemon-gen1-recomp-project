-- Re-pin the fingerprint goldens (21-testing-and-ci "the fingerprint
-- gate": "regenerated only by an explicit scripts/test.sh --bless after a
-- documented, intended parity change").
--
-- Blessing is deliberate.  The fingerprint is the number two builds must
-- agree on to link, so moving it breaks linking between every existing
-- build and every new one -- that is a parity change, and the tri-ledger
-- (docs/known-differences.md / docs/new-features.md) is where it gets
-- recorded before this is run.
--
--   luajit tests/bless_fingerprints.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local Fingerprint = require("src.link.Fingerprint")

local function write(path, value)
  local handle = io.open(path, "w")
  if not handle then
    io.stderr:write("cannot write " .. path .. "\n")
    os.exit(1)
  end
  handle:write(value, "\n")
  handle:close()
  print(("blessed %s -> %s"):format(path, value))
end

os.execute("mkdir -p tests/goldens")

-- the fixture golden always exists: it needs no ROM
do
  local data = T.fixtures.fresh()
  local run = T.sdk.loadNone({ data = data })
  write("tests/goldens/fixture_fingerprint.txt", Fingerprint.compute(data, {}))
  run.release()
end

-- the vanilla golden only when a ROM has been imported
do
  local probe = io.open("data/generated/maps.lua", "r")
  if not probe then
    print("skipped tests/goldens/vanilla_fingerprint.txt (no data/generated/)")
    return
  end
  probe:close()

  local Data = require("src.core.Data")
  Data:load()
  local run = T.sdk.loadNone({ data = Data })
  write("tests/goldens/vanilla_fingerprint.txt", Fingerprint.compute(Data, {}))
  run.release()
end
