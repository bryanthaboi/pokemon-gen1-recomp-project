-- Manifest v2: a strict superset of v1, so every shipped v1 manifest stays
-- valid.  Pure (no filesystem): the loader's validate phase owns the checks
-- that need to stat a file, this owns shape, vocabulary and range grammar.
local Logger = require("src.core.Logger")
local Semver = require("src.mods.Semver")
local Version = require("src.core.Version")

local Manifest = {}

Manifest.PROFILES = { content = true, overhaul = true, total_conversion = true }
Manifest.PERMISSIONS = { network = true, filesystem = true, engine_internals = true }

-- link-relevant registries; a mod that writes into one of these while
-- declaring affects_link = false gets an attributed warning from the loader
Manifest.LINK_REGISTRIES = {
  pokemon = true, moves = true, type_chart = true,
  statuses = true, move_effects = true,
}

local function array(value)
  if value == nil then return {} end
  assert(type(value) == "table", "manifest arrays must be tables")
  return value
end

-- api 2 treats vocabulary violations as load errors; api 1 keeps loading and
-- gets an attributed warning so v1 mods never break on a field they predate
local function violation(strict, id, message)
  if strict then error(message, 0) end
  Logger.warn("[%s] %s", tostring(id), message)
end

-- "id" or "id@<range>"; a malformed id or range fails for every api level
-- because there is no sane fallback reading for it
local function parseSpecs(list, field)
  local specs = {}
  for _, entry in ipairs(list) do
    assert(type(entry) == "string" and entry ~= "",
      field .. " entries must be non-empty strings")
    local id, range = entry:match("^([%w_%-]+)@(.+)$")
    if not id then
      id = entry:match("^([%w_%-]+)$")
      assert(id, ("malformed %s entry %q"):format(field, entry))
      range = nil
    end
    local ok, err = Semver.validRange(range)
    assert(ok, ("malformed %s range in %q: %s"):format(field, entry, tostring(err)))
    specs[#specs + 1] = { id = id, range = range }
  end
  return specs
end

function Manifest.validate(raw, path)
  assert(type(raw) == "table", "manifest must be an object")
  assert(type(raw.id) == "string" and raw.id:match("^[%w_%-]+$"),
    "manifest id must contain only letters, numbers, _ or -")
  assert(type(raw.name) == "string" and raw.name ~= "", "manifest name is required")
  assert(type(raw.version) == "string" and raw.version ~= "", "manifest version is required")
  assert(type(raw.entry) == "string" and raw.entry ~= "", "manifest entry is required")

  -- absent means 1: full v1 compat, schema violations downgrade to warnings
  assert(raw.api == nil or tonumber(raw.api) ~= nil, "manifest api must be a number")
  local api = tonumber(raw.api) or 1
  assert(api >= 1 and api % 1 == 0, "manifest api must be a positive integer")
  assert(api <= Version.modApi, ("requires mod API %d; this engine provides %d")
    :format(api, Version.modApi))
  local strict = api >= 2

  local profile = raw.profile or "content"
  if not Manifest.PROFILES[profile] then
    violation(strict, raw.id, ("unknown profile %q"):format(tostring(profile)))
    profile = "content"
  end

  local permissions, permissionSet = {}, {}
  for _, name in ipairs(array(raw.permissions)) do
    if Manifest.PERMISSIONS[name] then
      permissions[#permissions + 1] = name
      permissionSet[name] = true
    else
      violation(strict, raw.id, ("unknown permission %q"):format(tostring(name)))
    end
  end

  local gameVersionOk, gameVersionErr = Semver.validRange(raw.game_version)
  assert(gameVersionOk, ("malformed game_version %q: %s")
    :format(tostring(raw.game_version), tostring(gameVersionErr)))

  -- overhauls and total conversions are assumed to move the link
  -- fingerprint unless the manifest says otherwise; content packs are not
  local affectsLink = profile ~= "content"
  if type(raw.affects_link) == "boolean" then affectsLink = raw.affects_link end

  local function optionalFile(value, field)
    if value == nil then return nil end
    assert(type(value) == "string" and value ~= "", field .. " must be a file path")
    return value
  end

  return {
    id = raw.id,
    name = raw.name,
    version = raw.version,
    entry = raw.entry,
    api = api,
    priority = tonumber(raw.priority) or 0,
    dependencies = array(raw.dependencies),
    optional_dependencies = array(raw.optional_dependencies),
    conflicts = array(raw.conflicts),
    dependencySpecs = parseSpecs(array(raw.dependencies), "dependencies"),
    optionalSpecs = parseSpecs(array(raw.optional_dependencies), "optional_dependencies"),
    conflictSpecs = parseSpecs(array(raw.conflicts), "conflicts"),
    category = raw.category or "OTHER",
    game_version = raw.game_version,
    description = raw.description or "",
    profile = profile,
    affects_link = affectsLink,
    permissions = permissions,
    permissionSet = permissionSet,
    options_schema = optionalFile(raw.options_schema, "options_schema"),
    assets_transforms = optionalFile(raw.assets_transforms, "assets_transforms"),
    path = path,
    raw = raw,
  }
end

return Manifest
