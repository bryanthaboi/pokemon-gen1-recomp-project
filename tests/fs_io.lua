-- io-backed filesystem for the headless Loader (21-testing-and-ci
-- "headless loader seam").  Loader.new takes opts.fs; under plain luajit
-- there is no love.filesystem, so this adapter reads a real mod directory
-- off disk and lets discovery/topo-sort/merge run with no love at all.
--
-- Paths handed to the loader are repo-relative ("mods/example_mew_starter"),
-- the same strings love.filesystem would see, so a mod loaded through here
-- and one loaded in the game take identical code paths.

local FsIo = {}

-- shell-quote for the popen/os.execute probes; single quotes survive
-- spaces and the ' inside a name closes-escapes-reopens
local function quote(path)
  return "'" .. tostring(path):gsub("'", "'\\''") .. "'"
end

function FsIo.new(rootDir)
  local base = rootDir or "."

  local function abs(path)
    if path == nil or path == "" then return base end
    return base .. "/" .. path
  end

  local fs = {}

  function fs.read(path)
    local handle = io.open(abs(path), "rb")
    if not handle then return nil, "nofile" end
    local body = handle:read("*a")
    handle:close()
    return body
  end

  function fs.write(path, body)
    local handle = io.open(abs(path), "wb")
    if not handle then return false end
    handle:write(body)
    handle:close()
    return true
  end

  -- files answer without a shell; only the directory case pays for a probe
  function fs.getInfo(path)
    local handle = io.open(abs(path), "rb")
    if handle then
      local probe = handle:read(1)
      handle:close()
      -- a directory opens on some libc builds but reads nothing
      if probe ~= nil then return { type = "file" } end
    end
    local ok = os.execute("test -d " .. quote(abs(path)))
    if ok == true or ok == 0 then return { type = "directory" } end
    if handle then return { type = "file" } end
    return nil
  end

  function fs.load(path)
    return loadfile(abs(path))
  end

  function fs.getDirectoryItems(path)
    local items = {}
    local pipe = io.popen("ls -1 " .. quote(abs(path)) .. " 2>/dev/null")
    if not pipe then return items end
    for line in pipe:lines() do
      if line ~= "" then items[#items + 1] = line end
    end
    pipe:close()
    table.sort(items)
    return items
  end

  fs.root = base
  return fs
end

return FsIo
