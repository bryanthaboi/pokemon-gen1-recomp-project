-- Which Gen-1 game this process is running: Red (the historical default) or
-- Blue.  One source of truth for everything that differs by version -- the
-- accepted ROM hash, the import manifest, where the extracted cache lives,
-- and the save-file suffix -- so the importer, cache mount, SaveData, title
-- screen and palette all agree.
--
-- Red keeps every un-suffixed path it always used (save.lua, the root cache),
-- so existing installs are untouched; Blue is namespaced under blue/ and
-- _blue so both can be imported and played side by side.
--
-- Zero requires, so it loads during love.conf and under plain Lua for tools
-- and tests.  The active version is a process-global set once at boot from
-- the launcher's column choice (main.lua); it defaults to Red.

local GameVersion = {}

GameVersion.VERSIONS = {
  red = {
    id = "red",
    label = "Red",
    displayName = "Pokemon Red",
    sha1 = "ea9bcae617fdf159b045185467ae58b2e4a48b9a",
    manifest = "tools/rom_manifest.json",
    cachePrefix = "",       -- Red owns the cache root (backwards compatible)
    saveSuffix = "",        -- save.lua / save.lua.bak / save.lua.tmp
  },
  blue = {
    id = "blue",
    label = "Blue",
    displayName = "Pokemon Blue",
    sha1 = "d7037c83e1ae5b39bde3c30787637ba1d4c48ce2",
    manifest = "tools/rom_manifest_blue.json",
    cachePrefix = "blue/",  -- blue/data/generated, blue/assets/generated
    saveSuffix = "_blue",   -- save_blue.lua / .bak / .tmp
  },
}

-- Launcher column order (Yellow is still a placeholder, handled by the UI).
GameVersion.ORDER = { "red", "blue" }

GameVersion.current = "red"

function GameVersion.set(id)
  GameVersion.current = GameVersion.VERSIONS[id] and id or "red"
  return GameVersion.current
end

function GameVersion.get()
  return GameVersion.current
end

function GameVersion.isBlue()
  return GameVersion.current == "blue"
end

-- Metadata for a version id, defaulting to the active one.
function GameVersion.info(id)
  return GameVersion.VERSIONS[id or GameVersion.current]
end

function GameVersion.saveSuffix(id)
  return GameVersion.info(id).saveSuffix
end

function GameVersion.cachePrefix(id)
  return GameVersion.info(id).cachePrefix
end

-- The version a ROM belongs to, by its SHA-1, or nil for an unknown ROM.
function GameVersion.forSha1(sha1)
  for id, info in pairs(GameVersion.VERSIONS) do
    if info.sha1 == sha1 then return id end
  end
  return nil
end

return GameVersion
