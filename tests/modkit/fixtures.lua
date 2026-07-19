-- Data-shaped view of tests/fixture_data (21-testing-and-ci "fixture
-- dataset").  The T2/T4/T5 tiers run against this instead of
-- data/generated/*, which is what makes them ROM-free and therefore
-- CI-runnable.
--
-- The returned table carries its own module tables but inherits the Data
-- methods (resolveText/textEntry/trainerHeader/ensure) through __index, so
-- engine code that takes `data` as a parameter cannot tell it apart from a
-- real load.  The Data singleton is never touched: a fixture test and a
-- content_red test can run in the same process without either seeing the
-- other's tables.

local Data = require("src.core.Data")
local fixture = require("tests.fixture_data")

local Fixtures = {}

Fixtures.DIR = "tests/fixture_data"

local cached

-- a fresh dataset every call: the mod merge writes into the table it is
-- given, so a cached one would carry the previous case's registrations
function Fixtures.fresh()
  local data = fixture.load()
  setmetatable(data, { __index = Data })
  -- the same fill-if-absent pass a real Data:load runs before the mod
  -- loader, so constants/field.boot defaults exist to be patched over
  Data.seedDefaults(data)
  return data
end

-- idempotent handle for suites that only read; use fresh() when the case
-- loads mods
function Fixtures.load()
  if not cached then cached = Fixtures.fresh() end
  return cached
end

-- the ids a fixture case can rely on, so a case reads a name instead of
-- re-deriving it from the tables
Fixtures.ids = {
  species = { "FIXMON_A", "FIXMON_B", "FIXMON_C" },
  moves = { "FIX_TACKLE", "FIX_SCRATCH", "FIX_EMBERISH", "FIX_CUT" },
  maps = { "FIX_TOWN", "FIX_ROUTE" },
  tileset = "FIX_OUT",
}

return Fixtures
