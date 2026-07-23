-- Single source of every compatibility-relevant number: engine release,
-- mod API major, link protocol, save format and ROM cache generation.  Zero
-- requires so it loads during love.conf and under plain Lua for tools and
-- tests.

local Version = {
  engine = "1.0.0",       -- game/engine release (semver triple)
  modApi = 2,             -- mod API major (manifest `api`)
  linkProtocol = 2,       -- link handshake wire version (Handshake.PROTOCOL)
  saveFormat = 3,         -- save.meta.format
  cache = "rom-cache-v5", -- ROM import cache generation (RomImporter marker)
}

-- "Pokemon Red (Gen 1 Recompilation Project) v1.0.0"
function Version.title(base)
  return (base or "Pokemon Red (Gen 1 Recompilation Project)")
    .. " v" .. Version.engine
end

return Version
