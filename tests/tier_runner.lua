-- Shared tier runner: globs a directory and runs each suite, reporting a
-- machine-readable failure count (21-testing-and-ci §CI, "the hard-coded
-- parity chain is replaced by directory globbing").
--
-- Each suite gets its own process.  That is not fastidiousness: the engine
-- is one-loader-per-dataset (a second Builtins.install over the same Data
-- re-registers every built-in id and raises) and Runtime holds
-- process-wide buses, so suites that each stand up a loader cannot share
-- an interpreter.  run_tests.lua already isolates one suite this way for
-- exactly that reason.
--
-- Globbing means a suite drops into the directory and runs -- no array to
-- edit -- which is the whole point of the reorganization.  Files starting
-- with "_" are helpers, not suites.

local Runner = {}

local function interpreter()
  -- arg[-1] is how the suite was invoked (luajit here, lua5.4 elsewhere)
  return (arg and arg[-1]) or "luajit"
end

function Runner.suites(dir)
  local files = {}
  local pipe = io.popen(("ls -1 '%s'/*.lua 2>/dev/null"):format(dir))
  if not pipe then return files end
  for line in pipe:lines() do
    local name = line:match("[^/]+$")
    -- "_" prefixes helpers; facts.lua is the tier's pinned-value table
    -- (a content_<mod>/facts.lua is data the suites read, not a suite)
    if name and name:sub(1, 1) ~= "_" and name ~= "facts.lua" then
      files[#files + 1] = line
    end
  end
  pipe:close()
  table.sort(files)
  return files
end

-- runs every suite in `dirs`, prints one line per suite, returns the
-- number that failed
function Runner.run(dirs, label)
  local lua = interpreter()
  local failed, total = 0, 0

  for _, dir in ipairs(dirs) do
    for _, path in ipairs(Runner.suites(dir)) do
      total = total + 1
      local status = os.execute(("%s %s"):format(lua, path))
      local ok = status == 0 or status == true
      if ok then
        print("ok   " .. path)
      else
        failed = failed + 1
        print("FAIL " .. path)
      end
    end
  end

  print(("\n%s: %d/%d suites passed"):format(label, total - failed, total))
  print(("%s"):format(failed == 0 and "ALL TESTS PASSED" or failed .. " FAILURES"))
  return failed, total
end

function Runner.main(dirs, label)
  local failed = Runner.run(dirs, label)
  os.exit(failed == 0 and 0 or 1)
end

return Runner
