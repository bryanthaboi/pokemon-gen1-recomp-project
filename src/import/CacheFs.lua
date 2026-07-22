-- Routes ROM-derived cache I/O (data/generated, assets/generated and the
-- rom-cache.complete marker) to the right place.
--
-- Normally the cache lives in LÖVE's per-user OS save directory and is
-- written through love.filesystem.  In portable mode it lives in the game
-- folder next to the executable instead (the folder holding portable.txt --
-- see SaveData), so nothing is left on the host machine.  That folder is
-- written with raw io.* (love.filesystem can only write to the save dir) and
-- read back through love.filesystem, require and love.graphics.newImage --
-- which works because the folder is on the physfs read path:
--
--   * Source runs (`love <gamedir>`, what the Play-* launchers use): the
--     folder IS the physfs source, so it is already readable.
--   * Fused builds (the packaged .app/.exe): the folder sits next to the
--     executable and is NOT normally readable, so CacheFs mounts it onto the
--     read path via PhysFS.  love.filesystem.mount refuses external folders,
--     but the underlying PHYSFS_mount (exported from love's framework) allows
--     them; we call it through LuaJIT's FFI.
--
-- Directories in the portable folder are created with a plain mkdir syscall
-- via FFI rather than os.execute, so importing never flashes a console window
-- on Windows (issue #74 -- the old per-file `os.execute("mkdir")` froze the
-- app behind a storm of one-frame cmd.exe windows).
--
-- Portable mode is desktop-only (Windows/Linux/macOS); on Android/iOS the
-- source is a read-only package with no game folder to write into, so
-- SaveData.isPortable() is false there and this module falls back to the
-- ordinary love.filesystem/save-directory behaviour.

local CacheFs = {}

local SEP = package.config:sub(1, 1)

-- lazily-resolved windowless mkdir: function(absolutePath) or false when
-- FFI is unavailable (the cache then stays on the save directory)
local mkdirFn = nil

local function resolveMkdir()
  if mkdirFn ~= nil then return mkdirFn end
  mkdirFn = false
  local ok, ffi = pcall(require, "ffi")
  if not ok then return mkdirFn end
  if ffi.os == "Windows" then
    -- kernel32 is reliably resolvable through ffi.C on Windows (the engine
    -- already binds it in DiscordPresence); CreateDirectoryA returns
    -- nonzero on success and 0 when the directory already exists -- both
    -- fine, the result is ignored.
    pcall(ffi.cdef,
      "int CreateDirectoryA(const char *lpPathName, void *lpSecurityAttributes);")
    local resolved = pcall(function() return ffi.C.CreateDirectoryA end)
    if resolved then
      mkdirFn = function(path) pcall(ffi.C.CreateDirectoryA, path, nil) end
    end
  else
    pcall(ffi.cdef, "int mkdir(const char *pathname, unsigned int mode);")
    local resolved = pcall(function() return ffi.C.mkdir end)
    if resolved then
      mkdirFn = function(path) pcall(ffi.C.mkdir, path, 493) end -- 0755
    end
  end
  return mkdirFn
end

-- Mount an external directory onto the physfs read path (appended, so the
-- game's own source always wins a name clash).  Returns true on success.
-- Guarded and lazily bound like the mkdir helper; PHYSFS_mount is exported
-- from love's framework, so ffi.C resolves it in the running process.
local physfsMountFn = nil
local function mountReadable(dir)
  if physfsMountFn == nil then
    physfsMountFn = false
    local ok, ffi = pcall(require, "ffi")
    if ok then
      pcall(ffi.cdef,
        "int PHYSFS_mount(const char *newDir, const char *mountPoint, int appendToPath);")
      if pcall(function() return ffi.C.PHYSFS_mount end) then
        physfsMountFn = function(d)
          local okc, ret = pcall(ffi.C.PHYSFS_mount, d, "", 1)
          return okc and ret ~= 0
        end
      end
    end
  end
  if not physfsMountFn then return false end
  return physfsMountFn(dir)
end

-- The portable game folder when the cache should live there, else nil.
-- Resolved (and, for a fused build, mounted) once and cached.  Requires a
-- desktop portable install (SaveData) and a working windowless mkdir.
local portableRoot = nil
local portableResolved = false
local function resolvePortableRoot()
  if portableResolved then return portableRoot end
  portableResolved = true
  portableRoot = nil
  if not resolveMkdir() then return nil end
  local base = require("src.core.SaveData").portableBaseDir()
  if not base then return nil end
  if love.filesystem.getSource and base == love.filesystem.getSource() then
    -- source run: the folder is already the physfs source
    portableRoot = base
  elseif mountReadable(base) then
    -- fused build: base is next to the executable; mount it so io.* writes
    -- there are visible to love.filesystem/require/newImage
    portableRoot = base
  end
  return portableRoot
end

function CacheFs.root()
  return resolvePortableRoot()
end

local function realPath(root, rel)
  return root .. SEP .. rel:gsub("/", SEP)
end

-- create every parent directory of `rel` under `root` (best effort; an
-- already-existing directory is fine, a genuine failure surfaces when the
-- subsequent io.open write fails)
local function ensureParents(root, rel)
  local mkdir = resolveMkdir()
  if not mkdir then return end
  local parts = {}
  for part in rel:gmatch("[^/]+") do parts[#parts + 1] = part end
  local cur = root
  for i = 1, #parts - 1 do
    cur = cur .. SEP .. parts[i]
    mkdir(cur)
  end
end

-- write cache-relative `rel` (forward-slash path) with the given bytes;
-- returns ok, err like love.filesystem.write
function CacheFs.write(rel, data)
  local root = CacheFs.root()
  if root then
    ensureParents(root, rel)
    local f, err = io.open(realPath(root, rel), "wb")
    if not f then return false, err end
    f:write(data)
    f:close()
    return true
  end
  local parent = rel:match("^(.*)/[^/]+$")
  if parent and not love.filesystem.createDirectory(parent) then
    local info = love.filesystem.getInfo(parent)
    local reason = info and ("a " .. info.type .. " already exists there")
      or "unknown reason"
    return false, "could not create " .. parent .. ": " .. reason
  end
  return love.filesystem.write(rel, data)
end

-- read cache-relative `rel`; returns the bytes or nil
function CacheFs.read(rel)
  local root = CacheFs.root()
  if root then
    local f = io.open(realPath(root, rel), "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
  end
  return love.filesystem.read(rel)
end

-- does cache-relative `rel` exist as a file?
function CacheFs.exists(rel)
  local root = CacheFs.root()
  if root then
    local f = io.open(realPath(root, rel), "rb")
    if not f then return false end
    f:close()
    return true
  end
  return love.filesystem.getInfo(rel, "file") ~= nil
end

-- remove a single cache-relative file
function CacheFs.remove(rel)
  local root = CacheFs.root()
  if root then
    os.remove(realPath(root, rel))
    return
  end
  love.filesystem.remove(rel)
end

-- Remove the game-folder copy of a cache subtree before a fresh import, so a
-- cache-format bump does not leave orphaned files behind.  No-op when the
-- portable cache is inactive (the save-directory copy is cleared by
-- RomImporter's own removeTree).  The tree is enumerated through
-- love.filesystem (the game folder is mounted) and the real files deleted
-- with os.remove; empty directories are harmless and left in place.
function CacheFs.removeTree(rel)
  local root = CacheFs.root()
  if not root then return end
  local function walk(r)
    local info = love.filesystem.getInfo(r)
    if not info then return end
    if info.type == "directory" then
      for _, child in ipairs(love.filesystem.getDirectoryItems(r)) do
        walk(r .. "/" .. child)
      end
    else
      os.remove(realPath(root, r))
    end
  end
  walk(rel)
end

return CacheFs
