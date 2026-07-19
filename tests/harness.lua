-- Shared test bootstrap (21-testing-and-ci D14).  Every suite used to
-- re-implement check/eq and its own failure counter; this is the single
-- copy.  Deliberately love-free so the T1 primitive suites keep proving
-- the engine's mod core runs with no love global at all -- tests/modkit
-- installs the stub for the tiers that need it.
--
-- Two shapes, because the repo runs suites two ways:
--
--   T.check/T.eq + T.finish()  -- a suite that owns its process (the
--     tests/engine, tests/content_red and tests/modkit/cases tiers, which
--     tier_runner spawns one at a time).  finish sets the exit code.
--   T.suite(label)             -- a suite tests/run_tests.lua dofiles into
--     its own process (the mod_*/parity_* files).  Scoped counters, and
--     finish raises rather than exiting so one bad suite is one FAIL line
--     in the parent instead of the end of the run.

-- suites are dofile'd from the repo root, and requiring this file already
-- needed the prefix, so only add it once
if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?.lua;./?/init.lua;" .. package.path
end

local T = {}

T.failures = 0
T.checks = 0
T.messages = {}

-- the seed the behavior suite has always used; suites that inject their
-- own rolls still do, this only pins the ambient stream
T.SEED = 12345
math.randomseed(T.SEED)

-- quiet mode prints only failures, so a 1600-check parent run stays
-- readable; verbose is the historical per-check "ok" stream
T.VERBOSE_ENV = os.getenv("POKEPORT_TEST_VERBOSE") == "1"
T.verbose = T.VERBOSE_ENV

-- One check is one line.  Suites embed captured subprocess output in a
-- message (modkit_tests folds a whole `modkit lint` transcript into one),
-- and a bare newline there puts an unrelated "FAIL ..." at column 0 --
-- which every line-oriented consumer of this output, scripts/test.sh
-- included, then counts as a failure of its own.
local function oneline(msg)
  return (tostring(msg):gsub("%s*\n%s*", " "))
end

-- structural compare for payload/record assertions; nil-holes compare equal
local function deep(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do if not deep(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

-- Every assertion is expressed against one `check`, so the module-level
-- API and a scoped suite share these bodies instead of keeping two copies
-- that can drift.
local function assertions(check)
  local A = { check = check }

  function A.eq(got, want, msg)
    return check(got == want,
      ("%s (got %s, want %s)"):format(tostring(msg), tostring(got), tostring(want)))
  end

  function A.neq(got, want, msg)
    return check(got ~= want, ("%s (got %s)"):format(tostring(msg), tostring(got)))
  end

  function A.same(got, want, msg)
    return check(deep(got, want), msg)
  end

  -- the seam under test is supposed to raise; assert it did and that the
  -- message names the reason, so a rename does not quietly pass
  function A.raises(fn, fragment, msg)
    local ok, err = pcall(fn)
    if ok then return check(false, msg .. " (no error raised)") end
    if fragment then
      return check(tostring(err):find(fragment, 1, true) ~= nil,
        ("%s (error was %s)"):format(msg, tostring(err)))
    end
    return check(true, msg)
  end

  return A
end

function T.check(cond, msg)
  T.checks = T.checks + 1
  if cond then
    if T.verbose then print("ok   " .. oneline(msg)) end
  else
    T.failures = T.failures + 1
    T.messages[#T.messages + 1] = oneline(msg)
    print("FAIL " .. oneline(msg))
  end
  return cond and true or false
end

do
  local A = assertions(function(cond, msg) return T.check(cond, msg) end)
  T.eq, T.neq, T.same, T.raises = A.eq, A.neq, A.same, A.raises
end

-- deterministic roll injection, the idiom the current suites hand-roll as
-- `{ rng = function() return 255 end }`
T.rng = {}

function T.rng.fixed(value)
  return function() return value end
end

function T.rng.seq(...)
  local values, i = { ... }, 0
  return function()
    i = i + 1
    return values[math.min(i, #values)]
  end
end

-- A scoped counter for the suites that run *inside* a parent's process.
-- tests/run_tests.lua dofiles the mod_*/parity_* files rather than
-- spawning one process each (tier_runner does that for the newer tiers),
-- so module-level counters would report the whole chained run as one
-- suite's total.  A scoped suite counts only its own checks, and its
-- finish raises instead of exiting -- os.exit here would take the parent
-- down with it, which is why every chained file ended in `error(...)`
-- before there was a harness to share.
function T.suite(label)
  local S = { label = label or "suite", failures = 0, checks = 0, messages = {} }

  -- A chained suite's stream is its own: the parent sets T.verbose for the
  -- checks it makes itself, and inheriting that would bury its progress
  -- under every assertion of twenty-odd child files.
  S.verbose = T.VERBOSE_ENV

  -- deliberately does not touch the module-level counters: the parent that
  -- dofiles this suite counts the suite as one check of its own, and
  -- folding the child's assertions in too would report every failure twice
  local function check(cond, msg)
    S.checks = S.checks + 1
    if cond then
      if S.verbose then print("ok   " .. oneline(msg)) end
    else
      S.failures = S.failures + 1
      S.messages[#S.messages + 1] = oneline(msg)
      print("FAIL " .. oneline(msg))
    end
    return cond and true or false
  end

  local A = assertions(check)
  S.check, S.eq, S.neq = A.check, A.eq, A.neq
  S.same, S.raises = A.same, A.raises
  S.rng = T.rng

  function S.finish()
    print(("%s: %d/%d checks passed"):format(S.label, S.checks - S.failures, S.checks))
    if S.failures > 0 then
      error(("%d %s assertion(s) failed (first: %s)")
        :format(S.failures, S.label, S.messages[1] or "?"), 0)
    end
  end

  return S
end

-- POKEPORT_TEST_CHILD is the escape hatch for a parent that dofiles a
-- process-owning suite rather than spawning it: raise instead of exiting,
-- so the parent survives.  T.suite is the better answer and nothing in the
-- repo sets this, but a mod's own runner may.
function T.finish(label)
  local name = label or "suite"
  if T.failures == 0 then
    print(("%d/%d checks passed  (%s)"):format(T.checks, T.checks, name))
  else
    print(("%d/%d checks passed, %d FAILURES  (%s)")
      :format(T.checks - T.failures, T.checks, T.failures, name))
  end
  if T.failures == 0 then
    if not _G.POKEPORT_TEST_CHILD then os.exit(0) end
    return
  end
  local first = T.messages[1] or "?"
  if _G.POKEPORT_TEST_CHILD then
    error(("%d failed (first: %s)"):format(T.failures, first), 0)
  end
  os.exit(1)
end

return T
