-- Handshake v2 (D8): the `hello` both peers exchange on pairing and the
-- compatibility verdict drawn from the two of them.
--
-- v1 builds sent `{type="hello", name, mode}` and nothing else.  Every field
-- here is additive, and a peer that omits `protocol` is by construction a
-- pre-mod build running unmodified content -- so a missing `protocol` reads
-- as "peer is vanilla" and the v1 code path is taken verbatim.  That keeps
-- old installs byte-compatible instead of locking them out.

local Fingerprint = require("src.link.Fingerprint")
local Schemas = require("src.mods.Schemas")
local Version = require("src.core.Version")

local Handshake = {}

Handshake.PROTOCOL = Version.linkProtocol or 2

-- writing into any of these changes what a lockstep turn or a rebuilt trade
-- mon looks like, which is what a v1 peer cannot know about us
local LINK_SURFACE = {
  pokemon = true, moves = true, type_chart = true, statuses = true,
  move_effects = true, balls = true, rulesets = true, constants = true,
  link_fields = true,
}

Handshake.LINK_SURFACE = LINK_SURFACE

local function loader(game)
  return game and game.mods or nil
end

-- every enabled mod, sorted so both peers see one order.  The whole set
-- rides the wire because the incompatibility screen diffs these arrays to
-- name what is missing; only the affects-link ones fold into the digest.
function Handshake.mods(game)
  local mods = {}
  local mod = loader(game)
  if not mod or not mod.status then return mods end
  local ok, status = pcall(mod.status, mod)
  if not ok or not status then return mods end
  for _, manifest in ipairs(status.loaded or {}) do
    mods[#mods + 1] = { id = manifest.id, version = manifest.version,
                        affectsLink = manifest.affects_link ~= false }
  end
  table.sort(mods, function(a, b) return tostring(a.id) < tostring(b.id) end)
  return mods
end

-- cheap answer to "can I link with a peer that assumes vanilla?": true as
-- soon as one enabled mod either declares affects_link or has written a
-- record into a link-surface registry
function Handshake.linkModified(game)
  local mod = loader(game)
  if not mod then return false end
  for _, entry in ipairs(Handshake.mods(game)) do
    if entry.affectsLink then return true end
  end
  for name, registry in pairs(mod.content or {}) do
    if LINK_SURFACE[name] then
      for _, list in pairs(registry.ops or {}) do
        for _, entry in ipairs(list) do
          if entry.owner and entry.owner ~= Schemas.ENGINE then return true end
        end
      end
    end
  end
  return false
end

-- mode is nil on the guest: it pairs and announces itself before the host
-- has picked, and compatibility is decided from the two hellos, not the mode
function Handshake.hello(game, mode)
  local mods = Handshake.mods(game)
  return {
    type = "hello",
    protocol = Handshake.PROTOCOL,
    name = game and game.save and game.save.player and game.save.player.name,
    mode = mode,
    engineVersion = Version.engine,
    apiVersion = Version.modApi,
    fingerprint = Fingerprint.compute(game and game.data, mods),
    linkModified = Handshake.linkModified(game),
    mods = mods,
  }
end

local function major(semver)
  return tonumber(tostring(semver or ""):match("^(%d+)")) or 0
end

-- full        identical link surfaces: nothing to negotiate, lockstep is safe
-- vanilla_peer  an old build, and we are unmodified, so it is right about us
-- subset      both v2 but the surfaces differ: negotiated trade, no battle
-- refused     an old build we would silently corrupt, or a different engine
function Handshake.checkCompat(localHello, remoteHello)
  localHello = localHello or {}
  if not remoteHello or not remoteHello.protocol then
    if localHello.linkModified then
      return "refused", "peer_v1_modified"
    end
    return "vanilla_peer", nil
  end
  if major(remoteHello.engineVersion) ~= major(localHello.engineVersion) then
    return "refused", "engine_mismatch"
  end
  if remoteHello.fingerprint == localHello.fingerprint then
    return "full", nil
  end
  return "subset", "fingerprint_mismatch"
end

