-- Headless mod load/merge for the SDK harness (21-testing-and-ci "modkit
-- test harness").  A mod author with a checkout of the engine and no ROM
-- can load their mod, merge it into the fixture dataset, and assert on the
-- result -- the seam that makes `modkit test` possible.
--
-- Loader:_discover hard-codes the root "mods", so loading exactly one mod
-- (or a mod that lives outside mods/) goes through an aliasing filesystem:
-- "mods/<name>" is rewritten to the real directory and the listing of
-- "mods" is narrowed to the selected set.  Everything else is the
-- production path -- same Loader, same validate, same topo-sort, same
-- merge -- so a green SDK test means the mod really loads in the game.

local FsIo = require("tests.fs_io")
local Loader = require("src.mods.Loader")
local Runtime = require("src.mods.Runtime")

local Sdk = {}

local function basename(path)
  return (tostring(path):gsub("/+$", ""):match("[^/]+$"))
end

-- rewrite "mods/<alias>" and anything under it to the mod's real location,
-- and answer getDirectoryItems("mods") with just the selected aliases
local function aliasFs(inner, alias)
  local fs = { root = inner.root }

  local function map(path)
    if path == nil then return path end
    for name, real in pairs(alias) do
      local prefix = "mods/" .. name
      if path == prefix then return real end
      if path:sub(1, #prefix + 1) == prefix .. "/" then
        return real .. path:sub(#prefix + 1)
      end
    end
    return path
  end

  function fs.read(path) return inner.read(map(path)) end
  function fs.write(path, body) return inner.write(map(path), body) end
  function fs.load(path) return inner.load(map(path)) end

  function fs.getInfo(path)
    if path == "mods" then return { type = "directory" } end
    return inner.getInfo(map(path))
  end

  function fs.getDirectoryItems(path)
    if path == "mods" then
      local names = {}
      for name in pairs(alias) do names[#names + 1] = name end
      table.sort(names)
      return names
    end
    return inner.getDirectoryItems(map(path))
  end

  return fs
end

-- flat path -> content filesystem, for cases that synthesize a mod rather
-- than committing one to disk
function Sdk.memfs(files)
  local loadstr = loadstring or load
  return {
    read = function(path) return files[path] end,
    write = function(path, body) files[path] = body return true end,
    getInfo = function(path)
      if files[path] then return { type = "file" } end
      local prefix = path .. "/"
      for key in pairs(files) do
        if key:sub(1, #prefix) == prefix then return { type = "directory" } end
      end
      return nil
    end,
    load = function(path)
      if not files[path] then return nil, "no file: " .. path end
      return loadstr(files[path], path)
    end,
    getDirectoryItems = function(path)
      local seen, items = {}, {}
      local prefix = path .. "/"
      for key in pairs(files) do
        if key:sub(1, #prefix) == prefix then
          local child = key:sub(#prefix + 1):match("^[^/]+")
          if child and not seen[child] then
            seen[child] = true
            items[#items + 1] = child
          end
        end
      end
      table.sort(items)
      return items
    end,
  }
end

-- Runtime is process-wide and Loader:load installs into it; a case that
-- forgets to put it back would leak its buses into the next suite
local saved

function Sdk.captureRuntime()
  saved = { events = Runtime.events, hooks = Runtime.hooks, errors = Runtime.errors }
end

function Sdk.restoreRuntime()
  if not saved then return end
  Runtime.events, Runtime.hooks, Runtime.errors = saved.events, saved.hooks, saved.errors
  Runtime.currentMod = nil
  saved = nil
end

-- opts.data   the merge target (defaults to a fresh fixture dataset)
-- opts.fs     override the filesystem entirely (e.g. Sdk.memfs)
-- opts.root   repo root the real paths are relative to
-- opts.dev    force the dev tripwire on
function Sdk.loadMods(paths, opts)
  opts = opts or {}
  local data = opts.data or require("tests.modkit.fixtures").fresh()

  local fs = opts.fs
  if not fs then
    local alias = {}
    for _, path in ipairs(paths) do alias[basename(path)] = path end
    fs = aliasFs(FsIo.new(opts.root or "."), alias)
  end

  Sdk.captureRuntime()
  local loader = Loader.new({ fs = fs, dev = opts.dev })
  local ok, err = pcall(loader.load, loader, data)
  if not ok then
    Sdk.restoreRuntime()
    error(err, 0)
  end

  local mods = {}
  for _, path in ipairs(paths) do
    for id, mod in pairs(loader.mods) do
      if mod.path == path or basename(mod.path) == basename(path) then mods[id] = mod end
    end
  end

  return {
    loader = loader,
    data = data,
    mods = mods,
    errors = loader.errors,
    -- release the buses; a case that wants them live calls keep()
    release = function() Sdk.restoreRuntime() end,
  }
end

function Sdk.loadMod(path, opts)
  local result = Sdk.loadMods({ path }, opts)
  result.mod = select(2, next(result.mods))
  return result
end

-- load nothing: the no-mod baseline every parity gate compares against
function Sdk.loadNone(opts)
  return Sdk.loadMods({}, opts)
end

return Sdk