-- only two v2 peers that agreed on a verdict may reject a mon outright; a v1
-- peer keeps the old substitute-a-move behaviour it was built against
function Handshake.strict(verdict)
  return verdict == "full" or verdict == "subset"
end

function Handshake.battleAllowed(verdict)
  return verdict == "full" or verdict == "vanilla_peer" or verdict == nil
end

function Handshake.tradeAllowed(verdict)
  return verdict ~= "refused"
end

-- ------- incompatibility report

local function index(mods)
  local byId = {}
  for _, mod in ipairs(mods or {}) do byId[tostring(mod.id)] = mod end
  return byId
end

-- the two mod arrays diffed, so the screen can name the difference instead
-- of the old silent mid-battle draw
function Handshake.modDiff(localHello, remoteHello)
  local mine = index(localHello and localHello.mods)
  local theirs = index(remoteHello and remoteHello.mods)
  local onlyMine, onlyTheirs, differing = {}, {}, {}
  for id, mod in pairs(mine) do
    local peer = theirs[id]
    if not peer then
      onlyMine[#onlyMine + 1] = mod
    elseif tostring(peer.version) ~= tostring(mod.version) then
      differing[#differing + 1] = { id = id, mine = mod.version,
                                    theirs = peer.version }
    end
  end
  for id, mod in pairs(theirs) do
    if not mine[id] then onlyTheirs[#onlyTheirs + 1] = mod end
  end
  local byId = function(a, b) return tostring(a.id) < tostring(b.id) end
  table.sort(onlyMine, byId)
  table.sort(onlyTheirs, byId)
  table.sort(differing, byId)
  return { onlyMine = onlyMine, onlyTheirs = onlyTheirs, differing = differing }
end

local WIDTH = 19 -- characters that fit one 160px line at 8px per glyph

local function wrap(lines, text)
  while #text > WIDTH do
    local cut = text:sub(1, WIDTH + 1):match("^.*()%s")
    if not cut or cut <= 1 then cut = WIDTH + 1 end
    lines[#lines + 1] = text:sub(1, cut - 1)
    text = text:sub(cut + 1)
  end
  if #text > 0 then lines[#lines + 1] = text end
end

local function listMods(lines, heading, mods)
  if #mods == 0 then return end
  wrap(lines, heading)
  for i, mod in ipairs(mods) do
    if i > 3 then
      wrap(lines, ("and %d more."):format(#mods - 3))
      return
    end
    wrap(lines, (" %s %s"):format(tostring(mod.id):upper():sub(1, 12),
                                  tostring(mod.version or "?")))
  end
end

-- lines for the incompatibility screen: what differs, then what still works
function Handshake.describe(localHello, remoteHello, verdict, mode)
  local lines = {}
  local peer = (remoteHello and remoteHello.name) or "THEY"
  if verdict == "refused" then
    if not (remoteHello and remoteHello.protocol) then
      wrap(lines, "The other game is")
      wrap(lines, "an older version")
      wrap(lines, "with no mods.")
      wrap(lines, "Your mods can't")
      wrap(lines, "link with it.")
    else
      wrap(lines, "The two games are")
      wrap(lines, "different engine")
      wrap(lines, "versions.")
    end
    return lines
  end
  wrap(lines, "Your games differ.")
  local diff = Handshake.modDiff(localHello, remoteHello)
  listMods(lines, peer .. " has:", diff.onlyTheirs)
  listMods(lines, "You have:", diff.onlyMine)
  for i, row in ipairs(diff.differing) do
    if i > 2 then break end
    wrap(lines, ("%s %s vs %s"):format(tostring(row.id):upper():sub(1, 8),
                                       tostring(row.mine), tostring(row.theirs)))
  end
  if #diff.onlyMine == 0 and #diff.onlyTheirs == 0 and #diff.differing == 0 then
    wrap(lines, "The game data is")
    wrap(lines, "not the same.")
  end
  if mode == "battle" then
    wrap(lines, "Link battle needs")
    wrap(lines, "the same mods.")
  else
    wrap(lines, "Trading is limited")
    wrap(lines, "to shared POKéMON.")
  end
  return lines
end

return Handshake
